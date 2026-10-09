# shellcheck shell=bash disable=SC2034  # values here are used by in-container.sh
# Helpers for tests/server/in-container.sh. Runs INSIDE the throwaway team-srvtest container
# (Ubuntu, bash 5, root). Never used on a real server.

SRC=${SRC:-/src}
SERVER=$SRC/server
FIX=$SRC/tests/fixtures
LIB=/usr/local/lib/team
T=${T:-/tmp/team-srvtest}
LOG=$T/last.log
mkdir -p "$T"

PASS=0 FAIL=0 FAILED=()
pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
fail() {
  FAIL=$((FAIL + 1)); FAILED+=("$1"); printf 'FAIL  %s\n' "$1"
  if [[ -s $LOG ]]; then tail -n "${TAIL:-25}" "$LOG" | sed 's/^/      | /'; fi
  return 0
}
section() { printf '\n=== %s\n' "$1"; }

# check <description> <command...> : PASS when the command exits 0 (output kept in $LOG)
check() {
  local d=$1; shift
  if "$@" > "$LOG" 2>&1; then pass "$d"; else fail "$d"; fi
}
# check_not <description> <command...> : PASS when the command fails
check_not() {
  local d=$1; shift
  if "$@" > "$LOG" 2>&1; then fail "$d"; else pass "$d"; fi
}
# expect_rc <code> <description> <command...>
expect_rc() {
  local want=$1 d=$2 rc; shift 2
  "$@" > "$LOG" 2>&1; rc=$?
  if [[ $rc == "$want" ]]; then pass "$d"; else fail "$d (exit $rc, wanted $want)"; fi
}
# ok_if <description> <bash condition string evaluated with [[ ]] semantics via eval>
ok_if() {
  local d=$1; shift
  if eval "$*"; then pass "$d"
  else printf '      condition: %s\n' "$*" | cut -c1-300; fail "$d"; fi
}

# make_bundle <project> <env> <dir> [extra inputs.conf lines...] : what team-provision would send.
# FIXTURE=<name> reuses another fixture's ops/ under a new project name.
make_bundle() {
  local project=$1 env=$2 dir=$3 host fixture=${FIXTURE:-$1}; shift 3
  rm -rf "${dir:?}"
  mkdir -p "$dir"
  cp "$SERVER"/* "$dir/"
  cp -R "$FIX/$fixture/ops" "$dir/ops"
  sed -i "s/^PROJECT_NAME=.*/PROJECT_NAME=$project/" "$dir/ops/project.conf"
  mkdir -p "$T/keys"
  [[ -e $T/keys/$project-$env-deploy ]] || ssh-keygen -q -t ed25519 -N '' -C "x" -f "$T/keys/$project-$env-deploy"
  [[ -e $T/keys/$project-dbpull ]] || ssh-keygen -q -t ed25519 -N '' -C "x" -f "$T/keys/$project-dbpull"
  if [[ $env == staging ]]; then host=$project-staging.example.test; else host=$project.example.test; fi
  {
    printf 'PROJECT=%s\nENV=%s\nHOST=%s\n' "$project" "$env" "$host"
    if [[ $env == staging ]]; then printf 'BASIC_AUTH_USER=client\nBASIC_AUTH_PASSWORD=staging-pass-%s\n' "$project"; fi
    printf 'DEPLOY_PUBKEY=%s\n' "$(cat "$T/keys/$project-$env-deploy.pub")"
    [[ $env == production ]] && printf 'DBPULL_PUBKEY=%s\n' "$(cat "$T/keys/$project-dbpull.pub")"
    printf 'TIMEZONE=%s\nLOW_TRAFFIC_HOUR=%s\nACME_EMAIL=\nTLS=skip\n' \
      "$(sed -n 's/^PROJECT_TIMEZONE=//p' "$dir/ops/project.conf")" \
      "$(sed -n 's/^LOW_TRAFFIC_HOUR=//p' "$dir/ops/project.conf")"
    local l; for l in "$@"; do printf '%s\n' "$l"; done
  } > "$dir/inputs.conf"
  chmod 600 "$dir/inputs.conf"
}

# provision_run <bundle> [--apply] : run provision as team-provision does (bash <bundle>/provision)
provision_run() { bash "$1/provision" --bundle "$1" "${@:2}"; }

# changes_in <file> : count of [create]/[update]/[remove] lines
changes_in() { grep -cE '^\[(create|update|remove)\]' "$1" || true; }

# managed_hash : hash of every file the pack manages on this "server"
managed_hash() {
  {
    find /etc/team /usr/local/lib/team /etc/nginx/sites-available /etc/nginx/team /etc/sudoers.d \
         /etc/logrotate.d /etc/php -type f 2>/dev/null
    find /etc/systemd/system -maxdepth 1 -name 'team-*' -type f 2>/dev/null
    find /srv/team -path '*/shared/.env' -type f 2>/dev/null
    find /srv/team -path '*/.ssh/*' -type f 2>/dev/null
  } | sort | xargs -r sha256sum | sha256sum | cut -d' ' -f1
  stat -c '%n %a %U %G' /etc/nginx/sites-enabled/* 2>/dev/null | sha256sum | cut -d' ' -f1
}

# env_get <env file> <key>
env_get() { sed -n "s/^$2=//p" "$1" | tail -n 1; }

# make_release <dir> <tarball> [health=yes|no] [ops-from-project] : a release tarball like package.sh
make_release() {
  local dir=$1 out=$2 health=${3:-yes} ops=${4:-}
  rm -rf "${dir:?}"; mkdir -p "$dir/public" "$dir/storage/logs"
  printf 'release %s\n' "$(basename "$out")" > "$dir/index.html"
  printf 'release %s\n' "$(basename "$out")" > "$dir/public/index.html"
  printf 'seed\n' > "$dir/storage/logs/seed.log"
  if [[ $health == yes ]]; then printf 'ok\n' > "$dir/health"; printf 'ok\n' > "$dir/public/health"; fi
  [[ -n $ops ]] && cp -R "$FIX/$ops/ops" "$dir/ops"
  tar -czf "$out" -C "$dir" .
}

# deploy_as <user> <project> <env> <SSH_ORIGINAL_COMMAND> [stdin file]
deploy_as() {
  local user=$1 project=$2 env=$3 cmd=$4 in=${5:-/dev/null}
  runuser -u "$user" -- env SSH_ORIGINAL_COMMAND="$cmd" TEAM_HEALTH_RETRIES="${TEAM_HEALTH_RETRIES:-4}" \
    TEAM_HEALTH_DELAY="${TEAM_HEALTH_DELAY:-1}" "$LIB/deploy-receive" "$project" "$env" < "$in"
}

# stand_in_web <user> <port> <dir> : the stand-in app (python http.server serving current/)
stand_in_web() {
  runuser -u "$1" -- python3 -m http.server "$2" --bind 127.0.0.1 --directory "$3" > "$T/web-$2.log" 2>&1 &
  printf '%s' "$!"
}
# wait_http <code> <curl args...> : true once curl gets <code> (nginx applies a reload a moment
# after `service nginx reload` returns)
wait_http() {
  local want=$1 i got=""; shift
  for ((i = 0; i < 20; i++)); do
    got=$(curl -s -o /dev/null -w '%{http_code}' "$@")
    [[ $got == "$want" ]] && return 0
    sleep 0.25
  done
  printf '      got HTTP %s, wanted %s\n' "$got" "$want"
  return 1
}
wait_port() { local i; for ((i = 0; i < 50; i++)); do ss -ltnH | grep -q ":$1 " && return 0; sleep 0.2; done; return 1; }

pg() { runuser -u postgres -- psql -X -q -v ON_ERROR_STOP=1 "$@"; }
pgq() { runuser -u postgres -- psql -X -At -v ON_ERROR_STOP=1 "$@"; }
# MariaDB 11+ names its client mariadb (the mysql name may be absent); MySQL keeps mysql.
MYSQL_BIN=mysql
command -v mariadb > /dev/null 2>&1 && MYSQL_BIN=mariadb
my() { "$MYSQL_BIN" "$@"; }
myq() { "$MYSQL_BIN" -N -B "$@"; }
# The release's PHP version (8.3 on 24.04, 8.5 on 26.04) and its sudo (sudo or sudo-rs)
PHPV=$(find /etc/php -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -V | tail -n 1)
SUDO_IMPL=classic
sudo --version 2>/dev/null | head -n 1 | grep -q '^sudo-rs' && SUDO_IMPL=sudo-rs

# sudo_lists <user> <command…> : `sudo -l -U` (sudo and sudo-rs alike) shows every command
sudo_lists() {
  local user=$1 out c
  shift
  out=$(sudo -n -l -U "$user" | tr -s ' \t\n' ' ') || return 1
  for c in "$@"; do [[ $out == *"$c"* ]] || { printf 'missing: %s\nlisted: %s\n' "$c" "$out"; return 1; }; done
}

conf_get() { sed -n "s/^$2=//p" "$1" | tail -n 1; }
