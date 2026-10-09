#!/usr/bin/env bash
# self-test.sh: dev-standards' own checks (the `self-test` job), runnable on the Mac too.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
export LC_ALL=C

usage() {
  cat <<'USAGE'
Usage: tests/ci/self-test.sh                  run every check from the repo root
       tests/ci/self-test.sh --install-tools DIR
                                              (CI) download the pinned shellcheck and
                                              actionlint for linux x86_64 into DIR,
                                              verified against config/tool-versions.env

Checks, each PASS / FAIL / SKIP:
  1. shellcheck -x on every shell file (*.sh, *.bash, and files with a sh/bash shebang)
  2. actionlint on every workflow (ignoring only the job.workflow_repository /
     job.workflow_sha properties, which actionlint 1.7.12 doesn't know yet)
  3. tests/lib/net-guard-test.sh, tests/hooks/run.sh, tests/commands/*/run.sh,
     tests/ci/run.sh (when present), with TEAM_CONFIG_DIR pointing at an empty temp
     folder (never the real config) and the net guard (tests/lib/net-guard.sh)
     installed first, so no suite can reach a server
     (SELF_TEST_SUITES="<file> ..." runs only those suites)
  4. scripts/ci/context-check.sh --standards-self
  5. claude plugin validate . and ./plugins/team (CLAUDE_BIN, else `claude` on PATH;
     SKIP when neither exists)
Exit 0 when nothing fails, 1 otherwise, 2 on usage error.
USAGE
}

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
conf() { bash "$ROOT/scripts/ci/conf.sh" get "$ROOT/config/tool-versions.env" "$1"; }
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }

install_tools() {
  local dir="$1" tmp sc_v sc_sum al_v al_sum
  [ "$(uname -s)-$(uname -m)" = "Linux-x86_64" ] || { echo "self-test.sh: --install-tools is for linux x86_64 (CI)" >&2; exit 5; }
  mkdir -p "$dir"
  tmp=$(mktemp -d)
  sc_v=$(conf SHELLCHECK_VERSION); sc_sum=$(conf SHELLCHECK_SHA256)
  al_v=$(conf ACTIONLINT_VERSION); al_sum=$(conf ACTIONLINT_SHA256)
  curl -fsSL --retry 3 -o "$tmp/sc.tar.xz" "https://github.com/koalaman/shellcheck/releases/download/v${sc_v}/shellcheck-v${sc_v}.linux.x86_64.tar.xz"
  [ "$(sha256 "$tmp/sc.tar.xz")" = "$sc_sum" ] || { echo "self-test.sh: shellcheck checksum mismatch" >&2; rm -rf "${tmp:?}"; exit 1; }
  tar -xJf "$tmp/sc.tar.xz" -C "$tmp"
  cp "$tmp/shellcheck-v${sc_v}/shellcheck" "$dir/shellcheck"
  curl -fsSL --retry 3 -o "$tmp/al.tar.gz" "https://github.com/rhysd/actionlint/releases/download/v${al_v}/actionlint_${al_v}_linux_amd64.tar.gz"
  [ "$(sha256 "$tmp/al.tar.gz")" = "$al_sum" ] || { echo "self-test.sh: actionlint checksum mismatch" >&2; rm -rf "${tmp:?}"; exit 1; }
  tar -xzf "$tmp/al.tar.gz" -C "$dir" actionlint
  chmod 755 "$dir/shellcheck" "$dir/actionlint"
  rm -rf "${tmp:?}"
  "$dir/shellcheck" --version | sed -n 2p
  "$dir/actionlint" --version | head -n 1
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --install-tools) [ "$#" -eq 2 ] || { usage >&2; exit 2; }; install_tools "$2"; exit 0 ;;
  '') ;;
  *) usage >&2; exit 2 ;;
esac

results=""
fails=0
record() { results="${results}$(printf '%-5s %s' "$1" "$2")"$'\n'; [ "$1" != FAIL ] || fails=$((fails + 1)); }
section() { printf '\n=== %s ===\n' "$1"; }

work=$(mktemp -d)
trap 'rm -rf "${work:?}"' EXIT
mkdir -p "$work/team-config"

# 1. shellcheck
section "shellcheck"
: > "$work/shell-files"
find . \( -name .git -o -name node_modules -o -name .team -o -name .team-standards -o -name worktrees \) -prune -o -type f -print \
  | sed 's|^\./||' | LC_ALL=C sort > "$work/all-files"
while IFS= read -r f; do
  case "$f" in
    *.sh|*.bash) printf '%s\n' "$f" >> "$work/shell-files"; continue ;;
    *.md|*.json|*.yml|*.yaml|*.txt|*.toml|*.env|*.conf|*.lock|*.tar.gz|*.png|*.jpg) continue ;;
  esac
  first=$(head -n 1 "$f" 2>/dev/null | tr -d '\r' || true)
  case "$first" in
    '#!'*bash*|'#!'*/sh|'#!'*' sh'|'#!'*/sh' '*) printf '%s\n' "$f" >> "$work/shell-files" ;;
  esac
done < "$work/all-files"
n_sh=$(wc -l < "$work/shell-files" | tr -d ' ')
if ! command -v shellcheck >/dev/null 2>&1; then
  record FAIL "shellcheck is not installed"
else
  files=()
  while IFS= read -r f; do files+=("$f"); done < "$work/shell-files"
  if shellcheck -x ${files[@]+"${files[@]}"}; then record PASS "shellcheck: $n_sh shell files"
  else record FAIL "shellcheck: findings above ($n_sh shell files)"; fi
fi

# 2. actionlint
section "actionlint"
if ! command -v actionlint >/dev/null 2>&1; then
  record FAIL "actionlint is not installed"
else
  wf=()
  for f in .github/workflows/*.yml .github/workflows/*.yaml; do [ -f "$f" ] && wf+=("$f"); done
  if [ "${#wf[@]}" -eq 0 ]; then record FAIL "actionlint: no workflows found"
  elif actionlint -ignore 'property "workflow_(repository|sha)" is not defined' "${wf[@]}"; then record PASS "actionlint: ${#wf[@]} workflows"
  else record FAIL "actionlint: findings above"; fi
fi

# 3. test suites (each only when present; never the real ~/.config/team, never a server).
# Each suite installs its own net guard too; this one covers anything a suite runs first.
export TEAM_CONFIG_DIR="$work/team-config"
# shellcheck source=../lib/net-guard.sh
. "$ROOT/tests/lib/net-guard.sh"
net_guard_install "$work/net-guard"
if net_guard_assert; then record PASS "net-guard installed before the test suites"
else record FAIL "net-guard could not be installed: test suites not run"; suites_blocked=1; fi
suites="${SELF_TEST_SUITES:-$(printf '%s ' tests/lib/net-guard-test.sh tests/hooks/run.sh tests/commands/*/run.sh tests/ci/run.sh)}"
for suite in $suites; do
  [ -z "${suites_blocked:-}" ] || break
  [ -f "$suite" ] || continue
  section "$suite"
  rm -rf "${work:?}/team-config" && mkdir -p "$work/team-config"
  # The outer fakes stay first on PATH; each suite installs and asserts its own guard.
  if env -u NET_GUARD_DIR -u NET_GUARD_LOG bash "$suite"; then record PASS "$suite"
  else record FAIL "$suite"; fi
done
for suite in tests/hooks/run.sh tests/ci/run.sh; do
  [ -f "$suite" ] || record SKIP "$suite (not present)"
done
[ -z "${SELF_TEST_SUITES:-}" ] || record SKIP "other suites (SELF_TEST_SUITES is set)"

# 4. this repo's own context files
section "context check (standards-self)"
if bash scripts/ci/context-check.sh --standards-self; then record PASS "context check --standards-self"
else record FAIL "context check --standards-self"; fi

# 5. plugin manifests
section "claude plugin validate"
claude_bin="${CLAUDE_BIN:-}"
[ -n "$claude_bin" ] || claude_bin=$(command -v claude 2>/dev/null || true)
if [ -z "$claude_bin" ]; then
  record SKIP "claude plugin validate (no claude binary)"
  [ "${GITHUB_ACTIONS:-}" != true ] || echo "::notice::claude plugin validate skipped: Claude Code could not be installed"
else
  for target in . ./plugins/team; do
    if "$claude_bin" plugin validate "$target"; then record PASS "claude plugin validate $target"
    else record FAIL "claude plugin validate $target"; fi
  done
fi

printf '\n=== self-test summary ===\n%s' "$results"
if [ "$fails" -gt 0 ]; then
  printf 'self-test: %s check(s) failed\n' "$fails"
  exit 1
fi
printf 'self-test: all checks passed\n'
