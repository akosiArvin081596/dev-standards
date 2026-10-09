#!/usr/bin/env bash
# Unit tests for scripts/ci/*.sh, config/ and the workflows. Offline: GitHub, ssh and
# curl are stubs, git work happens in temp repos, and TEAM_CONFIG_DIR is a temp folder
# (never the real ~/.config/team). Run with: /bin/bash tests/ci/run.sh
# shellcheck source-path=SCRIPTDIR disable=SC2015,SC2016
# (SC2015: ok/bad always return 0, so `test && ok || bad` is safe. SC2016: backticks in test data are Markdown.)
set -uo pipefail
export LC_ALL=C

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
S="$ROOT/scripts/ci"
REAL_HOME="$HOME"
TMP=$(mktemp -d)
trap 'rm -rf "${TMP:?}"' EXIT

# Never the real config or home, never real GitHub
export HOME="$TMP/home" TEAM_CONFIG_DIR="$TMP/team-config"
mkdir -p "$HOME" "$TEAM_CONFIG_DIR"
unset GH_TOKEN GITHUB_TOKEN GITHUB_ACTIONS GITHUB_OUTPUT GITHUB_STEP_SUMMARY GITHUB_REPOSITORY \
  GITHUB_REPOSITORY_OWNER GITHUB_RUN_ID GITHUB_SHA PR_NUMBER BASE_SHA HEAD_SHA EVENT_ACTION OWNER_LOGIN \
  PROFILE PR_TITLE HEALTH_URL DEPLOY_HOST DEPLOY_USER DEPLOY_PORT DEPLOY_SSH_KEY DEPLOY_KNOWN_HOSTS \
  BASIC_AUTH_USER BASIC_AUTH_PASSWORD PROJECT_TIMEZONE TEAM_STANDARDS_DIR CI_CONFIG_DIR \
  GITLEAKS_VERSION GITLEAKS_SHA256 SEMGREP_VERSION 2>/dev/null || true
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.test GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.test

PASS=0
FAIL=0
LAST_OUT=""
ok() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }
# expect_rc <want> <name> <cmd...> : run, compare the exit code, keep the output in LAST_OUT
expect_rc() {
  local want="$1" name="$2" rc
  shift 2
  LAST_OUT=$("$@" 2>&1)
  rc=$?
  if [ "$rc" = "$want" ]; then ok "$name"; else
    bad "$name (exit $rc, want $want)"
    printf '%s\n' "$LAST_OUT" | tail -n 15 | sed 's/^/      | /'
  fi
}
# expect_out <grep -E pattern> <name> : LAST_OUT contains the pattern
expect_out() {
  if printf '%s\n' "$LAST_OUT" | grep -Eq -- "$1"; then ok "$2"; else
    bad "$2 (output lacks: $1)"
    printf '%s\n' "$LAST_OUT" | tail -n 10 | sed 's/^/      | /'
  fi
}
# expect_no_out <pattern> <name>
expect_no_out() {
  if printf '%s\n' "$LAST_OUT" | grep -Eq -- "$1"; then bad "$2 (output has: $1)"; else ok "$2"; fi
}
# expect_file_has <file> <pattern> <name>
expect_file_has() {
  if [ -f "$1" ] && grep -Eq -- "$2" "$1"; then ok "$3"; else bad "$3 ($1 lacks: $2)"; fi
}
expect_file_lacks() {
  if [ -f "$1" ] && grep -Eq -- "$2" "$1"; then bad "$3 ($1 has: $2)"; else ok "$3"; fi
}
section() { printf '\n== %s\n' "$1"; }

# ---------------------------------------------------------------- stubs
STUB="$TMP/stub"
mkdir -p "$STUB/bin" "$STUB/sim" "$STUB/gh-data"
export STUB_GH_LOG="$STUB/gh.log" STUB_GH_DATA="$STUB/gh-data"
cat > "$STUB/bin/gh" <<'EOF'
#!/bin/bash
# Stub gh: logs every call; serves $STUB_GH_DATA/<path with / → _>.json for GETs.
printf '%s\n' "$*" >> "$STUB_GH_LOG"
[ "${1:-}" = api ] || { echo "stub gh: only api" >&2; exit 1; }
shift
method=GET; jqf=""; path=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    --jq) jqf="$2"; shift 2 ;;
    --paginate) shift ;;
    -f|-F)
      case "$2" in body=@*) { printf -- '--- body\n'; cat "${2#body=@}"; } >> "$STUB_GH_LOG" ;; esac
      shift 2 ;;
    *) [ -z "$path" ] && path="$1"; shift ;;
  esac
done
if [ "$method" != GET ]; then
  if [ "${STUB_GH_WRITE_FAIL:-0}" = 1 ]; then echo "HTTP 403: Resource not accessible by integration" >&2; exit 1; fi
  case "$path" in
    */issues) if [ -n "$jqf" ]; then echo '{"number":99}' | jq -r "$jqf"; else echo '{"number":99}'; fi ;;
  esac
  exit 0
fi
key=$(printf '%s' "${path%%\?*}" | tr '/' '_')
f="$STUB_GH_DATA/$key.json"
[ -f "$f" ] || { echo "HTTP 404: stub has no $key" >&2; exit 1; }
if [ -n "$jqf" ]; then jq -r "$jqf" "$f"; else cat "$f"; fi
EOF
cat > "$STUB/sim/ssh" <<'EOF'
#!/bin/bash
# ssh simulator behind the net guard (the guard's fake logs the call, then hands it here):
# logs args, the key file's mode, and how many bytes came on stdin. Never connects.
log="$STUB_SSH_LOG"
printf 'args:' >> "$log"; for a in "$@"; do printf ' [%s]' "$a" >> "$log"; done; printf '\n' >> "$log"
prev=""
for a in "$@"; do
  if [ "$prev" = "-i" ]; then
    printf 'keymode: %s\n' "$(stat -f %Lp "$a" 2>/dev/null || stat -c %a "$a")" >> "$log"
    printf 'keyfile: %s\n' "$a" >> "$log"
  fi
  prev="$a"
done
printf 'stdin-bytes: %s\n' "$(wc -c | tr -d ' ')" >> "$log"
exit "${STUB_SSH_EXIT:-0}"
EOF
cat > "$STUB/bin/curl" <<'EOF'
#!/bin/bash
# Stub curl for smoke.sh: answers $STUB_CURL_CODE, writes headers for -D, logs args and -K content.
printf 'args: %s\n' "$*" >> "$STUB_CURL_LOG"
hdr=""; conf=""
while [ "$#" -gt 0 ]; do
  case "$1" in -D) hdr="$2"; shift 2 ;; -K) conf="$2"; shift 2 ;; *) shift ;; esac
done
[ -n "$conf" ] && { printf 'config: '; cat "$conf"; printf '\n'; } >> "$STUB_CURL_LOG"
if [ -n "$hdr" ]; then
  { printf 'HTTP/1.1 %s OK\r\n' "${STUB_CURL_CODE:-200}"; [ -n "${STUB_CURL_HEADER:-}" ] && printf '%s\r\n' "$STUB_CURL_HEADER"; } > "$hdr"
fi
printf '%s' "${STUB_CURL_CODE:-200}"
EOF
chmod +x "$STUB/bin/gh" "$STUB/sim/ssh" "$STUB/bin/curl"
mkdir -p "$STUB/ghbin"
cp "$STUB/bin/gh" "$STUB/ghbin/gh"
export PATH="$STUB/ghbin:$PATH"  # stub gh only (real curl stays, for file:// health checks)

# Network guard (tests/lib/net-guard.sh): fake ssh/scp/sftp/rsync go FIRST on PATH, log every
# call and refuse. deploy.sh's ssh is handed to $STUB/sim/ssh after logging. Never connects.
# shellcheck source=../lib/net-guard.sh
. "$ROOT/tests/lib/net-guard.sh"
NET_GUARD_REAL_HOME="$REAL_HOME"
net_guard_install "$TMP/net-guard"
if net_guard_assert; then ok "net-guard: fake ssh/scp/sftp/rsync first on PATH, refusing and logging"
else echo "net-guard is not in place; refusing to run any test" >&2; exit 1; fi
ALL_PATH="$NET_GUARD_DIR:$STUB/bin:$PATH"   # guard first, then stub gh + curl
reset_gh() { rm -rf "${STUB_GH_DATA:?}"/*; : > "$STUB_GH_LOG"; unset STUB_GH_WRITE_FAIL; }
gh_data() { printf '%s\n' "$2" > "$STUB_GH_DATA/$(printf '%s' "$1" | tr '/' '_').json"; }

# new_repo <dir> : git repo with one commit of whatever is in <dir>
new_repo() { git -C "$1" init -q -b main . && git -C "$1" add -A && git -C "$1" commit -qm base; }
commit_all() { git -C "$1" add -A && git -C "$1" commit -qm "${2:-change}"; }

# ======================================================================= pr-title
section "pr-title.sh"
for t in 'feat: add login' 'feat!: drop the v1 API' 'feat(api)!: drop v1' 'fix(auth): handle expiry' \
         'chore(deps): bump x from 1 to 2' 'chore(deps): Bump the actions group with 2 updates' \
         'chore(deps-dev): bump y' 'chore(main): release 1.2.0' 'hotfix: patch prod' 'docs: fix typo' 'revert: feat: x'; do
  expect_rc 0 "pr-title accepts: $t" env PR_TITLE="$t" /bin/bash "$S/pr-title.sh"
done
for t in 'Update README' 'feat:no space' 'Feat: x' 'FEAT: x' 'feat: ' 'wip: x' 'fix(a b): x' 'feat(): x' 'Revert "feat: x"' ''; do
  expect_rc 1 "pr-title rejects: '$t'" env PR_TITLE="$t" /bin/bash "$S/pr-title.sh"
done
expect_rc 1 "pr-title rejects an upper-case type under en_PH.UTF-8" env LANG=en_PH.UTF-8 LC_ALL=en_PH.UTF-8 PR_TITLE='Feat: x' /bin/bash "$S/pr-title.sh"
expect_rc 2 "pr-title needs PR_TITLE" /bin/bash "$S/pr-title.sh"
expect_rc 1 "pr-title: a title can't start a workflow command" env PR_TITLE='::add-mask::x' GITHUB_ACTIONS=true /bin/bash "$S/pr-title.sh"
expect_out '^title: ::add-mask::x' "pr-title prints outside text only after a prefix"

# ======================================================================= conf.sh
section "conf.sh"
C="$TMP/conf"; mkdir -p "$C"
printf 'A=1\n# B=2\nC = "quoted value"\nD='"'"'single'"'"'\nA=3\nnot a line\n' > "$C/x.conf"
expect_rc 0 "conf: last assignment wins" /bin/bash "$S/conf.sh" get "$C/x.conf" A
[ "$LAST_OUT" = 3 ] && ok "conf: A=3" || bad "conf: A=3 (got '$LAST_OUT')"
LAST_OUT=$(/bin/bash "$S/conf.sh" get "$C/x.conf" C); [ "$LAST_OUT" = "quoted value" ] && ok "conf: double quotes stripped" || bad "conf: double quotes ('$LAST_OUT')"
LAST_OUT=$(/bin/bash "$S/conf.sh" get "$C/x.conf" D); [ "$LAST_OUT" = "single" ] && ok "conf: single quotes stripped" || bad "conf: single quotes ('$LAST_OUT')"
LAST_OUT=$(/bin/bash "$S/conf.sh" get "$C/x.conf" B dflt); [ "$LAST_OUT" = "dflt" ] && ok "conf: comment ignored, default used" || bad "conf: default ('$LAST_OUT')"
LAST_OUT=$(/bin/bash "$S/conf.sh" get "$C/missing.conf" A); [ -z "$LAST_OUT" ] && ok "conf: missing file → empty" || bad "conf: missing file ('$LAST_OUT')"
expect_rc 2 "conf: usage error" /bin/bash "$S/conf.sh" get "$C/x.conf"
expect_rc 0 "conf: --help" /bin/bash "$S/conf.sh" --help

# ======================================================================= make-target.sh
section "make-target.sh"
M="$TMP/make"; mkdir -p "$M"
printf 'ok:\n\t@echo fine\nnc:\n\t@echo "not configured: fill in for your stack" >&2; exit 3\nthree:\n\t@echo "internal error"; exit 3\nfails:\n\t@exit 1\n' > "$M/Makefile"
out="$TMP/gh_output"
: > "$out"; expect_rc 0 "make-target: success" sh -c "cd '$M' && GITHUB_OUTPUT='$out' /bin/bash '$S/make-target.sh' ok"
expect_file_has "$out" '^status=ok$' "make-target: status=ok output"
: > "$out"; expect_rc 0 "make-target: exit 3 + 'not configured' → notice, success" sh -c "cd '$M' && GITHUB_ACTIONS=true GITHUB_OUTPUT='$out' /bin/bash '$S/make-target.sh' nc"
expect_out '^::notice::.*not configured' "make-target: prints a ::notice::"
expect_file_has "$out" '^status=not-configured$' "make-target: status=not-configured output"
: > "$out"; expect_rc 1 "make-target: exit 3 without 'not configured' is a failure" sh -c "cd '$M' && GITHUB_OUTPUT='$out' /bin/bash '$S/make-target.sh' three"
expect_file_has "$out" '^status=failed$' "make-target: status=failed output"
expect_rc 1 "make-target: failing target" sh -c "cd '$M' && /bin/bash '$S/make-target.sh' fails"
expect_rc 1 "make-target: missing target" sh -c "cd '$M' && /bin/bash '$S/make-target.sh' nosuchtarget"
expect_rc 1 "make-target: no Makefile" sh -c "cd '$TMP' && /bin/bash '$S/make-target.sh' build"
expect_rc 2 "make-target: bad target name" sh -c "cd '$M' && /bin/bash '$S/make-target.sh' 'a;b'"

# ======================================================================= package.sh
section "package.sh"
P="$TMP/pkg"; mkdir -p "$P/proj/art/assets" "$P/proj/ops"
echo page > "$P/proj/art/index.html"; echo css > "$P/proj/art/assets/a.css"; echo X=1 > "$P/proj/ops/project.conf"; echo 'rule|t|email|email' > "$P/proj/ops/anonymize"
expect_rc 0 "package: builds the tarball" sh -c "cd '$P/proj' && /bin/bash '$S/package.sh' art '$P/out/release-abc.tar.gz'"
LAST_OUT=$(tar -tzf "$P/out/release-abc.tar.gz" | sed 's|^\./||' | sort | tr '\n' ' ')
case "$LAST_OUT" in *"assets/a.css"*"index.html"*"ops/anonymize"*"ops/project.conf"*) ok "package: artifact contents + ops/ at the root" ;; *) bad "package: contents ($LAST_OUT)" ;; esac
mkdir -p "$P/proj/empty"
expect_rc 1 "package: refuses an empty artifact" sh -c "cd '$P/proj' && /bin/bash '$S/package.sh' empty '$P/out/x.tar.gz'"
expect_rc 1 "package: refuses a missing artifact dir" sh -c "cd '$P/proj' && /bin/bash '$S/package.sh' nope '$P/out/x.tar.gz'"
mkdir -p "$P/proj/art2/ops"; echo y > "$P/proj/art2/ops/x"
expect_rc 1 "package: refuses an artifact with its own ops/" sh -c "cd '$P/proj' && /bin/bash '$S/package.sh' art2 '$P/out/x.tar.gz'"
expect_rc 1 "package: refuses output inside the artifact" sh -c "cd '$P/proj' && /bin/bash '$S/package.sh' art art/x.tar.gz"
mkdir -p "$P/noops/art"; echo a > "$P/noops/art/a"
expect_rc 5 "package: needs ops/" sh -c "cd '$P/noops' && /bin/bash '$S/package.sh' art '$P/out/y.tar.gz'"

# ======================================================================= test-guard.sh
section "test-guard.sh"
# tg_case <name> <want-rc> <setup-fn> : base repo, then setup-fn changes it on a branch
tg_repo() {
  local d="$TMP/tg-$1"
  rm -rf "${d:?}"; mkdir -p "$d/tests" "$d/src" "$d/app/tests"
  printf 'it("adds", () => {\n  expect(add(1, 1)).toBe(2)\n})\n' > "$d/tests/math.test.js"
  printf 'func TestA(t *testing.T) {\n\tif got := A(); got != 1 {\n\t\tt.Errorf("got %%d", got)\n\t}\n}\n' > "$d/tests/a_test.go"
  printf 'it.skip("flaky one")\nit("other", () => {})\n' > "$d/tests/old.spec.js"
  printf 'def test_x():\n    assert x() == 1\n' > "$d/app/tests/test_x.py"
  echo 'export const add = (a, b) => a + b' > "$d/src/math.js"
  new_repo "$d" >/dev/null
  printf '%s' "$d"
}
d=$(tg_repo del); b=$(git -C "$d" rev-parse HEAD); git -C "$d" rm -q tests/a_test.go; commit_all "$d"
expect_rc 1 "test-guard: deleted test file fails" sh -c "cd '$d' && /bin/bash '$S/test-guard.sh' --base $b --head HEAD"
expect_out 'test file deleted: tests/a_test.go' "test-guard: names the deleted file"
d=$(tg_repo only); b=$(git -C "$d" rev-parse HEAD); sed -i.bak 's/^it("adds"/it.only("adds"/' "$d/tests/math.test.js"; rm -f "$d/tests/math.test.js.bak"; commit_all "$d"
expect_rc 1 "test-guard: added .only( fails" sh -c "cd '$d' && /bin/bash '$S/test-guard.sh' --base $b --head HEAD"
d=$(tg_repo disabled); b=$(git -C "$d" rev-parse HEAD); printf '@Disabled\nvoid testB() {}\n' > "$d/tests/BTest.java"; commit_all "$d"
expect_rc 1 "test-guard: added @Disabled (new file) fails" sh -c "cd '$d' && /bin/bash '$S/test-guard.sh' --base $b --head HEAD"
d=$(tg_repo skip); b=$(git -C "$d" rev-parse HEAD); printf 'func TestA(t *testing.T) {\n\tt.Skip("later")\n\tif got := A(); got != 1 {\n\t\tt.Errorf("got %%d", got)\n\t}\n}\n' > "$d/tests/a_test.go"; commit_all "$d"
expect_rc 1 "test-guard: added t.Skip( fails" sh -c "cd '$d' && /bin/bash '$S/test-guard.sh' --base $b --head HEAD"
d=$(tg_repo pyskip); b=$(git -C "$d" rev-parse HEAD); printf 'import pytest\n@pytest.mark.skip(reason="x")\ndef test_x():\n    assert x() == 1\n' > "$d/app/tests/test_x.py"; commit_all "$d"
expect_rc 1 "test-guard: added @pytest.mark.skip fails" sh -c "cd '$d' && /bin/bash '$S/test-guard.sh' --base $b --head HEAD"
d=$(tg_repo assert); b=$(git -C "$d" rev-parse HEAD); sed -i.bak 's/toBe(2)/toBe(3)/' "$d/tests/math.test.js"; rm -f "$d/tests/math.test.js.bak"; commit_all "$d"
: > "$out"; expect_rc 0 "test-guard: changed assertion passes" sh -c "cd '$d' && GITHUB_OUTPUT='$out' /bin/bash '$S/test-guard.sh' --base $b --head HEAD"
expect_file_has "$out" '^tests_changed=true$' "test-guard: changed assertion → tests_changed=true"
reset_gh
expect_rc 0 "test-guard: --label adds tests-changed" sh -c "cd '$d' && GITHUB_REPOSITORY=o/r /bin/bash '$S/test-guard.sh' --base $b --head HEAD --pr 7 --label"
expect_file_has "$STUB_GH_LOG" 'api -X POST repos/o/r/issues/7/labels -f labels\[\]=tests-changed' "test-guard: label call recorded"
reset_gh; export STUB_GH_WRITE_FAIL=1
expect_rc 0 "test-guard: read-only token degrades to a notice" sh -c "cd '$d' && GITHUB_REPOSITORY=o/r /bin/bash '$S/test-guard.sh' --base $b --head HEAD --pr 7 --label"
expect_out 'could not add label' "test-guard: notice names the label failure"
unset STUB_GH_WRITE_FAIL
d=$(tg_repo newtest); b=$(git -C "$d" rev-parse HEAD); printf 'it("subs", () => {\n  expect(sub(2, 1)).toBe(1)\n})\n' > "$d/tests/sub.test.js"; commit_all "$d"
: > "$out"; expect_rc 0 "test-guard: a new test file passes" sh -c "cd '$d' && GITHUB_OUTPUT='$out' /bin/bash '$S/test-guard.sh' --base $b --head HEAD"
expect_file_has "$out" '^tests_changed=false$' "test-guard: new assertions are not 'changed'"
d=$(tg_repo moved); b=$(git -C "$d" rev-parse HEAD); printf 'it("other", () => {})\nit.skip("flaky one")\n' > "$d/tests/old.spec.js"; commit_all "$d"
expect_rc 0 "test-guard: a moved existing skip line passes" sh -c "cd '$d' && /bin/bash '$S/test-guard.sh' --base $b --head HEAD"
d=$(tg_repo src); b=$(git -C "$d" rev-parse HEAD); echo 'items.only(1); describe.skip' >> "$d/src/math.js"; commit_all "$d"
expect_rc 0 "test-guard: markers outside test files are fine" sh -c "cd '$d' && /bin/bash '$S/test-guard.sh' --base $b --head HEAD"
d=$(tg_repo rename); b=$(git -C "$d" rev-parse HEAD); git -C "$d" mv tests/math.test.js src/math_check.js; commit_all "$d"
expect_rc 1 "test-guard: renaming a test out of the test paths fails" sh -c "cd '$d' && /bin/bash '$S/test-guard.sh' --base $b --head HEAD"
d=$(tg_repo scope); b=$(git -C "$d" rev-parse HEAD); git -C "$d" rm -q tests/a_test.go; commit_all "$d"
expect_rc 0 "test-guard: only looks inside the working directory" sh -c "cd '$d/app' && /bin/bash '$S/test-guard.sh' --base $b --head HEAD"
expect_rc 2 "test-guard: needs --base" sh -c "cd '$d' && /bin/bash '$S/test-guard.sh'"

# ======================================================================= pii-guard.sh
section "pii-guard.sh"
pii_repo() {
  local d="$TMP/pii-$1"
  rm -rf "${d:?}"; mkdir -p "$d/db/migrations" "$d/ops" "$d/src"
  printf 'MIGRATIONS_GLOB=db/migrations/** database/migrations/**\n' > "$d/ops/project.conf"
  printf 'rule|customers|email|email\n' > "$d/ops/anonymize"
  echo x > "$d/src/a"
  new_repo "$d" >/dev/null
  printf '%s' "$d"
}
d=$(pii_repo sql); b=$(git -C "$d" rev-parse HEAD)
printf 'CREATE TABLE customers (\n  id bigserial PRIMARY KEY,\n  email text NOT NULL,\n  phone_number varchar(20),\n  status text\n);\n-- the password column comes later\n' > "$d/db/migrations/001.sql"; commit_all "$d"
expect_rc 1 "pii-guard: a personal column without a rule fails" sh -c "cd '$d' && /bin/bash '$S/pii-guard.sh' --base $b --head HEAD"
expect_out "column 'phone_number'" "pii-guard: names the column"
expect_no_out "column 'password'" "pii-guard: comment lines are skipped"
expect_no_out "column 'email'" "pii-guard: a covered column passes"
printf 'rule|customers|phone_number|phone\n' >> "$d/ops/anonymize"; commit_all "$d"
expect_rc 0 "pii-guard: passes once ops/anonymize has a rule" sh -c "cd '$d' && /bin/bash '$S/pii-guard.sh' --base $b --head HEAD"
d=$(pii_repo ignore); b=$(git -C "$d" rev-parse HEAD)
printf 'ALTER TABLE users ADD COLUMN IF NOT EXISTS api_token text;\n' > "$d/db/migrations/002.sql"; printf 'ignore|*|api_token|hashed upstream\n' >> "$d/ops/anonymize"; commit_all "$d"
expect_rc 0 "pii-guard: an ignore entry (table *) passes" sh -c "cd '$d' && /bin/bash '$S/pii-guard.sh' --base $b --head HEAD"
d=$(pii_repo laravel); b=$(git -C "$d" rev-parse HEAD); mkdir -p "$d/database/migrations"
printf '<?php\nSchema::table("users", function (Blueprint $table) {\n    $table->string('"'"'mobile'"'"')->nullable();\n});\n' > "$d/database/migrations/2026_01_01_add_mobile.php"; commit_all "$d"
expect_rc 1 "pii-guard: DSL column (\$table->string('mobile')) is found" sh -c "cd '$d' && /bin/bash '$S/pii-guard.sh' --base $b --head HEAD"
d=$(pii_repo rails); b=$(git -C "$d" rev-parse HEAD)
printf 'class AddBirth < ActiveRecord::Migration[7.1]\n  def change\n    add_column :people, :birth_date, :date\n  end\nend\n' > "$d/db/migrations/20260101_add_birth.rb"; commit_all "$d"
expect_rc 1 "pii-guard: symbol column (:birth_date) is found" sh -c "cd '$d' && /bin/bash '$S/pii-guard.sh' --base $b --head HEAD"
d=$(pii_repo django); b=$(git -C "$d" rev-parse HEAD)
printf "migrations.AddField(\n    model_name='person',\n    name='home_address',\n    field=models.TextField(),\n)\n" > "$d/db/migrations/0002_person.py"; commit_all "$d"
expect_rc 1 "pii-guard: quoted column ('home_address') is found" sh -c "cd '$d' && /bin/bash '$S/pii-guard.sh' --base $b --head HEAD"
d=$(pii_repo safe); b=$(git -C "$d" rev-parse HEAD)
printf 'CREATE TABLE orders (\n  id bigserial,\n  total numeric(10,2),\n  status text\n);\nALTER TABLE users DROP COLUMN phone;\n' > "$d/db/migrations/003.sql"; commit_all "$d"
expect_rc 0 "pii-guard: no personal columns (drops don't count) passes" sh -c "cd '$d' && /bin/bash '$S/pii-guard.sh' --base $b --head HEAD"
d=$(pii_repo outside); b=$(git -C "$d" rev-parse HEAD); printf 'CREATE TABLE t (email text);\n' > "$d/src/schema.sql"; commit_all "$d"
expect_rc 0 "pii-guard: files outside MIGRATIONS_GLOB are ignored" sh -c "cd '$d' && /bin/bash '$S/pii-guard.sh' --base $b --head HEAD"
d=$(pii_repo noglob); printf 'MIGRATIONS_GLOB=\n' > "$d/ops/project.conf"; commit_all "$d"; b=$(git -C "$d" rev-parse HEAD)
printf 'CREATE TABLE t (email text);\n' > "$d/db/migrations/001.sql"; commit_all "$d"
expect_rc 0 "pii-guard: empty MIGRATIONS_GLOB → notice, pass" sh -c "cd '$d' && /bin/bash '$S/pii-guard.sh' --base $b --head HEAD"
expect_out 'MIGRATIONS_GLOB is empty' "pii-guard: says why it skipped"

# ======================================================================= anonymize-lint.sh
section "anonymize-lint.sh"
A="$TMP/anon"; mkdir -p "$A"
printf '# ok\nrule|customers|email|email\nrule|public.customers|full_name|name\nrule|customers|notes|redact|gone\nignore|*|created_by|system\ndevlogin|users|email|dev@example.test|password_hash=x;name=Dev\n' > "$A/ok"
expect_rc 0 "anonymize-lint: a valid file passes" /bin/bash "$S/anonymize-lint.sh" "$A/ok"
expect_rc 0 "anonymize-lint: the fixture's file passes" /bin/bash "$S/anonymize-lint.sh" "$ROOT/tests/fixture-project/ops/anonymize"
printf 'rule|c|e|bogus\n' > "$A/b1"; expect_rc 1 "anonymize-lint: unknown strategy" /bin/bash "$S/anonymize-lint.sh" "$A/b1"
printf 'rule|*|email|email\n' > "$A/b2"; expect_rc 1 "anonymize-lint: * table only in ignore" /bin/bash "$S/anonymize-lint.sh" "$A/b2"
printf 'ignore|c|x\n' > "$A/b3"; expect_rc 1 "anonymize-lint: ignore needs a reason" /bin/bash "$S/anonymize-lint.sh" "$A/b3"
printf 'devlogin|users|email|me@gmail.com|name=x\n' > "$A/b4"; expect_rc 1 "anonymize-lint: real email domain refused" /bin/bash "$S/anonymize-lint.sh" "$A/b4"
printf 'ignore|*|email|newsletter copy\n' > "$A/b5"; expect_rc 1 "anonymize-lint: a personal-looking column can't be ignored for every table" /bin/bash "$S/anonymize-lint.sh" "$A/b5"
printf 'ignore|*|full_name|x\n' > "$A/b6"; expect_rc 1 "anonymize-lint: ignore|*| refused for a name column too" /bin/bash "$S/anonymize-lint.sh" "$A/b6"
printf 'ignore|orders|email|test data only\n' > "$A/b7"; expect_rc 0 "anonymize-lint: a per-table ignore of a personal-looking column is allowed" /bin/bash "$S/anonymize-lint.sh" "$A/b7"
printf 'ignore|*|created_by_tool|not personal\n' > "$A/b8"; expect_rc 0 "anonymize-lint: ignore|*| is fine for a non-personal column" /bin/bash "$S/anonymize-lint.sh" "$A/b8"
printf 'rule|c|phone|phone\nignore|c|PHONE|dup\n' > "$A/b5"; expect_rc 1 "anonymize-lint: duplicate column" /bin/bash "$S/anonymize-lint.sh" "$A/b5"
printf 'rule|c|n|name|arg\n' > "$A/b6"; expect_rc 1 "anonymize-lint: only redact takes an arg" /bin/bash "$S/anonymize-lint.sh" "$A/b6"
expect_rc 3 "anonymize-lint: missing file → not configured" /bin/bash "$S/anonymize-lint.sh" "$A/none"

# ======================================================================= context-check.sh
section "context-check.sh"
expect_rc 0 "context: the committed fixture passes (unreleased lock)" sh -c "cd '$ROOT/tests/fixture-project' && /bin/bash '$S/context-check.sh' --allow-unreleased-lock --standards-dir '$ROOT'"
expect_rc 0 "context: sync-fixture --check (fixture matches managed/)" /bin/bash "$ROOT/tests/ci/sync-fixture.sh" --check
# cx <name> : a fresh copy of the fixture
cx() { local d="$TMP/cx-$1"; rm -rf "${d:?}"; cp -R "$ROOT/tests/fixture-project" "$d"; printf '%s' "$d"; }
relock() { # relock <dir> <release> : rewrite lock hashes for the copy's current files
  local d="$1" rel="$2" p h tmpl="$TMP/lock.json"
  jq --arg r "$rel" '.release = $r' "$d/.claude/team-standards.lock" > "$tmpl"
  for p in $(jq -r '.files | keys[]' "$tmpl"); do
    h="sha256:$(shasum -a 256 "$d/$p" 2>/dev/null | awk '{print $1}')"
    [ "$h" != "sha256:" ] || h="sha256:$(sha256sum "$d/$p" | awk '{print $1}')"
    jq --arg p "$p" --arg h "$h" '.files[$p] = $h' "$tmpl" > "$tmpl.2" && mv "$tmpl.2" "$tmpl"
  done
  cp "$tmpl" "$d/.claude/team-standards.lock"
}
printf 'v0.9.0\nv1.0.0\nv1\n' > "$TMP/tags-1.0"
printf 'v1.0.0\nv1.1.0\nv1\n' > "$TMP/tags-1.1"
d=$(cx real); relock "$d" v1.0.0
expect_rc 0 "context: a real release tag passes" sh -c "cd '$d' && /bin/bash '$S/context-check.sh' --tags-from '$TMP/tags-1.0'"
expect_rc 0 "context: a newer release is only a notice" sh -c "cd '$d' && /bin/bash '$S/context-check.sh' --tags-from '$TMP/tags-1.1'"
expect_out 'v1.1.0 is out' "context: the notice names the newer release"
d=$(cx unknown); relock "$d" v9.9.9
expect_rc 1 "context: an unknown release fails" sh -c "cd '$d' && /bin/bash '$S/context-check.sh' --tags-from '$TMP/tags-1.1'"
d=$(cx unrel)
expect_rc 1 "context: 'unreleased' without the flag fails" sh -c "cd '$d' && /bin/bash '$S/context-check.sh' --tags-from '$TMP/tags-1.1'"
d=$(cx long); awk 'BEGIN { print "# long"; for (i = 1; i < 200; i++) print "- line " i }' > "$d/CLAUDE.md"
expect_rc 1 "context: a 200-line CLAUDE.md fails" sh -c "cd '$d' && /bin/bash '$S/context-check.sh' --allow-unreleased-lock --standards-dir '$ROOT'"
expect_out 'CLAUDE.md has 200 lines' "context: names the line count"
d=$(cx import); printf '\nSee @docs/flags.md for flags.\n' >> "$d/CLAUDE.md"
expect_rc 1 "context: an @ import fails" sh -c "cd '$d' && /bin/bash '$S/context-check.sh' --allow-unreleased-lock --standards-dir '$ROOT'"
d=$(cx noimport); printf '\nMail dev@example.test. Code: `@docs/x.md`.\n\n```\n@not/an/import\n```\n' >> "$d/CLAUDE.md"
expect_rc 0 "context: emails, code spans and fenced blocks aren't imports" sh -c "cd '$d' && /bin/bash '$S/context-check.sh' --allow-unreleased-lock --standards-dir '$ROOT'"
d=$(cx missing); printf -- '- `docs/runbooks/deploy.md` — how to deploy.\n' >> "$d/CLAUDE.md"
expect_rc 1 "context: a missing referenced path fails" sh -c "cd '$d' && /bin/bash '$S/context-check.sh' --allow-unreleased-lock --standards-dir '$ROOT'"
expect_out 'docs/runbooks/deploy.md' "context: names the missing path"
d=$(cx skips); printf -- '- Skips: `/team:ship`, `origin/main`, `owner/repo`, `~/.config/team/`, `.team/evidence/<pr>/`, `.team/`, `.env`, `.claude/worktrees/x`, `src/**`, `<type>/<issue>-<slug>`, `git merge origin/main`.\n' >> "$d/CLAUDE.md"
expect_rc 0 "context: skill names, refs, home, local, placeholder and glob paths are skipped" sh -c "cd '$d' && /bin/bash '$S/context-check.sh' --allow-unreleased-lock --standards-dir '$ROOT'"
d=$(cx tamper); printf '\n- extra line\n' >> "$d/.claude/rules/team/team.md"
expect_rc 1 "context: a tampered managed file fails" sh -c "cd '$d' && /bin/bash '$S/context-check.sh' --allow-unreleased-lock --standards-dir '$ROOT'"
expect_out 'managed file changed: .claude/rules/team/team.md' "context: names the tampered file"
d=$(cx extra); printf '# extra\n' > "$d/.claude/rules/team/extra.md"
expect_rc 1 "context: an unpinned file in .claude/rules/team fails" sh -c "cd '$d' && /bin/bash '$S/context-check.sh' --allow-unreleased-lock --standards-dir '$ROOT'"
d=$(cx teamlong); awk 'BEGIN { for (i = 0; i < 61; i++) print "- team line " i }' > "$d/.claude/rules/team/team.md"; relock "$d" v1.0.0
expect_rc 1 "context: a team rule over 60 lines fails" sh -c "cd '$d' && /bin/bash '$S/context-check.sh' --tags-from '$TMP/tags-1.0'"
d=$(cx rulelong); { printf -- '---\npaths:\n  - "src/**"\n---\n'; awk 'BEGIN { for (i = 0; i < 80; i++) print "- rule line " i }'; } > "$d/.claude/rules/project/big.md"
expect_rc 1 "context: a project rule over 80 lines fails" sh -c "cd '$d' && /bin/bash '$S/context-check.sh' --allow-unreleased-lock --standards-dir '$ROOT'"
d=$(cx always); awk 'BEGIN { print "# p"; for (i = 1; i < 140; i++) print "- l " i }' > "$d/CLAUDE.md"; awk 'BEGIN { for (i = 0; i < 79; i++) print "- always " i }' > "$d/.claude/rules/project/always.md"
expect_rc 1 "context: always-loaded total over 250 fails" sh -c "cd '$d' && /bin/bash '$S/context-check.sh' --allow-unreleased-lock --standards-dir '$ROOT'"
expect_out 'always-loaded context .* is 250|always-loaded context .* is 2[5-9][0-9]' "context: names the total"
d=$(cx scoped); awk 'BEGIN { print "# p"; for (i = 1; i < 140; i++) print "- l " i }' > "$d/CLAUDE.md"; { printf -- '---\npaths:\n  - "src/**"\n---\n'; awk 'BEGIN { for (i = 0; i < 75; i++) print "- scoped " i }'; } > "$d/.claude/rules/project/scoped.md"
expect_rc 0 "context: path-scoped rules don't count as always-loaded" sh -c "cd '$d' && /bin/bash '$S/context-check.sh' --allow-unreleased-lock --standards-dir '$ROOT'"
d=$(cx nolock); rm -f "$d/.claude/team-standards.lock"
expect_rc 1 "context: a missing lock fails" sh -c "cd '$d' && /bin/bash '$S/context-check.sh' --allow-unreleased-lock --standards-dir '$ROOT'"
d=$(cx drift); SD="$TMP/fake-standards"; rm -rf "${SD:?}"; mkdir -p "$SD"; cp -R "$ROOT/managed" "$SD/managed"; printf '\n- new managed line\n' >> "$SD/managed/.claude/rules/team/team.md"
expect_rc 1 "context: unreleased lock that differs from managed/ fails" sh -c "cd '$d' && /bin/bash '$S/context-check.sh' --allow-unreleased-lock --standards-dir '$SD'"
# standards-self
ss() {
  local d="$TMP/ss-$1"; rm -rf "${d:?}"; mkdir -p "$d/.claude/rules/team" "$d/.claude/rules/project" "$d/managed/.claude/rules/team" "$d/docs" "$d/plugins/team/bin"
  cp "$ROOT/managed/.claude/rules/team/"* "$d/managed/.claude/rules/team/"
  cp "$ROOT/managed/.claude/rules/team/"* "$d/.claude/rules/team/"
  printf '# dev-standards\n\n- Machine values live in `~/.config/team/`.\n- `plugins/team/` — `bin/` commands. Contract: `docs/rules.md`.\n' > "$d/CLAUDE.md"
  echo x > "$d/docs/rules.md"
  printf -- '---\npaths:\n  - "plugins/**"\n---\n# x\n- See `docs/rules.md`.\n' > "$d/.claude/rules/project/x.md"
  printf '%s' "$d"
}
d=$(ss ok)
expect_rc 0 "standards-self: a lean repo with the managed team rule passes" /bin/bash "$S/context-check.sh" --standards-self --root "$d"
expect_no_out 'config/team' "standards-self: home paths are never checked"
d=$(ss differ); printf -- '- local edit\n' >> "$d/.claude/rules/team/team.md"
expect_rc 1 "standards-self: a team rule that differs from managed/ fails" /bin/bash "$S/context-check.sh" --standards-self --root "$d"
d=$(ss empty); rm -f "$d/.claude/rules/team/"*
expect_rc 1 "standards-self: a missing team rule fails" /bin/bash "$S/context-check.sh" --standards-self --root "$d"
d=$(ss long); awk 'BEGIN { for (i = 0; i < 151; i++) print "- l " i }' > "$d/CLAUDE.md"
expect_rc 1 "standards-self: a 151-line CLAUDE.md fails" /bin/bash "$S/context-check.sh" --standards-self --root "$d"
d=$(ss path); printf -- '- `scripts/ci/nothing.sh`\n' >> "$d/CLAUDE.md"
expect_rc 1 "standards-self: a missing path fails" /bin/bash "$S/context-check.sh" --standards-self --root "$d"
d=$(ss imp); printf -- '- @docs/rules.md\n' >> "$d/CLAUDE.md"
expect_rc 1 "standards-self: an @ import fails" /bin/bash "$S/context-check.sh" --standards-self --root "$d"

# ======================================================================= guarded-paths.sh
section "guarded-paths.sh (globs)"
(
  # shellcheck source=../../scripts/ci/common.sh
  . "$S/common.sh"
  g=()
  while IFS= read -r x; do g+=("$x"); done < <(ci_list "$ROOT/config/guarded-globs.txt")
  for p in .claude/settings.json .claude/rules/team/team.md CLAUDE.md docs/CLAUDE.md .github/workflows/ci.yml .githooks/pre-push Makefile ops/project.conf ops/env/staging.env.tmpl .mcp.json; do
    if ci_path_matches "$p" "${g[@]}"; then echo "PASS  glob: $p is guarded"; else echo "FAIL  glob: $p should be guarded"; fi
  done
  for p in src/app.js sub/Makefile docs/README.md tests/a.test.js opsx/file CLAUDE.md.bak .mcp.json.bak; do
    if ci_path_matches "$p" "${g[@]}"; then echo "FAIL  glob: $p should not be guarded"; else echo "PASS  glob: $p is not guarded"; fi
  done
  for c in 'db/migrations/**|db/migrations/001.sql|0' 'db/migrations/**|db/migrations/a/b.sql|0' 'db/migrations/**|db/other.sql|1' \
           'src/*.js|src/a.js|0' 'src/*.js|src/a/b.js|1' '**/*.test.*|a/b/c.test.js|0' '**/*.test.*|c.test.js|0' 'a?.txt|ab.txt|0' 'a.txt|abtxt|1'; do
    pat="${c%%|*}"; rest="${c#*|}"; p="${rest%%|*}"; expected="${rest#*|}"
    if ci_path_matches "$p" "$pat"; then got=0; else got=1; fi
    if [ "$got" = "$expected" ]; then echo "PASS  glob: '$pat' vs $p"; else echo "FAIL  glob: '$pat' vs $p (got $got)"; fi
  done
) > "$TMP/glob-results"
while IFS= read -r line; do case "$line" in PASS*) ok "${line#PASS  }" ;; FAIL*) bad "${line#FAIL  }" ;; esac; done < "$TMP/glob-results"

section "guarded-paths.sh (decisions, recorded API JSON)"
gp_repo() {
  local d="$TMP/gp-$1"
  rm -rf "${d:?}"; mkdir -p "$d/db/migrations" "$d/ops" "$d/src/auth" "$d/docs"
  printf 'MIGRATIONS_GLOB=db/migrations/**\nHIGH_RISK_GLOBS=src/auth/**\n' > "$d/ops/project.conf"
  printf 'CREATE TABLE t (id int);\n' > "$d/db/migrations/001.sql"
  echo all: > "$d/Makefile"; echo x > "$d/src/a.js"; echo x > "$d/src/auth/login.js"; echo x > "$d/docs/README.md"
  new_repo "$d" >/dev/null
  printf '%s' "$d"
}
# gp <dir> <base> <event> [profile] : run the gate as PR #5 of o/r, owner "Owner"
gp() { (cd "$1" && GITHUB_REPOSITORY=o/r GITHUB_OUTPUT="$out" /bin/bash "$S/guarded-paths.sh" --pr 5 --base "$2" --head HEAD --event "$3" --owner Owner --profile "${4:-project}"); }
labels() { gh_data repos/o/r/issues/5 "{\"labels\":[$1]}"; }
events() { gh_data repos/o/r/issues/5/events "$1"; }
suites() { gh_data "repos/o/r/commits/$1/check-suites" "{\"check_suites\":[{\"created_at\":\"$2\"},{\"created_at\":\"2026-10-09T12:00:00Z\"}]}"; }
EV_OWNER='[{"event":"labeled","actor":{"login":"owner"},"label":{"name":"owner-approved"},"created_at":"2026-10-09T10:00:00Z"}]'
EV_OTHER='[{"event":"labeled","actor":{"login":"agent-bot"},"label":{"name":"owner-approved"},"created_at":"2026-10-09T10:00:00Z"}]'
EV_UNLAB='[{"event":"labeled","actor":{"login":"Owner"},"label":{"name":"owner-approved"},"created_at":"2026-10-09T10:00:00Z"},{"event":"unlabeled","actor":{"login":"Owner"},"label":{"name":"owner-approved"},"created_at":"2026-10-09T10:05:00Z"}]'
OA='{"name":"owner-approved"}'

d=$(gp_repo plain); b=$(git -C "$d" rev-parse HEAD); echo y >> "$d/src/a.js"; commit_all "$d"; h=$(git -C "$d" rev-parse HEAD)
reset_gh; labels ''; : > "$out"
expect_rc 0 "gate: an ordinary change is not guarded" gp "$d" "$b" opened
expect_file_has "$out" '^guarded=false$' "gate: guarded=false output"
expect_file_lacks "$STUB_GH_LOG" 'labels\[\]=guarded' "gate: no guarded label added"

d=$(gp_repo mk); b=$(git -C "$d" rev-parse HEAD); echo 'x:' >> "$d/Makefile"; commit_all "$d"; h=$(git -C "$d" rev-parse HEAD)
reset_gh; labels ''
expect_rc 1 "gate: Makefile change without owner-approved fails" gp "$d" "$b" opened
expect_file_has "$STUB_GH_LOG" 'issues/5/labels -f labels\[\]=guarded' "gate: adds the guarded label"
reset_gh; labels "$OA"; events "$EV_OWNER"; suites "$h" 2026-10-09T09:00:00Z
expect_rc 0 "gate: owner-approved by the owner after the push passes" gp "$d" "$b" labeled
reset_gh; labels "$OA"; events "$EV_OTHER"; suites "$h" 2026-10-09T09:00:00Z
expect_rc 1 "gate: owner-approved added by someone else fails" gp "$d" "$b" labeled
expect_file_has "$STUB_GH_LOG" 'api -X DELETE repos/o/r/issues/5/labels/owner-approved' "gate: removes a non-owner approval"
reset_gh; labels ''; events "$EV_UNLAB"; suites "$h" 2026-10-09T09:00:00Z
expect_rc 1 "gate: approval removed again fails" gp "$d" "$b" unlabeled
reset_gh; labels "$OA"; events "$EV_OWNER"; suites "$h" 2026-10-09T11:00:00Z
expect_rc 1 "gate: an approval older than the latest commit fails" gp "$d" "$b" labeled
expect_out 'predates the latest commits' "gate: says the approval is stale"
expect_file_has "$STUB_GH_LOG" 'DELETE repos/o/r/issues/5/labels/owner-approved' "gate: removes the stale approval"
reset_gh; labels "$OA"; events "$EV_OWNER"; suites "$h" 2026-10-09T09:00:00Z
expect_rc 1 "gate: synchronize (new commits) removes owner-approved and fails" gp "$d" "$b" synchronize
expect_file_has "$STUB_GH_LOG" 'DELETE repos/o/r/issues/5/labels/owner-approved' "gate: synchronize removal recorded"
reset_gh; labels "$OA"; events "$EV_OWNER"; gh_data "repos/o/r/commits/$h/check-suites" '{"check_suites":[]}'
expect_rc 1 "gate: unknown commit arrival time fails closed" gp "$d" "$b" labeled
reset_gh; labels ''; export STUB_GH_WRITE_FAIL=1
expect_rc 1 "gate: read-only token still decides (label write → notice)" gp "$d" "$b" opened
expect_out 'could not add label' "gate: read-only notice"
unset STUB_GH_WRITE_FAIL
reset_gh; : > "$out"
expect_rc 0 "gate: --labels-json/--events-json/--suites-json work offline" sh -c "cd '$d' && printf '[\"owner-approved\"]' > '$TMP/l.json' && printf '%s' '$EV_OWNER' > '$TMP/e.json' && printf '{\"check_suites\":[{\"created_at\":\"2026-10-09T09:30:00Z\"}]}' > '$TMP/s.json' && GITHUB_REPOSITORY=o/r GITHUB_OUTPUT='$out' /bin/bash '$S/guarded-paths.sh' --pr 5 --base $b --head HEAD --event labeled --owner OWNER --labels-json '$TMP/l.json' --events-json '$TMP/e.json' --suites-json '$TMP/s.json'"
expect_file_has "$out" '^approved=true$' "gate: approved=true output (login case-insensitive)"

d=$(gp_repo drop); b=$(git -C "$d" rev-parse HEAD); printf 'ALTER TABLE t DROP COLUMN name;\n' > "$d/db/migrations/002.sql"; commit_all "$d"
reset_gh; labels ''
expect_rc 1 "gate: a destructive migration is guarded" gp "$d" "$b" opened
expect_out 'destructive migration' "gate: names the destructive migration"
d=$(gp_repo create); b=$(git -C "$d" rev-parse HEAD); printf 'CREATE TABLE u (id int);\nALTER TABLE t ADD COLUMN note text;\n' > "$d/db/migrations/002.sql"; commit_all "$d"
reset_gh; labels ''
expect_rc 0 "gate: an expand-only migration is not guarded" gp "$d" "$b" opened
d=$(gp_repo delmig); b=$(git -C "$d" rev-parse HEAD); git -C "$d" rm -q db/migrations/001.sql; commit_all "$d"
reset_gh; labels ''
expect_rc 1 "gate: deleting a migration is guarded" gp "$d" "$b" opened
d=$(gp_repo baseconf); b=$(git -C "$d" rev-parse HEAD); printf 'MIGRATIONS_GLOB=nothing/**\n' > "$d/ops/project.conf"; printf 'DROP TABLE t;\n' > "$d/db/migrations/003.sql"; commit_all "$d"
reset_gh; labels ''
expect_rc 1 "gate: uses the BASE commit's MIGRATIONS_GLOB" gp "$d" "$b" opened
expect_out 'db/migrations/003.sql \(destructive' "gate: base glob still catches the drop"
d=$(gp_repo risk); b=$(git -C "$d" rev-parse HEAD); echo y >> "$d/src/auth/login.js"; commit_all "$d"
reset_gh; labels ''; : > "$out"
expect_rc 0 "gate: high-risk alone passes" gp "$d" "$b" opened
expect_file_has "$STUB_GH_LOG" 'labels\[\]=high-risk' "gate: adds the high-risk label"
expect_file_has "$out" '^high_risk=true$' "gate: high_risk=true output"
d=$(gp_repo std); b=$(git -C "$d" rev-parse HEAD); echo y >> "$d/docs/README.md"; commit_all "$d"
reset_gh; labels ''
expect_rc 1 "gate: profile standards guards every path" gp "$d" "$b" opened standards
expect_rc 0 "gate: not a pull request → notice" sh -c "cd '$d' && /bin/bash '$S/guarded-paths.sh' --base $b --head HEAD"

# ======================================================================= stop-the-line.sh
section "stop-the-line.sh"
reset_gh
gh_data repos/o/r/issues '[{"number":12,"title":"main is red"}]'; gh_data repos/o/r/issues/5 '{"labels":[{"name":"bug"}]}'
expect_rc 1 "stop-the-line: open main-red blocks a normal PR" env GITHUB_REPOSITORY=o/r /bin/bash "$S/stop-the-line.sh" --pr 5
expect_out 'issue #12' "stop-the-line: names the issue"
gh_data repos/o/r/issues/5 '{"labels":[{"name":"fixes-main"}]}'
expect_rc 0 "stop-the-line: a fixes-main PR may go ahead" env GITHUB_REPOSITORY=o/r /bin/bash "$S/stop-the-line.sh" --pr 5
gh_data repos/o/r/issues '[{"number":13,"pull_request":{"url":"x"}}]'
expect_rc 0 "stop-the-line: a labelled PR (not an issue) doesn't count" env GITHUB_REPOSITORY=o/r /bin/bash "$S/stop-the-line.sh" --pr 5
gh_data repos/o/r/issues '[]'
expect_rc 0 "stop-the-line: green main passes" env GITHUB_REPOSITORY=o/r /bin/bash "$S/stop-the-line.sh" --pr 5
printf '[{"number":3}]' > "$TMP/i.json"; printf '["needs-info"]' > "$TMP/lb.json"
expect_rc 1 "stop-the-line: --issues-json/--labels-json offline" /bin/bash "$S/stop-the-line.sh" --pr 5 --issues-json "$TMP/i.json" --labels-json "$TMP/lb.json"
rm -f "$STUB_GH_DATA/repos_o_r_issues.json"
expect_rc 1 "stop-the-line: an API failure fails closed" env GITHUB_REPOSITORY=o/r /bin/bash "$S/stop-the-line.sh" --pr 5
expect_rc 2 "stop-the-line: needs --pr" /bin/bash "$S/stop-the-line.sh"

# ======================================================================= main-red.sh
section "main-red.sh"
reset_gh; gh_data repos/o/r/issues '[]'
expect_rc 0 "main-red: open creates the issue" env GITHUB_REPOSITORY=o/r GITHUB_SHA=0123456789abcdef0123456789abcdef01234567 GITHUB_RUN_ID=42 PROJECT_TIMEZONE=Asia/Manila /bin/bash "$S/main-red.sh" open
expect_file_has "$STUB_GH_LOG" 'api -X POST repos/o/r/issues -f title=main is red .*labels\[\]=main-red' "main-red: POST issue with the main-red label"
expect_file_has "$STUB_GH_LOG" 'Asia/Manila \([0-9]{2}:[0-9]{2} UTC\)' "main-red: the time names the project timezone"
expect_file_has "$STUB_GH_LOG" 'actions/runs/42' "main-red: links the run"
reset_gh; gh_data repos/o/r/issues '[{"number":12}]'
expect_rc 0 "main-red: open with one open comments instead" env GITHUB_REPOSITORY=o/r /bin/bash "$S/main-red.sh" open
expect_file_has "$STUB_GH_LOG" 'POST repos/o/r/issues/12/comments' "main-red: comment on #12"
expect_file_lacks "$STUB_GH_LOG" 'title=main is red' "main-red: no second issue"
reset_gh; gh_data repos/o/r/issues '[{"number":12}]'
expect_rc 0 "main-red: close comments and closes" env GITHUB_REPOSITORY=o/r PROJECT_TIMEZONE=America/New_York /bin/bash "$S/main-red.sh" close
expect_file_has "$STUB_GH_LOG" 'PATCH repos/o/r/issues/12 -f state=closed' "main-red: closes #12"
expect_file_has "$STUB_GH_LOG" 'America/New_York' "main-red: close comment names the timezone"
reset_gh; gh_data repos/o/r/issues '[]'
expect_rc 0 "main-red: close with nothing open is a no-op" env GITHUB_REPOSITORY=o/r /bin/bash "$S/main-red.sh" close
expect_file_lacks "$STUB_GH_LOG" 'PATCH' "main-red: nothing closed"
expect_rc 2 "main-red: usage error" env GITHUB_REPOSITORY=o/r /bin/bash "$S/main-red.sh" maybe

# ======================================================================= incident.sh
section "incident.sh"
echo ok > "$TMP/health-ok"
reset_gh; gh_data repos/o/r/issues '[]'
expect_rc 1 "incident: two failed checks open an incident" env GITHUB_REPOSITORY=o/r INCIDENT_INTERVAL=0 HEALTH_URL="file://$TMP/health-missing" PROJECT_TIMEZONE=Asia/Manila /bin/bash "$S/incident.sh" check
expect_file_has "$STUB_GH_LOG" 'POST repos/o/r/issues .*labels\[\]=incident' "incident: POST issue with the incident label"
expect_file_has "$STUB_GH_LOG" 'Asia/Manila' "incident: the time names the project timezone"
expect_no_out 'health-missing' "incident: never prints the health URL"
reset_gh; gh_data repos/o/r/issues '[{"number":7}]'
expect_rc 1 "incident: still down, one incident only" env GITHUB_REPOSITORY=o/r INCIDENT_INTERVAL=0 HEALTH_URL="file://$TMP/health-missing" /bin/bash "$S/incident.sh" check
expect_file_lacks "$STUB_GH_LOG" 'title=' "incident: no second issue"
reset_gh; gh_data repos/o/r/issues '[{"number":7}]'
expect_rc 0 "incident: recovery closes the incident" env GITHUB_REPOSITORY=o/r INCIDENT_INTERVAL=0 HEALTH_URL="file://$TMP/health-ok" PROJECT_TIMEZONE=Asia/Manila /bin/bash "$S/incident.sh" check
expect_file_has "$STUB_GH_LOG" 'PATCH repos/o/r/issues/7 -f state=closed' "incident: closes #7"
expect_file_has "$STUB_GH_LOG" 'Recovered.*Asia/Manila' "incident: recovery comment names the timezone"
reset_gh; gh_data repos/o/r/issues '[]'
expect_rc 0 "incident: healthy with nothing open" env GITHUB_REPOSITORY=o/r INCIDENT_INTERVAL=0 HEALTH_URL="file://$TMP/health-ok" /bin/bash "$S/incident.sh" check
expect_rc 3 "incident: no HEALTH_URL → not configured" env GITHUB_REPOSITORY=o/r /bin/bash "$S/incident.sh" check

# ======================================================================= smoke.sh
section "smoke.sh (stub curl)"
export STUB_CURL_LOG="$TMP/curl.log"
: > "$STUB_CURL_LOG"
expect_rc 0 "smoke: 200 passes" env PATH="$ALL_PATH" STUB_CURL_CODE=200 SMOKE_ATTEMPTS=2 SMOKE_DELAY=0 /bin/bash "$S/smoke.sh" https://staging.example.test/health
expect_rc 1 "smoke: 503 fails after the retries" env PATH="$ALL_PATH" STUB_CURL_CODE=503 SMOKE_ATTEMPTS=2 SMOKE_DELAY=0 /bin/bash "$S/smoke.sh" https://staging.example.test/health
expect_no_out 'staging.example.test' "smoke: never prints the URL"
expect_rc 0 "smoke: --noindex with the header passes" env PATH="$ALL_PATH" STUB_CURL_CODE=200 STUB_CURL_HEADER='X-Robots-Tag: noindex, nofollow' SMOKE_ATTEMPTS=1 /bin/bash "$S/smoke.sh" https://staging.example.test/health --noindex
expect_rc 1 "smoke: --noindex without the header fails" env PATH="$ALL_PATH" STUB_CURL_CODE=200 SMOKE_ATTEMPTS=1 /bin/bash "$S/smoke.sh" https://staging.example.test/health --noindex
: > "$STUB_CURL_LOG"
expect_rc 0 "smoke: basic auth" env PATH="$ALL_PATH" STUB_CURL_CODE=200 SMOKE_ATTEMPTS=1 BASIC_AUTH_USER=client BASIC_AUTH_PASSWORD='p"w\d' /bin/bash "$S/smoke.sh" https://staging.example.test/health
expect_file_lacks "$STUB_CURL_LOG" '^args:.*p"w' "smoke: the password is not on the command line"
expect_file_has "$STUB_CURL_LOG" '^config: user = "client:p\\"w\\\\d"' "smoke: the password goes through a curl config file"
expect_rc 3 "smoke: an empty URL is not configured" env PATH="$ALL_PATH" /bin/bash "$S/smoke.sh" ""

# ======================================================================= deploy.sh
section "deploy.sh (stub ssh)"
export STUB_SSH_LOG="$TMP/ssh.log"
SHA=0123456789abcdef0123456789abcdef01234567
mkdir -p "$TMP/dep"; head -c 2048 /dev/zero > "$TMP/dep/release-$SHA.tar.gz"
dep_env() { env PATH="$ALL_PATH" NET_GUARD_SIMULATOR="$STUB/sim" RUNNER_TEMP="$TMP/dep" DEPLOY_HOST=deploy.example.test DEPLOY_USER=app-staging DEPLOY_PORT=2222 DEPLOY_SSH_KEY='fake-key-for-tests' DEPLOY_KNOWN_HOSTS='[deploy.example.test]:2222 ssh-ed25519 AAAAfake' "$@"; }
: > "$STUB_SSH_LOG"
expect_rc 0 "deploy: streams the tarball to 'deploy <sha>'" dep_env /bin/bash "$S/deploy.sh" staging "$TMP/dep/release-$SHA.tar.gz"
expect_file_has "$STUB_SSH_LOG" "\[app-staging@deploy.example.test\] \[deploy $SHA\]" "deploy: forced-command form 'deploy <sha>'"
expect_file_has "$STUB_SSH_LOG" '\[StrictHostKeyChecking=yes\]' "deploy: StrictHostKeyChecking=yes"
expect_file_lacks "$STUB_SSH_LOG" 'StrictHostKeyChecking=no' "deploy: never StrictHostKeyChecking=no"
expect_file_has "$STUB_SSH_LOG" '\[-F\] \[/dev/null\]' "deploy: ignores ssh config files"
expect_file_has "$STUB_SSH_LOG" '\[-p\] \[2222\]' "deploy: uses DEPLOY_PORT"
expect_file_has "$STUB_SSH_LOG" '^keymode: 600$' "deploy: key file is mode 600"
expect_file_has "$STUB_SSH_LOG" '^stdin-bytes: 2048$' "deploy: the whole tarball goes on stdin"
kf=$(sed -n 's/^keyfile: //p' "$STUB_SSH_LOG" | head -n 1)
[ -n "$kf" ] && [ ! -e "$kf" ] && ok "deploy: key file removed afterwards" || bad "deploy: key file removed afterwards ($kf)"
: > "$STUB_SSH_LOG"
expect_rc 7 "deploy: rollback passes exit 7 (not on the server) through" dep_env STUB_SSH_EXIT=7 /bin/bash "$S/deploy.sh" production --rollback "$SHA"
expect_file_has "$STUB_SSH_LOG" "\[rollback $SHA\]" "deploy: forced-command form 'rollback <sha>'"
expect_file_has "$STUB_SSH_LOG" '^stdin-bytes: 0$' "deploy: rollback sends nothing on stdin"
expect_rc 3 "deploy: a missing secret is not configured" env PATH="$ALL_PATH" DEPLOY_HOST=h /bin/bash "$S/deploy.sh" staging "$TMP/dep/release-$SHA.tar.gz"
expect_rc 2 "deploy: a bad sha is a usage error" dep_env /bin/bash "$S/deploy.sh" production --rollback 'abc;rm'
expect_rc 2 "deploy: a bad env is a usage error" dep_env /bin/bash "$S/deploy.sh" prod "$TMP/dep/release-$SHA.tar.gz"
expect_rc 1 "deploy: a host with odd characters is refused" dep_env DEPLOY_HOST='-oProxyCommand=x' /bin/bash "$S/deploy.sh" staging "$TMP/dep/release-$SHA.tar.gz"
expect_file_has "$NET_GUARD_LOG" "ssh	.*app-staging@deploy.example.test deploy $SHA" "net-guard: deploy's ssh went through the guard's fake"
: > "$STUB_SSH_LOG"
expect_rc 255 "net-guard: without a simulator the fake refuses deploy's ssh" env PATH="$ALL_PATH" RUNNER_TEMP="$TMP/dep" DEPLOY_HOST=deploy.example.test DEPLOY_USER=app-staging DEPLOY_SSH_KEY=k DEPLOY_KNOWN_HOSTS=h /bin/bash "$S/deploy.sh" staging --health
[ ! -s "$STUB_SSH_LOG" ] && ok "net-guard: nothing reached the simulator without opting in" || bad "net-guard: the simulator ran without opting in"

# ======================================================================= gitleaks.sh
section "gitleaks.sh (offline)"
G="$TMP/gl"; mkdir -p "$G/bin"; printf '#!/bin/sh\necho RAN > "%s/ran"\n' "$G" > "$G/bin/gitleaks"; chmod +x "$G/bin/gitleaks"
tar -czf "$G/fake.tar.gz" -C "$G/bin" gitleaks
expect_rc 1 "gitleaks: a tarball with the wrong SHA-256 is refused" /bin/bash "$S/gitleaks.sh" verify --tarball "$G/fake.tar.gz"
expect_out 'checksum mismatch' "gitleaks: says checksum mismatch"
d=$(tg_repo gl); b=$(git -C "$d" rev-parse HEAD); echo y >> "$d/src/math.js"; commit_all "$d"
expect_rc 1 "gitleaks: git mode never runs an unverified binary" sh -c "cd '$d' && /bin/bash '$S/gitleaks.sh' git --base $b --tarball '$G/fake.tar.gz'"
[ ! -e "$G/ran" ] && ok "gitleaks: the unverified binary did not run" || bad "gitleaks: the unverified binary ran"
good=$(shasum -a 256 "$G/fake.tar.gz" 2>/dev/null | awk '{print $1}'); [ -n "$good" ] || good=$(sha256sum "$G/fake.tar.gz" | awk '{print $1}')
expect_rc 0 "gitleaks: a matching SHA-256 verifies" env GITLEAKS_SHA256="$good" /bin/bash "$S/gitleaks.sh" verify --tarball "$G/fake.tar.gz"
expect_rc 2 "gitleaks: usage error" /bin/bash "$S/gitleaks.sh" scan

# ======================================================================= semgrep.sh (args only; no network)
section "semgrep.sh (arguments)"
expect_rc 2 "semgrep: needs --base" sh -c "cd '$d' && /bin/bash '$S/semgrep.sh'"
expect_rc 5 "semgrep: an unknown base commit is a missing prerequisite" sh -c "cd '$d' && /bin/bash '$S/semgrep.sh' --base 0000000000000000000000000000000000000000"

# ======================================================================= config
section "config/"
LAST_OUT=$(jq -r '.actions_app_id' "$ROOT/config/required-checks.json"); [ "$LAST_OUT" = 15368 ] && ok "required-checks: actions_app_id 15368" || bad "required-checks: app id ($LAST_OUT)"
for p in project standards template; do
  got=$(jq -r --arg p "$p" '.profiles[$p] | (.actions | join("|")) + "||" + (.statuses | join("|"))' "$ROOT/config/required-checks.json")
  case "$p" in
    project) want='ci / ci|gates / guarded-paths|gates / pr-title||ai-review|ai-security|ai-qa' ;;
    standards) want='self-test|ci / ci|gates / guarded-paths|gates / pr-title||ai-review|ai-security' ;;
    *) want='template-ci|gates / guarded-paths|gates / pr-title||ai-review|ai-security' ;;
  esac
  [ "$got" = "$want" ] && ok "required-checks: profile $p matches docs/rules.md §2" || bad "required-checks: profile $p ($got)"
done
got=$(jq -r '[.[].name] | join(" ")' "$ROOT/config/labels.json")
[ "$got" = "bug feature client-request high-risk guarded owner-approved tests-changed needs-info health incident main-red fixes-main" ] && ok "labels.json: the 12 labels of docs/rules.md §3" || bad "labels.json: names ($got)"
jq -e 'all(.[]; (.color | test("^[0-9a-f]{6}$")) and (.description | length > 0 and length <= 100))' "$ROOT/config/labels.json" >/dev/null && ok "labels.json: colours and descriptions valid" || bad "labels.json: colours/descriptions"
for f in test-markers.txt assertion-patterns.txt pii-patterns.txt destructive-migration-patterns.txt; do
  badp=$(grep -v '^#' "$ROOT/config/$f" | grep -v '^$' | while IFS= read -r p; do echo x | grep -E -- "$p" >/dev/null 2>&1; [ $? -le 1 ] || echo "$p"; done)
  [ -z "$badp" ] && ok "config/$f: every pattern compiles" || bad "config/$f: bad patterns: $badp"
done
grep -v '^#' "$ROOT/config/pr-title-types.txt" | grep -v '^$' | grep -qv '^[a-z][a-z]*$' && bad "pr-title-types: lower-case words only" || ok "pr-title-types: lower-case words only"
for k in GITLEAKS_SHA256 ACTIONLINT_SHA256 SHELLCHECK_SHA256; do
  v=$(/bin/bash "$S/conf.sh" get "$ROOT/config/tool-versions.env" "$k")
  printf '%s' "$v" | grep -Eq '^[0-9a-f]{64}$' && ok "tool-versions: $k is a SHA-256" || bad "tool-versions: $k ($v)"
done

# ======================================================================= workflows (static rules)
section "workflows"
WF="$ROOT/.github/workflows"
for f in ci pr-gates pipeline rollback uptime self-test gates release; do
  [ -f "$WF/$f.yml" ] && ok "workflow present: $f.yml" || bad "workflow missing: $f.yml"
done
grep -l 'pull_request_target' "$WF"/*.yml >/dev/null 2>&1 && bad "workflows: no pull_request_target" || ok "workflows: no pull_request_target"
grep -nE '^[[:space:]]+paths(-ignore)?:' "$WF"/*.yml >/dev/null 2>&1 && bad "workflows: no paths: filters" || ok "workflows: no paths: filters"
grep -h 'runs-on:' "$WF"/*.yml | grep -qv 'runs-on: ubuntu-24.04' && bad "workflows: runs-on ubuntu-24.04 only" || ok "workflows: runs-on ubuntu-24.04 only"
for f in "$WF"/*.yml; do grep -q '^permissions:' "$f" || bad "workflows: $(basename "$f") has top-level permissions"; done
ok "workflows: every file has top-level permissions (checked above)"
unpinned=$(grep -hE '^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]' "$WF"/*.yml | grep -v 'uses: \./' | grep -vE 'uses: [A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40} # v[0-9]+\.[0-9]+\.[0-9]+$' || true)
[ -z "$unpinned" ] && ok "workflows: every third-party action is pinned to a 40-char SHA with # vX.Y.Z" || bad "workflows: unpinned: $unpinned"
grep -n 'secrets\.' "$WF/self-test.yml" "$WF/gates.yml" "$WF/ci.yml" "$WF/pr-gates.yml" >/dev/null 2>&1 && bad "workflows: PR workflows use no secrets" || ok "workflows: PR workflows use no secrets"
grep -n 'PR_TITLE: \${{ github.event.pull_request.title }}' "$WF/pr-gates.yml" >/dev/null && ! grep -n 'run:.*github.event.pull_request.title' "$WF"/*.yml >/dev/null && ok "workflows: the PR title reaches scripts only through env" || bad "workflows: PR title handling"
for j in deploy-staging deploy-production; do
  awk -v j="  $j:" '$0 == j {f = 1; next} f && /^  [a-z]/ {f = 0} f' "$WF/pipeline.yml" | grep -q 'cancel-in-progress: false' && ok "pipeline: $j is never cancelled" || bad "pipeline: $j cancel-in-progress"
done
awk '$0 == "  rollback:" {f = 1; next} f' "$WF/rollback.yml" | grep -q 'cancel-in-progress: false' && ok "rollback: never cancelled" || bad "rollback: cancel-in-progress"
grep -q 'group: team-deploy-production-' "$WF/rollback.yml" && ok "rollback: shares the production deploy group" || bad "rollback: production group"
grep -q 'job.workflow_repository' "$WF/ci.yml" && grep -q "inputs.standards-ref || job.workflow_sha" "$WF/ci.yml" && ok "ci: standards checkout at the called commit" || bad "ci: standards checkout"
grep -q 'standards-ref: \${{ github.event.pull_request.base.sha }}' "$WF/gates.yml" && grep -q 'profile: standards' "$WF/gates.yml" && ok "gates: base-commit scripts, profile standards" || bad "gates: standards-ref/profile"
grep -q 'StrictHostKeyChecking=no' "$ROOT/scripts/ci/"*.sh "$WF"/*.yml && bad "never StrictHostKeyChecking=no" || ok "never StrictHostKeyChecking=no"

# ======================================================================= --help everywhere
section "--help"
for f in "$S"/*.sh; do
  [ "$(basename "$f")" = common.sh ] && continue
  expect_rc 0 "$(basename "$f") --help" /bin/bash "$f" --help
done
expect_rc 0 "sync-fixture.sh --help" /bin/bash "$ROOT/tests/ci/sync-fixture.sh" --help
expect_rc 0 "self-test.sh --help" /bin/bash "$ROOT/tests/ci/self-test.sh" --help

section "net-guard log"
unexpected=$(cut -f2- "$NET_GUARD_LOG" | grep -v 'net-guard-selftest' | grep -v 'app-staging@deploy.example.test' || true)
[ -z "$unexpected" ] && ok "net-guard: no ssh-family call except the guard self-test and the fake deploy host" || bad "net-guard: unexpected calls: $unexpected"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
