# shellcheck shell=bash disable=SC2034  # variables used by run.sh
# Helpers for tests/commands/local/run.sh. Sourced, never executed. bash 3.2.
#
# Safety: everything happens in one mktemp -d sandbox with a fake HOME, a fake
# TEAM_CONFIG_DIR, stub gh/ssh/security/pbcopy first on PATH, and throwaway Docker
# containers named team-cmdtest-* that are removed by name at the end. The owner's
# Postgres on 5432, real config, keychain, ~/.ssh and GitHub are never touched.

PASS=0 FAIL=0 SKIP=0
MY_CMDS="team-new-worktree team-remove-worktree team-hooks team-app team-db-pull team-staging-login team-check-fences team-discover team-provision team-flag team-refresh-staging team-deploy"
PG_NAME="" PG_PORT="" PG_OK=0
MY_CONTAINER="team-cmdtest-my-db" MY_VOLUME="team-cmdtest-my-db-data" MY_USED=0
RECORDED_PIDS=""

# file_mode <path> : octal permission bits (GNU stat first; BSD stat rejects -c)
file_mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
skip() { SKIP=$((SKIP + 1)); printf 'SKIP  %s\n' "$*"; }
section() { printf '\n== %s\n' "$*"; }

# ok <label> <command...> : PASS when the command succeeds
ok() {
  local label="$1"
  shift
  if "$@"; then pass "$label"; else fail "$label"; fi
}

# run_cmd <outfile-prefix> <command...> : runs it, stdout → $1.out, stderr → $1.err, sets RC
run_cmd() {
  local p="$1"
  shift
  RC=0
  "$@" > "$p.out" 2> "$p.err" || RC=$?
}

# expect_rc <code> <label> <command...> : output in $T/last.out / last.err
expect_rc() {
  local want="$1" label="$2"
  shift 2
  run_cmd "$T/last" "$@"
  if [ "$RC" = "$want" ]; then
    pass "$label"
  else
    fail "$label (exit $RC, wanted $want)"
    sed 's/^/        | /' "$T/last.err" | tail -n 8
  fi
}

has() { grep -Fq -- "$2" "$1" 2>/dev/null; }
hasnt() { ! grep -Fq -- "$2" "$1" 2>/dev/null; }
kv() { sed -n "s/^$2=//p" "$1" | head -n 1; }   # kv <file> <key>
cmd() { /bin/bash "$BIN/$1" "${@:2}"; }         # run one of our commands with bash 3.2

free_port() {   # free_port <lo> <hi>
  local p="$1"
  while [ "$p" -le "$2" ]; do
    if ! lsof -nP -iTCP:"$p" -sTCP:LISTEN -t >/dev/null 2>&1 && ! (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then
      echo "$p"
      return 0
    fi
    p=$((p + 1))
  done
  return 1
}

free_block() {   # free_block <lo> <hi> <size> : first port starting a free block
  local b="$1" i okb
  while [ $((b + $3)) -le "$2" ]; do
    okb=1
    for ((i = 0; i < $3; i++)); do
      if lsof -nP -iTCP:"$((b + i))" -sTCP:LISTEN -t >/dev/null 2>&1; then okb=0; break; fi
    done
    [ "$okb" = 1 ] && { echo "$b"; return 0; }
    b=$((b + $3))
  done
  return 1
}

# start_listener <port> <dir> : a decoy HTTP listener we own; PID recorded for cleanup
start_listener() {
  mkdir -p "$2"
  (cd "$2" && exec python3 -m http.server "$1" --bind 127.0.0.1 >/dev/null 2>&1) &
  RECORDED_PIDS="$RECORDED_PIDS $!:$(cd "$2" && pwd -P)"
  local i
  for ((i = 0; i < 50; i++)); do
    lsof -nP -iTCP:"$1" -sTCP:LISTEN -t >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
}

# stop_recorded : stops only PIDs we started, after checking their cwd (never pkill)
stop_recorded() {
  local e pid dir cwd
  for e in $RECORDED_PIDS; do
    pid="${e%%:*}" dir="${e#*:}"
    kill -0 "$pid" 2>/dev/null || continue
    cwd=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1)
    if [ "$cwd" = "$dir" ]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  RECORDED_PIDS=""
}

setup_sandbox() {
  REAL_HOME="$HOME"
  export DOCKER_CONFIG="${DOCKER_CONFIG:-$REAL_HOME/.docker}"
  T=$(mktemp -d "${TMPDIR:-/tmp}/team-cmdtest.XXXXXX")
  T=$(cd "$T" && pwd -P)
  export HOME="$T/home"
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  export XDG_CONFIG_HOME="$HOME/.config" GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME="Cmd Test" GIT_AUTHOR_EMAIL="cmdtest@example.invalid"
  export GIT_COMMITTER_NAME="Cmd Test" GIT_COMMITTER_EMAIL="cmdtest@example.invalid"
  export STUB_DIR="$T/stub" TEAM_CONFIG_DIR="$T/config" TEAM_SNAPSHOT_CACHE="$T/cache"
  export CLAUDE_CONFIG_DIR="$T/claude-config"
  mkdir -p "$STUB_DIR" "$TEAM_CONFIG_DIR" "$CLAUDE_CONFIG_DIR"
  unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT PGHOST PGPORT PGDATABASE PGSERVICE PGUSER PGPASSWORD GH_TOKEN GITHUB_TOKEN
  export PATH="$HERE/stubs:$PATH"
  # Network guard (tests/lib/net-guard.sh): fake ssh/scp/sftp/rsync go FIRST on PATH, log every
  # call and refuse; ssh calls are handed to the stubs/ssh simulator after logging. Never connects.
  # shellcheck source=SCRIPTDIR/../../lib/net-guard.sh
  . "$REPO/tests/lib/net-guard.sh"
  NET_GUARD_REAL_HOME="$REAL_HOME"
  net_guard_install "$T/net-guard"
  export NET_GUARD_SIMULATOR="$HERE/stubs"
  if net_guard_assert; then pass "net-guard: fake ssh/scp/sftp/rsync first on PATH, refusing and logging"; else echo "net-guard is not in place; refusing to run any test" >&2; exit 1; fi

  # a private copy of the plugin (bin + lib + server); placeholders for server scripts
  # another engineer may not have written yet (the ssh stub never runs them)
  PLUGIN="$T/plugin"
  mkdir -p "$PLUGIN/server"
  cp -R "$REPO/plugins/team/bin" "$REPO/plugins/team/lib" "$PLUGIN/"
  if [ -d "$REPO/plugins/team/server" ]; then cp -R "$REPO/plugins/team/server/." "$PLUGIN/server/"; fi
  for s in provision discover lib.sh; do
    [ -f "$PLUGIN/server/$s" ] || printf '#!/usr/bin/env bash\necho "placeholder %s"\n' "$s" > "$PLUGIN/server/$s"
  done
  BIN="$PLUGIN/bin"

  PBASE=$(free_block 18400 18990 30) || { echo "no free port block" >&2; exit 1; }
  write_config "$TEAM_CONFIG_DIR"
}

# write_config <dir> [extra defaults lines...]
write_config() {
  local d="$1"
  shift
  mkdir -p "$d"
  {
    echo "# fake config for tests: TEST-NET address, .test domain"
    echo "VPS_ALIAS=vps-test"
    echo "VPS_IP=192.0.2.10"
    echo "VPS_HOSTNAME=vps.example.test"
    echo "VPS_ADMIN_USER=tester"
    echo 'VPS_FORBIDDEN_ALIASES="vps-test-root"'
    echo "DOMAIN=example.test"
    echo "PRODUCTION_HOST_PATTERN={app}.example.test"
    echo "STAGING_HOST_PATTERN={app}-staging.example.test"
    echo "DEFAULT_TIMEZONE=Asia/Manila"
    echo "DEFAULT_GITHUB_ACCOUNT=test-owner"
    echo "OWNER_LOGIN=test-owner"
    echo "MAX_PARALLEL_WRITERS=3"
    echo "WORKTREE_PORT_MIN=$PBASE"
    echo "WORKTREE_PORT_MAX=$((PBASE + 29))"
    echo "BACKGROUND_PERMISSION_MODE="
    echo "LOCAL_PG_HOST=127.0.0.1"
    echo "LOCAL_PG_PORT=${PG_PORT:-1}"
    echo "TEAM_BIN=$BIN"
    echo "ACME_EMAIL=owner@example.test"
    for l in "$@"; do echo "$l"; done
  } > "$d/defaults.conf"
  echo "account|test-owner|github.com|Test Owner|owner@example.test" > "$d/accounts.conf"
}

start_pg() {
  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    return 1
  fi
  command -v psql >/dev/null 2>&1 || return 1
  PG_NAME="team-cmdtest-pg-$$"
  PG_PORT=$(free_port 56400 56499) || return 1
  PG_PASS=$(openssl rand -hex 12)
  POSTGRES_PASSWORD="$PG_PASS" docker run -d --name "$PG_NAME" -e POSTGRES_PASSWORD \
    -p "127.0.0.1:$PG_PORT:5432" postgres:16-alpine >/dev/null || { PG_NAME=""; return 1; }
  local i
  for ((i = 0; i < 90; i++)); do
    if PGPASSWORD="$PG_PASS" psql -X -h 127.0.0.1 -p "$PG_PORT" -U postgres -d postgres -Atc 'SELECT 1' >/dev/null 2>&1; then
      export PGUSER=postgres PGPASSWORD="$PG_PASS"
      PG_OK=1
      write_config "$TEAM_CONFIG_DIR"
      return 0
    fi
    sleep 1
  done
  return 1
}

pgq() { psql -X -h 127.0.0.1 -p "$PG_PORT" -U postgres -d "${2:-postgres}" -Atc "$1" 2>/dev/null; }

cleanup() {
  local f d
  find "$T" -path '*/.team/app.pid' 2>/dev/null | while IFS= read -r f; do
    d=$(dirname "$(dirname "$f")")
    (cd "$d" && /bin/bash "$BIN/team-app" down >/dev/null 2>&1) || true
  done
  stop_recorded
  [ -n "$PG_NAME" ] && docker rm -f -v "$PG_NAME" >/dev/null 2>&1
  if [ "$MY_USED" = 1 ]; then
    docker rm -f -v "$MY_CONTAINER" >/dev/null 2>&1
    docker volume rm "$MY_VOLUME" >/dev/null 2>&1
  fi
  [ -n "${T:-}" ] && rm -rf "${T:?}"
  return 0
}

# make_project <dir> <project> <engine> <makefile fixture> [extra project.conf lines...]
# A main checkout whose origin is git@github.com:test-owner/<project>.git, rewritten with
# url.insteadOf to a local bare repo (no network; the ssh stub would refuse anyway).
make_project() {
  local dir="$1" project="$2" engine="$3" mk="$4" l
  shift 4
  git init -q --bare -b main "$dir.origin.git"
  git init -q -b main "$dir"
  git -C "$dir" config "url.$dir.origin.git.insteadOf" "git@github.com:test-owner/$project.git"
  git -C "$dir" remote add origin "git@github.com:test-owner/$project.git"
  mkdir -p "$dir/ops"
  {
    echo "PROJECT_NAME=$project"
    echo "GITHUB_ACCOUNT=test-owner"
    echo "GITHUB_SSH_HOST=github.com"
    echo "GITHUB_REPO=test-owner/$project"
    echo "DB_ENGINE=$engine"
    echo "WEB_MODE=proxy"
    echo "HEALTH_PATH=/health"
    echo "MIGRATE_CMD=make migrate"
    echo "SEED_CMD=make seed"
    echo "PROJECT_TIMEZONE=Asia/Manila"
    echo "LOW_TRAFFIC_HOUR=3"
    echo "ENV_FILE=.env"
    echo "ARTIFACT_DIR=.team/artifact"
    for l in "$@"; do echo "$l"; done
  } > "$dir/ops/project.conf"
  printf 'web|web|make dev\n' > "$dir/ops/services.conf"
  printf '.env\n.team/\n.claude/worktrees/\n' > "$dir/.gitignore"
  printf 'PORT=3000\nAPP_URL=http://localhost:3000\nDATABASE_URL=\nMAIL_MODE=smtp\nFOO=bar\n' > "$dir/.env.example"
  cp "$HERE/fixtures/$mk" "$dir/Makefile"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "chore: fixture project"
  git -C "$dir" push -q -u origin main 2>/dev/null
}

issue_json() {   # issue_json <n> <title> <label>
  jq -n --arg t "$2" --arg l "$3" '{title: $t, labels: [{name: $l}]}' > "$STUB_DIR/issue-$1.json"
}

summary() {
  printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
  [ "$FAIL" = 0 ]
}
