#!/usr/bin/env bash
# Tests for the local + VPS team-* commands (plugins/team/bin, docs/rules.md §10).
# Run: /bin/bash tests/commands/local/run.sh [group...]
# Groups: help lib hooks app worktrees identity dbpull remove mysql login flag vps provision
#         deploy fences shellcheck (default: all)
# Needs Docker (throwaway postgres:16-alpine and mysql:8.4 containers named team-cmdtest-*);
# without it the database groups are skipped. Never touches real servers, GitHub, the
# keychain, ~/.ssh, ~/.config/team or the Postgres on localhost:5432.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
# shellcheck source-path=SCRIPTDIR source=helpers.sh
. "$HERE/helpers.sh"

GROUPS_WANTED="${*:-help lib hooks app worktrees identity dbpull remove mysql login flag vps provision deploy fences shellcheck}"
want() { case " $GROUPS_WANTED " in *" $1 "*) return 0 ;; esac; return 1; }

setup_sandbox
trap cleanup EXIT
trap 'exit 130' INT TERM

# ------------------------------------------------------------------------------ help
t_help() {
  section "--help for every command"
  local c
  for c in $MY_CMDS; do
    run_cmd "$T/help" cmd "$c" --help
    if [ "$RC" = 0 ] && has "$T/help.out" "Usage: $c"; then pass "$c --help"; else fail "$c --help (exit $RC)"; fi
  done
  expect_rc 2 "team-new-worktree without an issue is a usage error" cmd team-new-worktree
  expect_rc 2 "team-app with a bad action is a usage error" cmd team-app restart
  expect_rc 2 "team-provision without an environment is a usage error" cmd team-provision
}

# ------------------------------------------------------------------------------ hooks
t_hooks() {
  section "team-hooks"
  local r="$T/hooks-fresh" r2="$T/hooks-husky" mark="$T/hooks-mark" common
  git init -q -b main "$r"
  mkdir -p "$r/.githooks"
  expect_rc 1 "--check fails before team-hooks ran" sh -c "cd '$r' && /bin/bash '$BIN/team-hooks' --check"
  expect_rc 0 "fresh repo: team-hooks" sh -c "cd '$r' && /bin/bash '$BIN/team-hooks'"
  ok "fresh repo: core.hooksPath=.githooks" [ "$(git -C "$r" config core.hooksPath)" = ".githooks" ]
  expect_rc 0 "fresh repo: second run is a no-op" sh -c "cd '$r' && /bin/bash '$BIN/team-hooks'"
  ok "fresh repo: still .githooks after the second run" [ "$(git -C "$r" config core.hooksPath)" = ".githooks" ]
  expect_rc 0 "fresh repo: --check passes" sh -c "cd '$r' && /bin/bash '$BIN/team-hooks' --check"

  git init -q -b main "$r2"
  mkdir -p "$r2/.githooks" "$r2/.husky/_"
  printf '#!/bin/sh\necho githooks >> "%s"\n' "$mark" > "$r2/.githooks/pre-commit"
  printf '#!/bin/sh\necho husky >> "%s"\n' "$mark" > "$r2/.husky/_/pre-commit"
  printf '#!/bin/sh\ncat > "%s.pp1"\n' "$mark" > "$r2/.githooks/pre-push"
  printf '#!/bin/sh\ncat > "%s.pp2"\n' "$mark" > "$r2/.husky/_/pre-push"
  chmod +x "$r2/.githooks/pre-commit" "$r2/.husky/_/pre-commit" "$r2/.githooks/pre-push" "$r2/.husky/_/pre-push"
  git -C "$r2" config core.hooksPath .husky/_
  common=$(cd "$r2/.git" && pwd -P)
  expect_rc 0 "existing .husky/_: team-hooks chains" sh -c "cd '$r2' && /bin/bash '$BIN/team-hooks'"
  ok "chained: core.hooksPath is the wrapper folder" [ "$(git -C "$r2" config core.hooksPath)" = "$common/team-hooks" ]
  ok "chained: team.previousHooksPath=.husky/_" [ "$(git -C "$r2" config team.previousHooksPath)" = ".husky/_" ]
  git -C "$r2" commit -q --allow-empty -m "chore: one" 2>/dev/null
  ok "chained: commit ran .githooks then .husky/_" [ "$(tr '\n' ' ' < "$mark")" = "githooks husky " ]
  expect_rc 0 "chained: second run is idempotent" sh -c "cd '$r2' && /bin/bash '$BIN/team-hooks'"
  ok "chained: previous path unchanged after re-run" [ "$(git -C "$r2" config team.previousHooksPath)" = ".husky/_" ]
  ok "chained: hooksPath unchanged after re-run" [ "$(git -C "$r2" config core.hooksPath)" = "$common/team-hooks" ]
  expect_rc 0 "chained: --check passes" sh -c "cd '$r2' && /bin/bash '$BIN/team-hooks' --check"
  git -C "$r2" add -A && git -C "$r2" commit -q -m "chore: hooks" 2>/dev/null
  : > "$mark"
  git -C "$r2" worktree add -q -b feat/1-x "$T/hooks-husky-wt" 2>/dev/null
  git -C "$T/hooks-husky-wt" commit -q --allow-empty -m "chore: in worktree" 2>/dev/null
  ok "chained: hooks also run in a worktree" [ "$(tr '\n' ' ' < "$mark")" = "githooks husky " ]
  git init -q --bare -b main "$T/hooks-remote.git"
  git -C "$r2" push -q "$T/hooks-remote.git" main 2>/dev/null
  ok "chained: pre-push stdin reaches both hooks" sh -c "grep -q 'refs/heads/main' '$mark.pp1' && cmp -s '$mark.pp1' '$mark.pp2'"
  printf '#!/bin/sh\necho githooks-fail >> "%s"\nexit 1\n' "$mark" > "$r2/.githooks/pre-commit"
  : > "$mark"
  if git -C "$r2" commit -q --allow-empty -m "chore: two" 2>/dev/null; then fail "chained: failing .githooks hook blocks the commit"; else pass "chained: failing .githooks hook blocks the commit"; fi
  ok "chained: the previous hook does not run after a failure" [ "$(tr '\n' ' ' < "$mark")" = "githooks-fail " ]
}

# ------------------------------------------------------------------------------ app
t_app() {
  section "team-app"
  local r="$T/app" port pid pgid
  make_project "$r" cmdtest-appsrv none Makefile.pg
  port=$(free_port $((PBASE + 25)) $((PBASE + 29)))
  printf 'PORT=%s\nAPP_URL=http://localhost:%s\n' "$port" "$port" > "$r/.env"
  expect_rc 0 "up starts make dev and waits for HEALTH_PATH" sh -c "cd '$r' && /bin/bash '$BIN/team-app' up --timeout 30"
  ok "up reports state=running health=ok" sh -c "grep -q '^state=running' '$T/last.out' && grep -q '^health=ok' '$T/last.out'"
  ok "health URL answers" curl -fsS -o /dev/null "http://localhost:$port/health"
  IFS='|' read -r pid pgid _ _ < "$r/.team/app.pid"
  ok "pidfile is pid|pgid|cwd|utc with this worktree" sh -c "awk -F'|' 'NF==4 && \$3==\"$r\"' '$r/.team/app.pid' | grep -q ."
  ok "app runs in its own process group" [ "$pid" = "$pgid" ]
  expect_rc 0 "up again is idempotent" sh -c "cd '$r' && /bin/bash '$BIN/team-app' up"
  ok "up again keeps the same pid" [ "$(kv "$T/last.out" pid)" = "$pid" ]
  expect_rc 0 "status" sh -c "cd '$r' && /bin/bash '$BIN/team-app' status"
  ok "status says running with the URL" sh -c "grep -q '^state=running' '$T/last.out' && grep -q '^url=http://localhost:$port' '$T/last.out'"
  expect_rc 0 "down stops it" sh -c "cd '$r' && /bin/bash '$BIN/team-app' down"
  ok "down removes the pidfile" [ ! -e "$r/.team/app.pid" ]
  ok "down leaves no process in the group" [ -z "$(ps -A -o pid=,pgid= | awk -v g="$pgid" '$2==g')" ]
  ok "down frees the port" sh -c "! lsof -nP -iTCP:$port -sTCP:LISTEN -t >/dev/null 2>&1"
  expect_rc 0 "down again is a no-op" sh -c "cd '$r' && /bin/bash '$BIN/team-app' down"
  expect_rc 0 "status when stopped" sh -c "cd '$r' && /bin/bash '$BIN/team-app' status"
  ok "status says stopped" grep -q '^state=stopped' "$T/last.out"

  start_listener "$port" "$T/foreign"
  expect_rc 4 "up refuses when another process holds PORT" sh -c "cd '$r' && /bin/bash '$BIN/team-app' up --timeout 5"
  stop_recorded

  local r3="$T/app-unconfigured" r4="$T/app-notarget"
  make_project "$r3" cmdtest-appnc none Makefile.unconfigured
  printf 'PORT=%s\n' "$port" > "$r3/.env"
  expect_rc 3 "up exits 3 when make dev is not configured" sh -c "cd '$r3' && /bin/bash '$BIN/team-app' up --timeout 10"
  ok "no pidfile left after exit 3" [ ! -e "$r3/.team/app.pid" ]
  make_project "$r4" cmdtest-appnt none Makefile.mysql
  printf 'PORT=%s\n' "$port" > "$r4/.env"
  expect_rc 3 "up exits 3 when there is no dev target" sh -c "cd '$r4' && /bin/bash '$BIN/team-app' up --timeout 10"
}

# ------------------------------------------------------------------------------ worktrees
PROJ="$T/proj"
t_worktrees() {
  section "team-new-worktree (3 in parallel, throwaway Postgres)"
  if [ "$PG_OK" != 1 ]; then skip "no Docker/psql: database worktree tests"; return; fi
  make_project "$PROJ" cmdtest-app postgres Makefile.pg
  printf 'PORT=%s\n' $((PBASE + 1)) > "$PROJ/.env"      # the main checkout's env file holds PBASE+1
  start_listener "$PBASE" "$T/decoy-listener"            # something already listens on PBASE
  issue_json 11 "Add CSV export!" feature
  issue_json 12 "Fix: crash on empty cart" bug
  issue_json 13 "Client wants dark mode" client-request
  local n pids="" rc
  for n in 11 12 13; do
    (cd "$PROJ" && /bin/bash "$BIN/team-new-worktree" "$n" > "$T/wt$n.out" 2> "$T/wt$n.err") &
    pids="$pids $!"
  done
  rc=0
  for n in $pids; do wait "$n" || rc=1; done
  if [ "$rc" = 0 ]; then pass "3 parallel runs exit 0"; else fail "3 parallel runs exit 0"; tail -n 5 "$T"/wt1?.err | sed 's/^/        | /'; fi

  local p11 p12 p13
  p11=$(kv "$T/wt11.out" port) p12=$(kv "$T/wt12.out" port) p13=$(kv "$T/wt13.out" port)
  ok "3 different ports ($p11 $p12 $p13)" sh -c "[ -n '$p11' ] && [ '$p11' != '$p12' ] && [ '$p11' != '$p13' ] && [ '$p12' != '$p13' ]"
  ok "ports skip the listening port and the main checkout's PORT" sh -c "for p in $p11 $p12 $p13; do [ \$p -gt $((PBASE + 1)) ] && [ \$p -le $((PBASE + 29)) ] || exit 1; done"
  ok "branches from labels and titles" sh -c "[ '$(kv "$T/wt11.out" branch)' = feat/11-add-csv-export ] && [ '$(kv "$T/wt12.out" branch)' = fix/12-fix-crash-on-empty-cart ] && [ '$(kv "$T/wt13.out" branch)' = feat/13-client-wants-dark-mode ]"
  WT11=$(kv "$T/wt11.out" path) WT12=$(kv "$T/wt12.out" path) WT13=$(kv "$T/wt13.out" path)
  ok "worktrees live in .claude/worktrees/<n>-<slug>" [ "$WT11" = "$PROJ/.claude/worktrees/11-add-csv-export" ]
  ok "branch has no upstream (--no-track)" sh -c "! git -C '$WT11' rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1"
  ok "databases created in the throwaway container" sh -c "[ \"\$(psql -X -h 127.0.0.1 -p $PG_PORT -U postgres -d postgres -Atc \"SELECT count(*) FROM pg_database WHERE datname IN ('cmdtest_app_11','cmdtest_app_12','cmdtest_app_13')\")\" = 3 ]"
  ok "database comment marks it as the pack's" [ "$(pgq "SELECT shobj_description(oid,'pg_database') FROM pg_database WHERE datname='cmdtest_app_11'")" = "team-pack:cmdtest-app:$WT11" ]
  ok "databases.registry records all three" [ "$(grep -c "^postgres|127.0.0.1|$PG_PORT|cmdtest_app_1[123]|cmdtest-app|$PROJ/.claude/worktrees/" "$TEAM_CONFIG_DIR/databases.registry")" = 3 ]
  ok "ports.registry records all three" [ "$(grep -c "|$PROJ/.claude/worktrees/" "$TEAM_CONFIG_DIR/ports.registry")" = 3 ]
  local e="$WT11/.env"
  ok "env file: PORT and APP_URL" sh -c "grep -qx 'PORT=$p11' '$e' && grep -qx 'APP_URL=http://localhost:$p11' '$e'"
  ok "env file: explicit DB host/port/name" sh -c "grep -qx 'DB_HOST=127.0.0.1' '$e' && grep -qx 'DB_PORT=$PG_PORT' '$e' && grep -qx 'DB_NAME=cmdtest_app_11' '$e'"
  ok "env file: DATABASE_URL replaced (key existed)" grep -q "^DATABASE_URL=postgresql://postgres:.*@127.0.0.1:$PG_PORT/cmdtest_app_11$" "$e"
  ok "env file: outside services in log/sandbox mode" sh -c "grep -qx 'MAIL_MODE=log' '$e' && grep -qx 'SMS_MODE=log' '$e' && grep -qx 'PAYMENTS_MODE=sandbox' '$e' && grep -qx 'WEBHOOKS_MODE=log' '$e'"
  ok "env file: replaced not duplicated, other keys kept" sh -c "[ \$(grep -c '^MAIL_MODE=' '$e') = 1 ] && grep -qx 'FOO=bar' '$e' && [ \$(grep -c '^PORT=' '$e') = 1 ]"
  ok "env file: timezone, Playwright profile, TEAM_WORKTREE" sh -c "grep -qx 'APP_TIMEZONE=Asia/Manila' '$e' && grep -qx 'PLAYWRIGHT_PROFILE_DIR=.team/playwright-profile' '$e' && grep -qx 'TEAM_WORKTREE=1' '$e'"
  ok "env file is mode 600" [ "$(stat -f %Lp "$e")" = 600 ]
  ok "make setup ran" [ -e "$WT11/.team/setup-ran" ]
  ok "no snapshot: MIGRATE_CMD then SEED_CMD ran" sh -c "[ -e '$WT11/.team/migrated' ] && [ \"\$(psql -X -h 127.0.0.1 -p $PG_PORT -U postgres -d cmdtest_app_11 -Atc 'SELECT count(*) FROM seeded')\" = 1 ]"
  ok "no snapshot: says the seed data was loaded" has "$T/wt11.err" "no sanitized snapshot yet"
  ok "evidence link points at the main checkout" [ "$(readlink "$WT11/.team/evidence")" = "$PROJ/.team/evidence" ]
  ok "main checkout's evidence folder exists" [ -d "$PROJ/.team/evidence" ]
  ok "summary has env_file and identity (owner account)" sh -c "[ '$(kv "$T/wt11.out" env_file)' = '$e' ] && [ '$(kv "$T/wt11.out" identity)' = test-owner ]"
  ok "no agent line: no per-worktree identity set" sh -c "! git -C '$WT11' config --get remote.origin.pushurl >/dev/null && ! git -C '$PROJ' config --get extensions.worktreeConfig >/dev/null"

  local before
  before=$(cat "$WT11/.team/setup-ran")
  sleep 1
  expect_rc 0 "re-run for issue 11 is idempotent" sh -c "cd '$WT12' && /bin/bash '$BIN/team-new-worktree' 11"
  ok "re-run: same path and port" sh -c "[ '$(kv "$T/last.out" path)' = '$WT11' ] && [ '$(kv "$T/last.out" port)' = '$p11' ]"
  ok "re-run: no duplicate registry lines" sh -c "[ \$(grep -c 'cmdtest_app_11|' '$TEAM_CONFIG_DIR/databases.registry') = 1 ] && [ \$(grep -c '|$WT11|' '$TEAM_CONFIG_DIR/ports.registry') = 1 ]"
  ok "re-run: setup not repeated" [ "$(cat "$WT11/.team/setup-ran")" = "$before" ]
  expect_rc 0 "re-run with another --slug reuses the issue's worktree" sh -c "cd '$PROJ' && /bin/bash '$BIN/team-new-worktree' 11 --slug something-else"
  ok "re-run with another --slug: same path" [ "$(kv "$T/last.out" path)" = "$WT11" ]
  expect_rc 2 "bad --type is a usage error" sh -c "cd '$PROJ' && /bin/bash '$BIN/team-new-worktree' 15 --type feature"

  pgq "CREATE DATABASE cmdtest_app_16" >/dev/null
  expect_rc 4 "refuses to adopt an existing, unrecorded database" sh -c "cd '$PROJ' && /bin/bash '$BIN/team-new-worktree' 16 --type feat --slug adopt --no-setup"
  ok "the unrecorded database is untouched" [ "$(pgq "SELECT count(*) FROM pg_database WHERE datname='cmdtest_app_16'")" = 1 ]
  ok "it is not recorded" hasnt "$TEAM_CONFIG_DIR/databases.registry" "cmdtest_app_16|"
  git -C "$PROJ" worktree remove --force "$PROJ/.claude/worktrees/16-adopt" 2>/dev/null
  git -C "$PROJ" branch -D feat/16-adopt >/dev/null 2>&1

  local down="$T/config-pgdown"
  write_config "$down"
  sed -i '' "s/^LOCAL_PG_PORT=.*/LOCAL_PG_PORT=$(free_port 56600 56699)/" "$down/defaults.conf"
  expect_rc 1 "Postgres unreachable → exit 1 with a clear message" sh -c "cd '$PROJ' && TEAM_CONFIG_DIR='$down' /bin/bash '$BIN/team-new-worktree' 17 --type fix --slug converge --no-setup"
  ok "the message names the server" has "$T/last.err" "cannot connect to Postgres on 127.0.0.1:"
  expect_rc 0 "re-run once Postgres is reachable finishes the same worktree" sh -c "cd '$PROJ' && /bin/bash '$BIN/team-new-worktree' 17 --no-setup"
  ok "converged: database and path" sh -c "[ '$(kv "$T/last.out" db)' = cmdtest_app_17 ] && [ '$(kv "$T/last.out" path)' = '$PROJ/.claude/worktrees/17-converge' ]"
  expect_rc 0 "clean up worktree 17" sh -c "cd '$PROJ' && /bin/bash '$BIN/team-remove-worktree' 17"

  # review-pr passes a PR number: with --type and --slug there is no issue lookup at all
  rm -f "$STUB_DIR/issue-30.json" "$STUB_DIR/issue-31.json"
  : > "$STUB_DIR/gh.log"
  expect_rc 0 "--type + --slug: a PR number works without an issue" sh -c "cd '$PROJ' && /bin/bash '$BIN/team-new-worktree' 30 --type chore --slug review --no-setup"
  ok "--type + --slug: branch chore/30-review" [ "$(kv "$T/last.out" branch)" = chore/30-review ]
  ok "--type + --slug: no gh call was made" sh -c "! grep -q 'issue view' '$STUB_DIR/gh.log'"
  expect_rc 1 "--type without --slug still reads the issue (none here → exit 1)" sh -c "cd '$PROJ' && /bin/bash '$BIN/team-new-worktree' 31 --type chore --no-setup"
  ok "--type without --slug: the issue was looked up" grep -q 'issue view 31 --json title,labels' "$STUB_DIR/gh.log"
  ok "--type without --slug: nothing created after the failed lookup" sh -c "! ls -d '$PROJ'/.claude/worktrees/31-* >/dev/null 2>&1 && ! grep -q 'cmdtest_app_31|' '$TEAM_CONFIG_DIR/databases.registry'"
  expect_rc 0 "clean up worktree 30" sh -c "cd '$PROJ' && /bin/bash '$BIN/team-remove-worktree' 30"
  stop_recorded
}

# ------------------------------------------------------------------------------ lib
t_lib() {
  section "team-local.sh helpers"
  local lib="$PLUGIN/lib" p
  run_lib() { /bin/bash -c ". '$lib/team-common.sh'; . '$lib/team-local.sh'; $1"; }
  ok "slugify: lowercase, non-alnum to -, trimmed" [ "$(run_lib "team_slugify '  Fix: Crash on *empty* cart!! '")" = "fix-crash-on-empty-cart" ]
  ok "slugify: at most 40 chars, no trailing -" [ "$(run_lib "team_slugify 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa b c'")" = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ]
  ok "slugify: non-ASCII becomes -" [ "$(run_lib "team_slugify 'Café menü'")" = "caf-men" ]
  printf 'A=1\nexport PORT=3000\nPORT=3001\nB=two words\n' > "$T/envtest"
  # shellcheck disable=SC2016  # $TV is expanded by the inner bash
  TV='x y&\z $HOME' run_lib "team_env_set '$T/envtest' PORT 8005; team_env_set '$T/envtest' NEW \"\$TV\"; team_env_set '$T/envtest' A 2"
  ok "env_set: replaces the first PORT, drops duplicates, keeps others" [ "$(tr '\n' '|' < "$T/envtest")" = "A=2|PORT=8005|B=two words|NEW='x y&\\z \$HOME'|" ]
  # shellcheck disable=SC2016  # a literal $HOME is the point of this check
  ok "env_get reads a quoted value back unchanged" [ "$(run_lib "team_env_get '$T/envtest' NEW")" = 'x y&\z $HOME' ]
  printf 'make: *** [setup] Error 3\n' > "$T/mk1"
  printf 'make[1]: *** [x] Error 3\nmake: *** [setup] Error 2\n' > "$T/mk2"
  printf "make: *** No rule to make target \`dev'.  Stop.\n" > "$T/mk3"
  ok "make status: Error 3 → not configured" sh -c "/bin/bash -c \". '$lib/team-common.sh'; . '$lib/team-local.sh'; team_make_status '$T/mk1' setup 2\"; [ \$? = 3 ]"
  ok "make status: nested failure → 1" sh -c "/bin/bash -c \". '$lib/team-common.sh'; . '$lib/team-local.sh'; team_make_status '$T/mk2' setup 2\"; [ \$? = 1 ]"
  ok "make status: no such target → not configured" sh -c "/bin/bash -c \". '$lib/team-common.sh'; . '$lib/team-local.sh'; team_make_status '$T/mk3' dev 2\"; [ \$? = 3 ]"
  ok "urlencode" [ "$(run_lib "team_urlencode 'a b/c@d:e'")" = "a%20b%2Fc%40d%3Ae" ]
  p=$(free_port $((PBASE + 20)) $((PBASE + 24)))
  start_listener "$p" "$T/listener-v4"
  mkdir -p "$T/listener-v6"
  (cd "$T/listener-v6" && exec python3 -m http.server "$p" --bind ::1 >/dev/null 2>&1) &
  RECORDED_PIDS="$RECORDED_PIDS $!:$T/listener-v6"
  sleep 1
  run_cmd "$T/shared" run_lib "team_warn_shared_port $p 'local Postgres'"
  ok "two different processes on one port → warning" has "$T/shared.err" "2 different processes listen on port $p"
  stop_recorded
  run_cmd "$T/shared" run_lib "team_warn_shared_port $p 'local Postgres'"
  ok "no warning once only one or none listens" [ ! -s "$T/shared.err" ]
}

# ------------------------------------------------------------------------------ identity
t_identity() {
  section "team-new-worktree: optional agent identity"
  if [ ! -d "$PROJ" ] || [ "$PG_OK" != 1 ]; then skip "needs the worktrees group"; return; fi
  cp "$TEAM_CONFIG_DIR/accounts.conf" "$T/accounts.bak"
  echo "agent|test-agent|github-agent|Test Agent|agent@example.test" >> "$TEAM_CONFIG_DIR/accounts.conf"
  expect_rc 0 "worktree with an agent line" sh -c "cd '$PROJ' && /bin/bash '$BIN/team-new-worktree' 14 --type chore --slug agent-id --no-setup"
  local w
  w=$(kv "$T/last.out" path)
  ok "summary prints identity=test-agent" [ "$(kv "$T/last.out" identity)" = test-agent ]
  ok "extensions.worktreeConfig enabled" [ "$(git -C "$PROJ" config --bool extensions.worktreeConfig)" = true ]
  ok "per-worktree user.name and user.email" sh -c "[ \"\$(git -C '$w' config user.name)\" = 'Test Agent' ] && [ \"\$(git -C '$w' config user.email)\" = agent@example.test ]"
  ok "per-worktree pushurl over the agent's SSH alias" [ "$(git -C "$w" config remote.origin.pushurl)" = "git@github-agent:test-owner/cmdtest-app.git" ]
  ok "main checkout keeps its own identity and push URL" sh -c "! git -C '$PROJ' config --get remote.origin.pushurl >/dev/null && ! git -C '$PROJ' config --get user.name >/dev/null"
  ok "other worktrees are not affected" sh -c "! git -C '$WT11' config --get remote.origin.pushurl >/dev/null"
  cp "$T/accounts.bak" "$TEAM_CONFIG_DIR/accounts.conf"
  expect_rc 0 "remove the agent worktree" sh -c "cd '$PROJ' && /bin/bash '$BIN/team-remove-worktree' 14"
}

# ------------------------------------------------------------------------------ db-pull
t_dbpull() {
  section "team-db-pull"
  if [ -z "${WT11:-}" ] || [ "$PG_OK" != 1 ]; then skip "needs the worktrees group"; return; fi
  mkdir -p "$TEAM_SNAPSHOT_CACHE/cmdtest-app"
  gzip -c "$HERE/fixtures/dump.sql" > "$TEAM_SNAPSHOT_CACHE/cmdtest-app/sanitized-20261001T030000Z.sql.gz"
  local m0
  m0=$(wc -l < "$WT11/.team/migrated")
  expect_rc 0 "restores the cached dump" sh -c "cd '$WT11' && /bin/bash '$BIN/team-db-pull'"
  ok "dump rows are in the worktree database" [ "$(pgq 'SELECT count(*) FROM customers' cmdtest_app_11)" = 2 ]
  ok "registry database was re-created (seed table gone)" [ -z "$(pgq "SELECT 1 FROM pg_tables WHERE tablename='seeded'" cmdtest_app_11)" ]
  ok "comment kept after re-creation" sh -c "psql -X -h 127.0.0.1 -p $PG_PORT -U postgres -d postgres -Atc \"SELECT shobj_description(oid,'pg_database') FROM pg_database WHERE datname='cmdtest_app_11'\" | grep -q '^team-pack:cmdtest-app:'"
  ok "MIGRATE_CMD ran after the restore" [ "$(wc -l < "$WT11/.team/migrated")" -gt "$m0" ]
  ok "other worktree databases untouched" [ "$(pgq 'SELECT count(*) FROM seeded' cmdtest_app_12)" = 1 ]

  expect_rc 6 "--fresh without the db-pull key: production not provisioned (exit 6)" sh -c "cd '$WT11' && /bin/bash '$BIN/team-db-pull' --fresh"
  ok "exit 6 explains it" has "$T/last.err" "production is not provisioned yet"
  printf 'stub key\n' > "$HOME/.ssh/team-dbpull-cmdtest-app"
  chmod 600 "$HOME/.ssh/team-dbpull-cmdtest-app"
  gzip -c "$HERE/fixtures/fresh-dump.sql" > "$STUB_DIR/fresh-dump.sql.gz"
  : > "$STUB_DIR/ssh.log"
  expect_rc 0 "--fresh downloads the newest dump and restores it" sh -c "cd '$WT11' && /bin/bash '$BIN/team-db-pull' --fresh"
  ok "downloaded into the cache (no .part left)" sh -c "[ -s '$TEAM_SNAPSHOT_CACHE/cmdtest-app/sanitized-20261005T030000Z.sql.gz' ] && ! ls '$TEAM_SNAPSHOT_CACHE/cmdtest-app/'*.part >/dev/null 2>&1"
  ok "the fresh dump is what got restored" [ "$(pgq 'SELECT id FROM fresh_marker' cmdtest_app_11)" = 42 ]
  ok "ssh used the restricted key as the production user via the alias" grep -q -- "-i $HOME/.ssh/team-dbpull-cmdtest-app -o IdentitiesOnly=yes -o BatchMode=yes -l cmdtest-app-production vps-test latest-name" "$STUB_DIR/ssh.log"
  ok "exactly two ssh calls (name, download), no retries" [ "$(grep -c . "$STUB_DIR/ssh.log")" = 2 ]
  : > "$STUB_DIR/ssh.log"
  expect_rc 0 "--fresh again skips the download when cached" sh -c "cd '$WT11' && /bin/bash '$BIN/team-db-pull' --fresh"
  ok "only latest-name was asked" sh -c "[ \$(grep -c . '$STUB_DIR/ssh.log') = 1 ] && grep -q 'latest-name' '$STUB_DIR/ssh.log'"
  rm -f "$TEAM_SNAPSHOT_CACHE/cmdtest-app/sanitized-20261005T030000Z.sql.gz"
  : > "$STUB_DIR/ssh.log"
  expect_rc 1 "an unexpected snapshot name from the server is rejected" sh -c "cd '$WT11' && STUB_SNAPSHOT_NAME='../../evil.sql.gz' /bin/bash '$BIN/team-db-pull' --fresh"
  ok "nothing was downloaded after the bad name" sh -c "[ \$(grep -c . '$STUB_DIR/ssh.log') = 1 ] && ! ls '$TEAM_SNAPSHOT_CACHE/' | grep -q evil"

  pgq "CREATE DATABASE cmdtest_app_12_decoy" >/dev/null
  psql -X -q -h 127.0.0.1 -p "$PG_PORT" -U postgres -d cmdtest_app_12_decoy -c "CREATE TABLE keep (id int); INSERT INTO keep VALUES (7);" >/dev/null 2>&1
  cp "$WT12/.env" "$T/env12.bak"
  sed -i '' 's/^DB_NAME=.*/DB_NAME=cmdtest_app_12_decoy/' "$WT12/.env"
  expect_rc 4 "refuses to overwrite an unrecorded, non-empty database" sh -c "cd '$WT12' && /bin/bash '$BIN/team-db-pull'"
  ok "the unrecorded database still has its data" [ "$(pgq 'SELECT id FROM keep' cmdtest_app_12_decoy)" = 7 ]
  cp "$T/env12.bak" "$WT12/.env"
}

# ------------------------------------------------------------------------------ remove
t_remove() {
  section "team-remove-worktree"
  if [ -z "${WT11:-}" ] || [ "$PG_OK" != 1 ]; then skip "needs the worktrees group"; return; fi
  local p11
  p11=$(grep "|$WT11|" "$TEAM_CONFIG_DIR/ports.registry" | cut -d'|' -f1)
  pgq "CREATE DATABASE cmdtest_app_11_decoy" >/dev/null
  pgq "CREATE DATABASE cmdtest_app_1" >/dev/null
  mkdir -p "$PROJ/.team/evidence/5"
  printf 'png' > "$PROJ/.team/evidence/5/after.png"
  (cd "$WT11" && /bin/bash "$BIN/team-app" up --timeout 30 >/dev/null 2>&1)

  touch "$WT13/untracked.txt"
  expect_rc 4 "refuses a dirty worktree without --force" sh -c "cd '$PROJ' && /bin/bash '$BIN/team-remove-worktree' 13"
  ok "dirty worktree and its database kept" sh -c "[ -d '$WT13' ] && [ \"\$(psql -X -h 127.0.0.1 -p $PG_PORT -U postgres -d postgres -Atc \"SELECT count(*) FROM pg_database WHERE datname='cmdtest_app_13'\")\" = 1 ]"
  expect_rc 4 "refuses the main checkout" sh -c "cd '$PROJ' && /bin/bash '$BIN/team-remove-worktree' '$PROJ'"
  git -C "$PROJ" worktree add -q -b feat/99-own "$T/own-worktree" 2>/dev/null
  expect_rc 4 "refuses a worktree outside .claude/worktrees" sh -c "cd '$PROJ' && /bin/bash '$BIN/team-remove-worktree' '$T/own-worktree'"
  ok "the foreign worktree is untouched" [ -d "$T/own-worktree" ]
  git -C "$PROJ" worktree remove "$T/own-worktree" 2>/dev/null

  expect_rc 0 "removes worktree 11 by issue number" sh -c "cd '$PROJ' && /bin/bash '$BIN/team-remove-worktree' 11"
  ok "its recorded database was dropped" [ "$(pgq "SELECT count(*) FROM pg_database WHERE datname='cmdtest_app_11'")" = 0 ]
  ok "decoys with similar names survive" [ "$(pgq "SELECT count(*) FROM pg_database WHERE datname IN ('cmdtest_app_11_decoy','cmdtest_app_1','cmdtest_app_12_decoy')")" = 3 ]
  ok "the app was stopped first" sh -c "! lsof -nP -iTCP:$p11 -sTCP:LISTEN -t >/dev/null 2>&1"
  ok "the port is freed" hasnt "$TEAM_CONFIG_DIR/ports.registry" "|$WT11|"
  ok "the registry line is gone" hasnt "$TEAM_CONFIG_DIR/databases.registry" "|$WT11|"
  ok "the worktree folder is gone" [ ! -e "$WT11" ]
  ok "evidence in the main checkout survives" [ -f "$PROJ/.team/evidence/5/after.png" ]
  ok "branch kept while its PR is not merged" git -C "$PROJ" show-ref --verify --quiet refs/heads/feat/11-add-csv-export
  ok "prints what it did" sh -c "grep -qx 'dropped=cmdtest_app_11' '$T/last.out' && grep -qx 'port_freed=$p11' '$T/last.out' && grep -qx 'branch_deleted=no' '$T/last.out'"

  touch "$STUB_DIR/merged-fix_12-fix-crash-on-empty-cart"
  expect_rc 0 "removes worktree 12 by path" sh -c "cd '$PROJ' && /bin/bash '$BIN/team-remove-worktree' '$WT12'"
  ok "branch deleted once its PR is merged" sh -c "! git -C '$PROJ' show-ref --verify --quiet refs/heads/fix/12-fix-crash-on-empty-cart"

  pgq "COMMENT ON DATABASE cmdtest_app_13 IS 'not-the-pack'" >/dev/null
  expect_rc 0 "--force removes a dirty worktree" sh -c "cd '$PROJ' && /bin/bash '$BIN/team-remove-worktree' 13 --force"
  ok "a recorded database without the pack comment survives" [ "$(pgq "SELECT count(*) FROM pg_database WHERE datname='cmdtest_app_13'")" = 1 ]
  ok "and it is no longer claimed in the registry" hasnt "$TEAM_CONFIG_DIR/databases.registry" "cmdtest_app_13|"
  ok "worktree 13 is gone" [ ! -e "$WT13" ]
  expect_rc 2 "unknown issue is a usage error" sh -c "cd '$PROJ' && /bin/bash '$BIN/team-remove-worktree' 77"
}

# ------------------------------------------------------------------------------ mysql
t_mysql() {
  section "team-new-worktree / db-pull / remove with MySQL (project container)"
  if [ "$PG_OK" != 1 ]; then skip "no Docker: MySQL tests"; return; fi
  if docker inspect "$MY_CONTAINER" >/dev/null 2>&1; then skip "$MY_CONTAINER already exists (left by an earlier run?)"; return; fi
  if ! docker image inspect mysql:8.4 >/dev/null 2>&1 && ! docker pull -q mysql:8.4 >/dev/null 2>&1; then skip "mysql:8.4 image unavailable"; return; fi
  local r="$T/myproj" myport w pw
  myport=$(free_port 56500 56599)
  make_project "$r" cmdtest-my mysql Makefile.mysql "LOCAL_DB_IMAGE=mysql:8.4" "LOCAL_DB_PORT=$myport"
  MY_USED=1
  expect_rc 0 "worktree for a MySQL project (starts the project container)" sh -c "cd '$r' && /bin/bash '$BIN/team-new-worktree' 21 --type feat --slug my-db"
  w=$(kv "$T/last.out" path)
  pw=$(sed -n 's/^LOCAL_DB_PASSWORD=//p' "$TEAM_CONFIG_DIR/projects/cmdtest-my.conf")
  ok "container team-cmdtest-my-db runs with the pack label" [ "$(docker inspect -f '{{index .Config.Labels "team-pack"}}' "$MY_CONTAINER" 2>/dev/null)" = cmdtest-my ]
  ok "database created inside the container" sh -c "MYSQL_PWD='$pw' docker exec -e MYSQL_PWD '$MY_CONTAINER' mysql -uroot -N -B -e \"SHOW DATABASES LIKE 'cmdtest_my_21'\" 2>/dev/null | grep -qx cmdtest_my_21"
  ok "recorded in databases.registry" grep -q "^mysql|127.0.0.1|$myport|cmdtest_my_21|cmdtest-my|$w|" "$TEAM_CONFIG_DIR/databases.registry"
  ok "env file points at the container port" sh -c "grep -qx 'DB_PORT=$myport' '$w/.env' && grep -qx 'DB_USER=root' '$w/.env' && grep -qx 'DB_PASSWORD=$pw' '$w/.env'"
  ok "projects/<project>.conf holding the password is mode 600" [ "$(stat -f %Lp "$TEAM_CONFIG_DIR/projects/cmdtest-my.conf")" = 600 ]
  expect_rc 0 "re-run is idempotent" sh -c "cd '$r' && /bin/bash '$BIN/team-new-worktree' 21"
  mkdir -p "$TEAM_SNAPSHOT_CACHE/cmdtest-my"
  gzip -c "$HERE/fixtures/dump-mysql.sql" > "$TEAM_SNAPSHOT_CACHE/cmdtest-my/sanitized-20261001T030000Z.sql.gz"
  expect_rc 0 "db-pull restores a MySQL dump" sh -c "cd '$w' && /bin/bash '$BIN/team-db-pull'"
  ok "dump rows are in the container database" sh -c "[ \"\$(MYSQL_PWD='$pw' docker exec -e MYSQL_PWD '$MY_CONTAINER' mysql -uroot -N -B -e 'SELECT count(*) FROM cmdtest_my_21.customers' 2>/dev/null)\" = 3 ]"
  expect_rc 0 "remove drops the recorded MySQL database" sh -c "cd '$r' && /bin/bash '$BIN/team-remove-worktree' 21"
  ok "database gone, container still running" sh -c "! MYSQL_PWD='$pw' docker exec -e MYSQL_PWD '$MY_CONTAINER' mysql -uroot -N -B -e \"SHOW DATABASES LIKE 'cmdtest_my_21'\" 2>/dev/null | grep -q . && [ \"\$(docker inspect -f '{{.State.Running}}' '$MY_CONTAINER')\" = true ]"
}

# ------------------------------------------------------------------------------ staging login
t_login() {
  section "team-staging-login"
  : > "$STUB_DIR/security.log"
  expect_rc 4 "refuses inside Claude Code (CLAUDECODE=1)" env CLAUDECODE=1 /bin/bash "$BIN/team-staging-login" cmdtest-app
  ok "no keychain access when refused" [ ! -s "$STUB_DIR/security.log" ]
  printf 'cmdtest-app\nS3cretStubPass42\n' > "$STUB_DIR/keychain-team-staging-cmdtest-app"
  expect_rc 0 "copies the login to the clipboard" cmd team-staging-login cmdtest-app
  ok "clipboard holds Username/Password" [ "$(cat "$STUB_DIR/clipboard")" = "Username: cmdtest-app
Password: S3cretStubPass42" ]
  ok "the password is never printed" sh -c "! grep -q S3cretStubPass42 '$T/last.out' '$T/last.err'"
  expect_rc 1 "missing keychain item" cmd team-staging-login nothere
  expect_rc 2 "bad project name" cmd team-staging-login 'Bad;Name'
  rm -f "$STUB_DIR/keychain-team-staging-cmdtest-app"
}

# ------------------------------------------------------------------------------ flag
t_flag() {
  section "team-flag"
  local r="$T/flagproj"
  [ -d "$r" ] || make_project "$r" cmdtest-flag none Makefile.pg
  : > "$STUB_DIR/ssh.log"
  expect_rc 4 "production refused inside Claude Code" sh -c "cd '$r' && CLAUDECODE=1 /bin/bash '$BIN/team-flag' production new-ui on"
  ok "no ssh when refused" [ ! -s "$STUB_DIR/ssh.log" ]
  expect_rc 0 "staging flag inside Claude Code" sh -c "cd '$r' && CLAUDECODE=1 /bin/bash '$BIN/team-flag' staging new-ui on"
  ok "runs the server flag command over the alias" grep -qx "vps-test sudo /usr/local/lib/team/flag cmdtest-flag staging new-ui on --by test-owner" "$STUB_DIR/ssh.log"
  expect_rc 0 "production flag from a normal terminal" sh -c "cd '$r' && /bin/bash '$BIN/team-flag' production new-ui off"
  ok "production command sent" grep -qx "vps-test sudo /usr/local/lib/team/flag cmdtest-flag production new-ui off --by test-owner" "$STUB_DIR/ssh.log"
  expect_rc 2 "unsafe flag name refused" sh -c "cd '$r' && /bin/bash '$BIN/team-flag' staging 'x;reboot' on"
  expect_rc 2 "bad state refused" sh -c "cd '$r' && /bin/bash '$BIN/team-flag' staging new-ui maybe"
}

# ------------------------------------------------------------------------------ discover / refresh / alias safety
t_vps() {
  section "team-discover, team-refresh-staging, VPS alias safety"
  local r="$T/flagproj" bad="$T/config-bad"
  [ -d "$r" ] || make_project "$r" cmdtest-flag none Makefile.pg
  : > "$STUB_DIR/ssh.log"; : > "$STUB_DIR/ssh-dest.log"
  expect_rc 0 "team-discover sends server/discover and runs it" cmd team-discover
  ok "discover: the report is printed" has "$T/last.out" "STUB DISCOVER REPORT"
  ok "discover: discover and lib.sh arrived unchanged" sh -c "cmp -s '$STUB_DIR/discover-bundle/discover' '$PLUGIN/server/discover' && cmp -s '$STUB_DIR/discover-bundle/lib.sh' '$PLUGIN/server/lib.sh' && [ \$(ls '$STUB_DIR/discover-bundle' | wc -l) -eq 2 ]"
  # shellcheck disable=SC2016  # literal remote command text
  ok "discover: one plain ssh to the alias, run without sudo, temp folder removed" sh -c "[ \$(grep -c . '$STUB_DIR/ssh.log') = 1 ] && grep -qxF 'd=\$(mktemp -d) && tar -xz -C \"\$d\" && bash \"\$d/discover\"; rc=\$?; rm -rf \"\${d:?}\"; exit \$rc' '$STUB_DIR/discover-cmd' && grep -q '^vps-test d=' '$STUB_DIR/ssh.log'"
  expect_rc 0 "team-refresh-staging shows the server's plan" sh -c "cd '$r' && /bin/bash '$BIN/team-refresh-staging'"
  ok "refresh plan: no --apply sent" grep -qx "vps-test sudo /usr/local/lib/team/refresh-staging cmdtest-flag" "$STUB_DIR/ssh.log"
  ok "refresh plan: says nothing changed" has "$T/last.out" "Nothing changed"
  expect_rc 0 "team-refresh-staging --apply" sh -c "cd '$r' && /bin/bash '$BIN/team-refresh-staging' --apply"
  ok "refresh apply: --apply sent" grep -qx "vps-test sudo /usr/local/lib/team/refresh-staging cmdtest-flag --apply" "$STUB_DIR/ssh.log"
  write_config "$bad"
  sed -i '' 's/^VPS_ALIAS=.*/VPS_ALIAS=vps-test-root/' "$bad/defaults.conf"
  expect_rc 4 "a forbidden alias is refused" env TEAM_CONFIG_DIR="$bad" /bin/bash "$BIN/team-discover"
  sed -i '' 's/^VPS_ALIAS=.*/VPS_ALIAS=192.0.2.10/' "$bad/defaults.conf"
  expect_rc 4 "the VPS IP as alias is refused" env TEAM_CONFIG_DIR="$bad" /bin/bash "$BIN/team-discover"
  expect_rc 5 "missing defaults.conf" env TEAM_CONFIG_DIR="$T/nowhere" /bin/bash "$BIN/team-discover"
  ok "ssh only ever went to the alias" sh -c "! grep -v -x 'vps-test' '$STUB_DIR/ssh-dest.log' | grep -q ."
}

# ------------------------------------------------------------------------------ provision
secret_files() { find "$STUB_DIR/secrets" -type f 2>/dev/null | sed 's|.*/||' | LC_ALL=C sort | tr '\n' ' '; }
t_provision() {
  section "team-provision (stub ssh and gh)"
  local r="$T/provproj" pw pub
  make_project "$r" cmdtest-prov postgres Makefile.pg
  rm -rf "${STUB_DIR:?}/secrets" "${STUB_DIR:?}/variables"
  : > "$STUB_DIR/ssh.log"; : > "$STUB_DIR/ssh-dest.log"; : > "$STUB_DIR/gh.log"; rm -f "$STUB_DIR/security-i.log"

  expect_rc 0 "staging plan" sh -c "cd '$r' && /bin/bash '$BIN/team-provision' staging"
  cp "$T/last.out" "$T/prov-plan.out"
  ok "plan: bundle has server scripts, ops/ and inputs.conf" sh -c "[ -f '$STUB_DIR/bundle/provision' ] && [ -f '$STUB_DIR/bundle/ops/project.conf' ] && [ -f '$STUB_DIR/bundle/inputs.conf' ]"
  ok "plan: no macOS metadata files in the bundle" sh -c "! find '$STUB_DIR/bundle' -name '._*' | grep -q ."
  ok "plan: remote command matches §12 without --apply" sh -c "grep -q 'sudo bash \"\$d/provision\" --bundle \"\$d\"; rc=\$?; rm -rf \"\${d:?}\"; exit \$rc' '$STUB_DIR/provision-cmd'"
  ok "plan: inputs.conf values" sh -c "grep -qx 'PROJECT=\"cmdtest-prov\"' '$STUB_DIR/bundle/inputs.conf' && grep -qx 'ENV=\"staging\"' '$STUB_DIR/bundle/inputs.conf' && grep -qx 'HOST=\"cmdtest-prov-staging.example.test\"' '$STUB_DIR/bundle/inputs.conf' && grep -q '^DEPLOY_PUBKEY=\"ssh-ed25519 AAAA' '$STUB_DIR/bundle/inputs.conf' && grep -qx 'DBPULL_PUBKEY=\"\"' '$STUB_DIR/bundle/inputs.conf' && grep -qx 'TIMEZONE=\"Asia/Manila\"' '$STUB_DIR/bundle/inputs.conf'"
  ok "plan: inputs.conf is mode 600" [ "$(stat -f %Lp "$STUB_DIR/bundle/inputs.conf")" = 600 ]
  ok "plan: lists the §12 secret names" has "$T/prov-plan.out" "environment secrets (staging) in test-owner/cmdtest-prov: DEPLOY_HOST DEPLOY_USER DEPLOY_PORT DEPLOY_SSH_KEY DEPLOY_KNOWN_HOSTS APP_URL HEALTH_URL BASIC_AUTH_USER BASIC_AUTH_PASSWORD"
  ok "plan: lists the variable and keychain item" sh -c "grep -q 'STAGING_READY=true' '$T/prov-plan.out' && grep -q 'keychain: team-staging-cmdtest-prov' '$T/prov-plan.out'"
  ok "plan: nothing stored" sh -c "[ ! -d '$STUB_DIR/secrets' ] && [ ! -d '$STUB_DIR/variables' ] && [ ! -e '$STUB_DIR/security-i.log' ]"
  ok "plan: one ssh connection" [ "$(grep -c . "$STUB_DIR/ssh.log")" = 1 ]
  pw=$(sed -n 's/^BASIC_AUTH_PASSWORD="\(.*\)"$/\1/p' "$STUB_DIR/bundle/inputs.conf")
  ok "plan: the generated password is never printed" sh -c "[ -n '$pw' ] && ! grep -q '$pw' '$T/last.out' '$T/last.err'"

  : > "$STUB_DIR/ssh.log"
  expect_rc 0 "staging apply (server output leaks on purpose)" sh -c "cd '$r' && STUB_LEAK=1 /bin/bash '$BIN/team-provision' staging --apply"
  cat "$T/last.out" "$T/last.err" > "$T/prov-apply.all"
  pw=$(sed -n 's/^BASIC_AUTH_PASSWORD="\(.*\)"$/\1/p' "$STUB_DIR/bundle/inputs.conf")
  pub=$(sed -n 's/^DEPLOY_PUBKEY="\(.*\)"$/\1/p' "$STUB_DIR/bundle/inputs.conf")
  # shellcheck disable=SC2016  # literal text of the remote command
  ok "apply: remote command has --apply" grep -q -- '--bundle "$d" --apply;' "$STUB_DIR/provision-cmd"
  ok "apply: exactly the §12 staging secret names" [ "$(secret_files)" = "staging.APP_URL staging.BASIC_AUTH_PASSWORD staging.BASIC_AUTH_USER staging.DEPLOY_HOST staging.DEPLOY_KNOWN_HOSTS staging.DEPLOY_PORT staging.DEPLOY_SSH_KEY staging.DEPLOY_USER staging.HEALTH_URL " ]
  ok "apply: host/user/port values" sh -c "[ \"\$(cat '$STUB_DIR/secrets/staging.DEPLOY_HOST')\" = 192.0.2.10 ] && [ \"\$(cat '$STUB_DIR/secrets/staging.DEPLOY_USER')\" = cmdtest-prov-staging ] && [ \"\$(cat '$STUB_DIR/secrets/staging.DEPLOY_PORT')\" = 22 ]"
  ok "apply: URLs" sh -c "[ \"\$(cat '$STUB_DIR/secrets/staging.APP_URL')\" = https://cmdtest-prov-staging.example.test ] && [ \"\$(cat '$STUB_DIR/secrets/staging.HEALTH_URL')\" = https://cmdtest-prov-staging.example.test/health ]"
  ok "apply: pinned known_hosts line for the VPS IP" [ "$(cat "$STUB_DIR/secrets/staging.DEPLOY_KNOWN_HOSTS")" = "192.0.2.10 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIStubHostKeyForTestsOnly0000000000000000000" ]
  ok "apply: the deploy private key matches the public key sent to the server" sh -c "chmod 600 '$STUB_DIR/secrets/staging.DEPLOY_SSH_KEY' && [ \"\$(ssh-keygen -y -f '$STUB_DIR/secrets/staging.DEPLOY_SSH_KEY' | cut -d' ' -f1,2)\" = '$pub' ]"
  ok "apply: basic auth values" sh -c "[ \"\$(cat '$STUB_DIR/secrets/staging.BASIC_AUTH_USER')\" = cmdtest-prov ] && [ \"\$(cat '$STUB_DIR/secrets/staging.BASIC_AUTH_PASSWORD')\" = '$pw' ]"
  ok "apply: STAGING_READY=true" [ "$(cat "$STUB_DIR/variables/STAGING_READY" 2>/dev/null)" = true ]
  ok "apply: keychain item stored via security -i (stdin)" grep -q "add-generic-password -U -s \"team-staging-cmdtest-prov\" -a \"cmdtest-prov\" .* -w \"$pw\"" "$STUB_DIR/security-i.log"
  ok "apply: the password never reaches argv" hasnt "$STUB_DIR/security.log" "$pw"
  ok "apply: the password is not in the output (even when the server echoes it)" hasnt "$T/prov-apply.all" "$pw"
  ok "apply: private key material is not in the output" sh -c "! grep -q 'c3R1Yi1wcml2YXRlLWtleS1ib2R5' '$T/prov-apply.all' && ! grep -q 'BEGIN OPENSSH PRIVATE KEY' '$T/prov-apply.all' && ! grep -qF \"\$(sed -n 2p '$STUB_DIR/secrets/staging.DEPLOY_SSH_KEY')\" '$T/prov-apply.all'"
  ok "apply: every gh call acted as the account with a token, for the right repo/env" sh -c "! grep 'secret set' '$STUB_DIR/gh.log' | grep -v 'token=yes secret set [A-Z_]* --env staging --repo test-owner/cmdtest-prov' | grep -q ."
  ok "apply: values went on stdin, never as gh arguments" sh -c "! grep -q -e '$pw' -e '192.0.2.10' -e 'cmdtest-prov-staging.example' '$STUB_DIR/gh.log' && [ \$(grep -c -e '--body' '$STUB_DIR/gh.log') = \$(grep -c 'variable set STAGING_READY --body true' '$STUB_DIR/gh.log') ]"
  ok "apply: host key pinned locally for team-deploy" [ "$(cat "$TEAM_CONFIG_DIR/projects/cmdtest-prov.known_hosts")" = "192.0.2.10 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIStubHostKeyForTestsOnly0000000000000000000" ]
  ok "apply: ssh only to the alias (never the IP)" sh -c "! grep -v -x 'vps-test' '$STUB_DIR/ssh-dest.log' | grep -q ."
  ok "apply: two connections (provision, host key), no retries" [ "$(grep -v '^-G ' "$STUB_DIR/ssh.log" | grep -c .)" = 2 ]

  # re-run without rotation keeps keys and login
  printf '%s\n%s\n' cmdtest-prov "$pw" > "$STUB_DIR/keychain-team-staging-cmdtest-prov"
  echo '[{"name":"DEPLOY_SSH_KEY"},{"name":"DEPLOY_HOST"}]' > "$STUB_DIR/secrets-staging.json"
  rm -rf "${STUB_DIR:?}/secrets"
  expect_rc 0 "staging re-apply without --rotate-keys" sh -c "cd '$r' && /bin/bash '$BIN/team-provision' staging --apply"
  ok "re-apply: same deploy public key sent" [ "$(sed -n 's/^DEPLOY_PUBKEY="\(.*\)"$/\1/p' "$STUB_DIR/bundle/inputs.conf")" = "$pub" ]
  ok "re-apply: DEPLOY_SSH_KEY not replaced" [ ! -e "$STUB_DIR/secrets/staging.DEPLOY_SSH_KEY" ]
  ok "re-apply: same staging password" [ "$(sed -n 's/^BASIC_AUTH_PASSWORD="\(.*\)"$/\1/p' "$STUB_DIR/bundle/inputs.conf")" = "$pw" ]
  expect_rc 0 "staging apply --rotate-keys" sh -c "cd '$r' && /bin/bash '$BIN/team-provision' staging --apply --rotate-keys"
  ok "rotate: new deploy key and secret" sh -c "[ \"\$(sed -n 's/^DEPLOY_PUBKEY=\"\(.*\)\"\$/\1/p' '$STUB_DIR/bundle/inputs.conf')\" != '$pub' ] && [ -s '$STUB_DIR/secrets/staging.DEPLOY_SSH_KEY' ]"
  ok "rotate: new staging password" [ "$(sed -n 's/^BASIC_AUTH_PASSWORD="\(.*\)"$/\1/p' "$STUB_DIR/bundle/inputs.conf")" != "$pw" ]
  rm -f "$STUB_DIR/secrets-staging.json" "$STUB_DIR/keychain-team-staging-cmdtest-prov"

  rm -rf "${STUB_DIR:?}/secrets" "${STUB_DIR:?}/variables"
  expect_rc 0 "production apply (public repo)" sh -c "cd '$r' && /bin/bash '$BIN/team-provision' production --apply"
  ok "production: exactly the §12 production secret names" [ "$(secret_files)" = "production.APP_URL production.DEPLOY_HOST production.DEPLOY_KNOWN_HOSTS production.DEPLOY_PORT production.DEPLOY_SSH_KEY production.DEPLOY_USER production.HEALTH_URL repo.PRODUCTION_HEALTH_URL " ]
  ok "production: PRODUCTION_READY=true" [ "$(cat "$STUB_DIR/variables/PRODUCTION_READY" 2>/dev/null)" = true ]
  ok "production: host from the pattern" grep -qx 'HOST="cmdtest-prov.example.test"' "$STUB_DIR/bundle/inputs.conf"
  ok "production: db-pull key installed, mode 600" sh -c "[ \"\$(stat -f %Lp '$HOME/.ssh/team-dbpull-cmdtest-prov')\" = 600 ]"
  ok "production: db-pull key matches DBPULL_PUBKEY" [ "$(ssh-keygen -y -f "$HOME/.ssh/team-dbpull-cmdtest-prov" | cut -d' ' -f1,2)" = "$(sed -n 's/^DBPULL_PUBKEY="\(.*\)"$/\1/p' "$STUB_DIR/bundle/inputs.conf")" ]

  rm -rf "${STUB_DIR:?}/secrets" "${STUB_DIR:?}/variables"
  expect_rc 1 "server failure: TEAM-RESULT fail → exit 1" sh -c "cd '$r' && STUB_PROVISION_FAIL=1 /bin/bash '$BIN/team-provision' staging --apply"
  ok "server failure: nothing stored" sh -c "[ ! -d '$STUB_DIR/secrets' ] && [ ! -d '$STUB_DIR/variables' ]"

  local rp="$T/privproj"
  make_project "$rp" cmdtest-priv postgres Makefile.pg "VISIBILITY=private"
  expect_rc 0 "private repo: production apply" sh -c "cd '$rp' && /bin/bash '$BIN/team-provision' production --apply"
  ok "private: no production values in GitHub" sh -c "[ ! -d '$STUB_DIR/secrets' ] && [ ! -e '$STUB_DIR/variables/PRODUCTION_READY' ]"
  ok "private: deploy key kept on the Mac, mode 600" [ "$(stat -f %Lp "$HOME/.ssh/team-deploy-cmdtest-priv-production" 2>/dev/null)" = 600 ]
  ok "private: host key pinned in the config folder" [ -s "$TEAM_CONFIG_DIR/projects/cmdtest-priv.known_hosts" ]
  expect_rc 2 "unknown argument" sh -c "cd '$r' && /bin/bash '$BIN/team-provision' staging --force"
}

# ------------------------------------------------------------------------------ deploy
t_deploy() {
  section "team-deploy (private fallback)"
  local r="$T/deployproj" sha
  make_project "$r" cmdtest-dep none Makefile.pg
  sha=$(git -C "$r" rev-parse HEAD)
  : > "$STUB_DIR/ssh.log"
  expect_rc 4 "production refused inside Claude Code" sh -c "cd '$r' && CLAUDECODE=1 /bin/bash '$BIN/team-deploy' production --apply"
  expect_rc 0 "plan by default" sh -c "cd '$r' && /bin/bash '$BIN/team-deploy' staging"
  ok "plan: no connection, says nothing changed" sh -c "[ ! -s '$STUB_DIR/ssh.log' ] && grep -q 'Nothing changed' '$T/last.out'"
  expect_rc 6 "no local deploy key → exit 6" sh -c "cd '$r' && /bin/bash '$BIN/team-deploy' staging --apply"
  printf 'stub key\n' > "$HOME/.ssh/team-deploy-cmdtest-dep-staging"
  chmod 600 "$HOME/.ssh/team-deploy-cmdtest-dep-staging"
  mkdir -p "$TEAM_CONFIG_DIR/projects"
  echo "192.0.2.10 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIStubHostKeyForTestsOnly0000000000000000000" > "$TEAM_CONFIG_DIR/projects/cmdtest-dep.known_hosts"
  expect_rc 4 "--sha that is not HEAD is refused" sh -c "cd '$r' && /bin/bash '$BIN/team-deploy' staging --sha 0000000 --apply"
  expect_rc 0 "staging deploy with the stored key" sh -c "cd '$r' && /bin/bash '$BIN/team-deploy' staging --sha '${sha:0:12}' --apply"
  ok "ssh: stored key, pinned host key, strict checking, deploy user, alias" grep -qF -- "-i $HOME/.ssh/team-deploy-cmdtest-dep-staging -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$TEAM_CONFIG_DIR/projects/cmdtest-dep.known_hosts -o GlobalKnownHostsFile=/dev/null -o HostKeyAlias=192.0.2.10 -l cmdtest-dep-staging vps-test deploy $sha" "$STUB_DIR/ssh.log"
  ok "ssh: never StrictHostKeyChecking=no" hasnt "$STUB_DIR/ssh.log" "StrictHostKeyChecking=no"
  ok "release tarball = artifact + ops/" sh -c "tar -tzf '$STUB_DIR/deploy-stdin.tar.gz' | grep -qx './index.html' && tar -tzf '$STUB_DIR/deploy-stdin.tar.gz' | grep -qx './ops/project.conf'"
  ok "release tarball kept as .team/release-<sha>.tar.gz" [ -s "$r/.team/release-$sha.tar.gz" ]
  expect_rc 7 "exit 7 passes through (release not on server)" sh -c "cd '$r' && STUB_DEPLOY_RC=7 /bin/bash '$BIN/team-deploy' staging --apply"
  local r3="$T/deploy-nc"
  make_project "$r3" cmdtest-dep none Makefile.unconfigured
  expect_rc 3 "make build not configured → exit 3" sh -c "cd '$r3' && /bin/bash '$BIN/team-deploy' staging --apply"
}

# ------------------------------------------------------------------------------ fences
t_fences() {
  section "team-check-fences"
  local fence="$REPO/plugins/team/hooks/fence" r="$T/fenceproj"
  git init -q -b main "$r"
  mkdir -p "$r/.claude/hooks"
  cp "$REPO/managed/.claude/settings.json" "$r/.claude/settings.json"
  cp "$REPO/managed/.claude/hooks/plugin-check" "$r/.claude/hooks/plugin-check"
  chmod +x "$r/.claude/hooks/plugin-check"
  mkdir -p "$CLAUDE_CONFIG_DIR/plugins"
  echo '{"version":2,"plugins":{"team@dev-standards":[{"scope":"project","version":"0.1.0"}]}}' > "$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json"
  printf '#!/bin/bash\ncat >/dev/null\nexit 0\n' > "$T/allow-all-hook"
  chmod +x "$T/allow-all-hook"
  expect_rc 1 "an allow-everything hook fails the table" sh -c "cd '$r' && /bin/bash '$BIN/team-check-fences' --hook '$T/allow-all-hook' --offline"
  ok "the allow-everything table names forbidden actions as FAIL" sh -c "grep -q '^FAIL .*push to main' '$T/last.out' && grep -q '^PASS .*settings deny: Bash(git tag \*)' '$T/last.out'"
  expect_rc 5 "missing hook → exit 5" sh -c "cd '$r' && /bin/bash '$BIN/team-check-fences' --hook '$T/no-such-hook' --offline"
  if [ ! -x "$fence" ]; then
    skip "real fence hook not present yet ($fence)"
    return
  fi
  expect_rc 0 "real fence: every forbidden action denied, every control allowed" sh -c "cd '$r' && /bin/bash '$BIN/team-check-fences' --hook '$fence' --offline"
  if [ "$RC" != 0 ]; then grep '^FAIL' "$T/last.out" | sed 's/^/        | /'; fi
  ok "real fence: table covers the forbidden list" [ "$(grep -cE '^PASS +deny ' "$T/last.out")" -ge 45 ]
  ok "real fence: simulated denials stay out of the real fence.log" [ ! -e "$TEAM_CONFIG_DIR/fence.log" ]
  jq '.permissions.deny -= ["Bash(git tag *)"]' "$REPO/managed/.claude/settings.json" > "$r/.claude/settings.json"
  expect_rc 1 "a missing deny rule fails the table" sh -c "cd '$r' && /bin/bash '$BIN/team-check-fences' --hook '$fence' --offline"
  rm -f "$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json"
  cp "$REPO/managed/.claude/settings.json" "$r/.claude/settings.json"
  expect_rc 1 "plugin not installed fails the table" sh -c "cd '$r' && /bin/bash '$BIN/team-check-fences' --hook '$fence' --offline"
}

# ------------------------------------------------------------------------------ shellcheck
t_shellcheck() {
  section "shellcheck"
  if ! command -v shellcheck >/dev/null 2>&1; then skip "shellcheck not installed"; return; fi
  local c files=""
  for c in $MY_CMDS; do files="$files $REPO/plugins/team/bin/$c"; done
  # shellcheck disable=SC2086  # word splitting of the file list is intended
  ok "shellcheck: commands and team-local.sh" shellcheck -x $files "$REPO/plugins/team/lib/team-local.sh"
  ok "shellcheck: tests and stubs" shellcheck -x "$HERE/run.sh" "$HERE/helpers.sh" "$HERE"/stubs/*
}

if want worktrees || want identity || want dbpull || want remove || want mysql; then
  if start_pg; then echo "throwaway Postgres: $PG_NAME on 127.0.0.1:$PG_PORT"; else echo "Docker/psql unavailable: database tests will be skipped"; fi
fi
want help && t_help
want lib && t_lib
want hooks && t_hooks
want app && t_app
want worktrees && t_worktrees
want identity && t_identity
want dbpull && t_dbpull
want remove && t_remove
want mysql && t_mysql
want login && t_login
want flag && t_flag
want vps && t_vps
want provision && t_provision
want deploy && t_deploy
want fences && t_fences
want shellcheck && t_shellcheck
summary
