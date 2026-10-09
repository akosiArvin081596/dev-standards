# shellcheck shell=bash disable=SC2034  # variables here are used by run.sh and run-groups.sh
# shellcheck source-path=SCRIPTDIR
# Helpers for tests/commands/github/run.sh. Sourced, never executed.
# Everything runs in a mktemp -d sandbox: stub gh and security first on PATH, a fake
# TEAM_CONFIG_DIR and HOME, fake accounts (octo-owner, octo-other, optional octo-agent).

# Byte-order collation: in some UTF-8 locales bash 3.2 lets [a-z] match capitals.
unset LC_ALL
LC_COLLATE=C
export LC_COLLATE

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
BIN="$REPO/plugins/team/bin"
FIX="$HERE/fixtures"
MY_CMDS="team-gh team-post-check team-bootstrap-repo team-verify-repo team-sync team-store-token team-merge-if-green team-worktree-report team-conflict-check"
TOKEN_RE='gho_FAKE|TOKENxyz123'

N_PASS=0
N_FAIL=0
pass() { N_PASS=$((N_PASS + 1)); printf 'PASS  %s\n' "$1"; }
fail() {
  N_FAIL=$((N_FAIL + 1))
  printf 'FAIL  %s\n' "$1"
  if [ -n "${2-}" ]; then printf '%s\n' "$2" | head -n 40 | sed 's/^/      | /'; fi
}
section() { printf '\n== %s\n' "$1"; }

setup_sandbox() {
  REAL_GIT=$(command -v git)
  REAL_HOME="$HOME"
  T=$(mktemp -d "${TMPDIR:-/tmp}/team-ghtest.XXXXXX")
  T=$(cd "$T" && pwd -P)
  mkdir -p "$T/stubbin" "$T/gh" "$T/sec" "$T/config" "$T/home"
  cp "$HERE/stubs/gh" "$HERE/stubs/security" "$T/stubbin/"
  chmod +x "$T/stubbin/gh" "$T/stubbin/security"
  export PATH="$T/stubbin:$BIN:$PATH"
  export GH_STUB_DIR="$T/gh" SEC_STUB_DIR="$T/sec" TEAM_CONFIG_DIR="$T/config" HOME="$T/home"
  export TEAM_STANDARDS_DIR="$FIX/standards"
  export GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@example.invalid"
  export GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@example.invalid"
  export TEAM_BOOTSTRAP_POLL_SLEEP=0
  unset CLAUDECODE GH_REPO GH_TOKEN GITHUB_TOKEN GH_HOST GH_DEBUG TEAM_STANDARDS_REF TEAM_STANDARDS_TARBALL \
    TEAM_STANDARDS_REPO TEAM_TEMPLATE_REPO CLAUDE_PLUGIN_ROOT
  write_config noagent

  # Shared network guard, installed last so its fakes come first on PATH: every
  # ssh/scp/sftp/rsync call is logged and refused. No test may run without it.
  # shellcheck source=SCRIPTDIR/../../lib/net-guard.sh
  . "$REPO/tests/lib/net-guard.sh"
  NET_GUARD_REAL_HOME="$REAL_HOME"
  net_guard_install "$T/net-guard"
  if net_guard_assert; then
    pass "net-guard: fake ssh/scp/sftp/rsync first on PATH, refusing and logging; fake TEAM_CONFIG_DIR and HOME"
  else
    echo "net-guard is not in place; refusing to run any test" >&2
    exit 1
  fi
  NET_GUARD_BASELINE=$(wc -l <"$NET_GUARD_LOG" | tr -d ' ')
}

# net_guard_final : no ssh-family call happened after the guard's own self-test
net_guard_final() {
  local now
  now=$(wc -l <"$NET_GUARD_LOG" | tr -d ' ')
  if [ "$now" = "$NET_GUARD_BASELINE" ]; then
    pass "net-guard: no ssh/scp/sftp/rsync call during the whole run"
  else
    fail "net-guard: ssh-family calls were attempted (all refused)" "$(tail -n +"$((NET_GUARD_BASELINE + 1))" "$NET_GUARD_LOG")"
  fi
}

cleanup() {
  if [ -n "${T:-}" ] && [ -d "$T" ]; then rm -rf "${T:?}"; fi
}

# write_config agent|noagent
write_config() {
  {
    echo "# test accounts (fake)"
    echo "account|octo-owner|github.com|Octo Owner|owner@example.invalid"
    echo "account|octo-other|github.com-other|Octo Other|other@example.invalid"
    [ "$1" = agent ] && echo "agent|octo-agent|github.com-agent|Octo Agent|agent@example.invalid"
  } >"$TEAM_CONFIG_DIR/accounts.conf"
  {
    echo "DEFAULT_GITHUB_ACCOUNT=octo-owner"
    echo "OWNER_LOGIN=octo-owner"
    echo "DEFAULT_TIMEZONE=Asia/Manila"
  } >"$TEAM_CONFIG_DIR/defaults.conf"
}

# ------------------------------------------------------------------ gh stub control

R_N=0
stub_reset() {
  rm -f "$GH_STUB_DIR"/log "$GH_STUB_DIR"/routes "$GH_STUB_DIR"/count "$GH_STUB_DIR"/unmatched
  rm -f "$GH_STUB_DIR"/body.* "$GH_STUB_DIR"/resp.* "$GH_STUB_DIR"/noauth-*
  : >"$GH_STUB_DIR/log"
}
stub_clear_log() { : >"$GH_STUB_DIR/log"; rm -f "$GH_STUB_DIR"/body.*; }

# route <glob> <json | @file | -> [rc] [http]
route() {
  local pat="$1" content="$2" rc="${3:-0}" http="${4:-}" f
  # never leave a field empty: tab is IFS whitespace, so empty fields would collapse
  if [ -z "$http" ]; then if [ "${rc%!}" = 0 ]; then http=200; else http=500; fi; fi
  R_N=$((R_N + 1))
  f="resp.$R_N"
  case "$content" in
    @*) cp "${content#@}" "$GH_STUB_DIR/$f" ;;
    -) f="-" ;;
    *) printf '%s\n' "$content" >"$GH_STUB_DIR/$f" ;;
  esac
  printf '%s\t%s\t%s\t%s\n' "$pat" "$rc" "$http" "$f" >>"$GH_STUB_DIR/routes"
}
route_err() { route "$1" '{"message":"error"}' 1 "$2"; }

# log lines: n|acting|key
log_keys() { cut -d'|' -f3- "$GH_STUB_DIR/log"; }
# last_call <glob> : prints "n|acting|key" of the last call whose key matches
last_call() {
  local line key hit=""
  while IFS= read -r line; do
    key="${line#*|}"; key="${key#*|}"
    # shellcheck disable=SC2254
    case "$key" in $1) hit="$line" ;; esac
  done <"$GH_STUB_DIR/log"
  [ -n "$hit" ] || return 1
  printf '%s' "$hit"
}
called() { last_call "$1" >/dev/null; }
count_calls() {
  local line key c=0
  while IFS= read -r line; do
    key="${line#*|}"; key="${key#*|}"
    # shellcheck disable=SC2254
    case "$key" in $1) c=$((c + 1)) ;; esac
  done <"$GH_STUB_DIR/log"
  printf '%s' "$c"
}
acting_for() { local l; l=$(last_call "$1") || return 1; l="${l#*|}"; printf '%s' "${l%%|*}"; }
body_for() {
  local l n
  l=$(last_call "$1") || return 1
  n="${l%%|*}"
  [ -f "$GH_STUB_DIR/body.$n" ] || return 1
  cat "$GH_STUB_DIR/body.$n"
}
# any_write : true when the log holds a GitHub write
any_write() {
  log_keys | grep -Eq '^(api (POST|PUT|PATCH|DELETE) |secret set|pr (create|edit|comment|review|merge)|issue (create|comment|edit))'
}

# ------------------------------------------------------------------ running commands

# cmd <name> args... : run a plugin command with /bin/bash
cmd() { local c="$1"; shift; /bin/bash "$BIN/$c" "$@"; }
in_dir() { local d="$1"; shift; (cd "$d" && "$@"); }

# run_cmd <cmd...> : OUT, RC; fails the test when a token shows up in the output
run_cmd() {
  OUT=$("$@" 2>&1)
  RC=$?
  if printf '%s' "$OUT" | grep -Eq "$TOKEN_RE"; then fail "token leaked in output of: $*" "$OUT"; fi
  return 0
}
# run_in <stdin-text> <cmd...> : like run_cmd with stdin
run_in() {
  local input="$1"
  shift
  OUT=$(printf '%s' "$input" | "$@" 2>&1)
  RC=$?
  if printf '%s' "$OUT" | grep -Eq "$TOKEN_RE"; then fail "token leaked in output of: $*" "$OUT"; fi
  return 0
}

has() { case "$OUT" in *"$1"*) return 0 ;; esac; return 1; }

expect_rc() {
  local name="$1" want="$2"
  shift 2
  run_cmd "$@"
  if [ "$RC" = "$want" ]; then pass "$name"; else fail "$name (exit $RC, want $want)" "$OUT"; fi
}
expect_out() { if has "$2"; then pass "$1"; else fail "$1 (missing: $2)" "$OUT"; fi; }
expect_no_out() { if has "$2"; then fail "$1 (unexpected: $2)" "$OUT"; else pass "$1"; fi; }
ok() { local name="$1"; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }
not() { if "$@"; then return 1; else return 0; fi; }
json_eq() { [ "$(printf '%s' "$1" | jq -cS .)" = "$(printf '%s' "$2" | jq -cS .)" ]; }
expect_json() {
  local name="$1" got="$2" want="$3"
  if json_eq "$got" "$want"; then pass "$name"; else fail "$name" "got:  $(printf '%s' "$got" | jq -cS . 2>&1)
want: $(printf '%s' "$want" | jq -cS . 2>&1)"; fi
}

# make_repo <dir> <origin-url> [GITHUB_ACCOUNT] [PROJECT_TIMEZONE] [VISIBILITY]
make_repo() {
  local d="$1" url="$2" acct="${3:-octo-owner}" tz="${4:-}" vis="${5:-public}"
  mkdir -p "$d"
  git init -q -b main "$d"
  git -C "$d" remote add origin "$url"
  mkdir -p "$d/ops"
  {
    echo "PROJECT_NAME=sample-app"
    echo "GITHUB_ACCOUNT=$acct"
    echo "VISIBILITY=$vis"
    [ -z "$tz" ] || echo "PROJECT_TIMEZONE=$tz"
  } >"$d/ops/project.conf"
  printf 'hello\n' >"$d/README.md"
  git -C "$d" add -A
  git -C "$d" commit -q -m "chore: init"
}
