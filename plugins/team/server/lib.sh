# shellcheck shell=bash disable=SC2034,SC2016  # constants are used by the scripts that source this; SQL backticks are literal
# Shared helpers for the team server scripts. Sourced, never executed.
# Runs on the server (Linux, bash 5, GNU tools). Contract: docs/rules.md §4 (exit codes),
# §8 (ops/anonymize), §11 (server paths, users, units, keys, env templates).
#
# Every script does:
#   TEAM_PROG=<name>
#   TEAM_SELF_DIR=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
#   . "$TEAM_SELF_DIR/lib.sh"

shopt -u patsub_replacement 2>/dev/null || true   # bash 5.2: keep '&' literal in ${v/pat/repl}
# Locale-independent behaviour: in some locales [a-z] also matches capitals, and sort/grep vary.
# The caller's locale is restored only for the app's own MIGRATE_CMD (team_run_migrate).
TEAM_CALLER_LC_ALL=${LC_ALL-__unset__}
export LC_ALL=C

# ---------------------------------------------------------------------------- paths and names
TEAM_LIB_DIR=/usr/local/lib/team
TEAM_ETC_DIR=/etc/team
TEAM_PROJECTS_DIR=/etc/team/projects
TEAM_SRV_ROOT=/srv/team
TEAM_VAR_ROOT=/var/lib/team
TEAM_LOG_DIR=/var/log/team
TEAM_ACME_ROOT=/var/www/team-acme
TEAM_NGINX_AUTH_DIR=/etc/nginx/team
TEAM_PORT_MIN=9100
TEAM_PORT_MAX=9899
TEAM_KEEP_RELEASES=5
TEAM_KEEP_SNAPSHOTS=7
TEAM_KEEP_BACKUPS=14
TEAM_KEEP_PREDEPLOY=5
TEAM_SCRIPTS="discover provision deploy-receive snapshot serve-snapshot refresh-staging backup flag lib.sh"
# Users that exist on the shared server and must never be reused or touched.
TEAM_RESERVED_USERS="root deploy nodeapp serum72deploy ubuntu www-data postgres mysql nobody"
TEAM_PII_FILE="$TEAM_LIB_DIR/pii-patterns.txt"

# Exit codes (docs/rules.md §4)
TEAM_EXIT_FAIL=1
TEAM_EXIT_USAGE=2
TEAM_EXIT_NOT_CONFIGURED=3
TEAM_EXIT_REFUSED=4
TEAM_EXIT_PREREQ=5
TEAM_EXIT_OWNER=6
TEAM_EXIT_NO_RELEASE=7

TEAM_PROG="${TEAM_PROG:-team}"
TEAM_APPLY="${TEAM_APPLY:-0}"
TEAM_CHANGES=0
TEAM_FAIL_REASON=""

# ---------------------------------------------------------------------------- messages
team_say()  { printf '%s\n' "$*"; }
team_warn() { printf '[warn] %s\n' "$*"; }

# team_die <code> <message...> : message on stderr, remembered for TEAM-RESULT lines
team_die() {
  local code=$1; shift
  TEAM_FAIL_REASON="$*"
  printf '%s: %s\n' "$TEAM_PROG" "$*" >&2
  exit "$code"
}
team_usage_error() { team_die "$TEAM_EXIT_USAGE" "$* (see --help)"; }

# team_plan <kind> <message> : one plan line. create/update/remove count as changes.
team_plan() {
  case $1 in create|update|remove) TEAM_CHANGES=$((TEAM_CHANGES + 1)) ;; esac
  printf '[%s] %s\n' "$1" "$2"
}

# team_err_trap : install from scripts with `trap team_err_trap ERR` (needs set -E). Records where an
# unexpected failure happened without printing the command line (it might hold a value).
team_err_trap() {
  local rc=$? line=${BASH_LINENO[0]:-?}
  [[ -n $TEAM_FAIL_REASON ]] || TEAM_FAIL_REASON="unexpected error (exit $rc) near line $line"
}

# ---------------------------------------------------------------------------- small utilities
team_utc_now()   { date -u +%Y-%m-%dT%H:%M:%SZ; }
team_utc_stamp() { date -u +%Y%m%dT%H%M%SZ; }
team_systemd_running() { [[ -d /run/systemd/system ]]; }

team_trim() {
  local s=$1
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf '%s' "$s"
}

# team_conf_get <file> <key> [default] : KEY=value files, parsed, never sourced. Last assignment
# wins; one pair of surrounding quotes is stripped; empty or missing → default.
team_conf_get() {
  local file=$1 key=$2 default=${3-} line k v val=""
  if [[ -r $file ]]; then
    while IFS= read -r line || [[ -n $line ]]; do
      line=${line%$'\r'}
      [[ $line =~ ^[[:space:]]*# ]] && continue
      [[ $line == *=* ]] || continue
      k=$(team_trim "${line%%=*}")
      [[ $k == "$key" ]] || continue
      v=$(team_trim "${line#*=}")
      if [[ ${#v} -ge 2 && $v == \"*\" ]]; then v=${v:1:${#v}-2}
      elif [[ ${#v} -ge 2 && $v == \'*\' ]]; then v=${v:1:${#v}-2}; fi
      val=$v
    done < "$file"
  fi
  if [[ -n $val ]]; then printf '%s' "$val"; else printf '%s' "$default"; fi
}

# team_env_export <file> : export KEY=VALUE lines of a dotenv file (parsed, never sourced)
team_env_export() {
  local file=$1 line k v
  [[ -r $file ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    [[ $line =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    k=${BASH_REMATCH[2]}
    v=${BASH_REMATCH[3]}
    if [[ ${#v} -ge 2 && $v == \"*\" ]]; then v=${v:1:${#v}-2}
    elif [[ ${#v} -ge 2 && $v == \'*\' ]]; then v=${v:1:${#v}-2}; fi
    export "$k=$v"
  done < "$file"
}

# team_env_keys <file> : the KEY names defined in a dotenv-style file, one per line
team_env_keys() {
  local line
  [[ -r $1 ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)= ]] && printf '%s\n' "${BASH_REMATCH[2]}"
  done < "$1"
  return 0
}

team_require_root() {
  [[ $(id -u) -eq 0 ]] || team_die "$TEAM_EXIT_PREREQ" "run as root (sudo $TEAM_PROG …)"
}

# team_require_cmd <cmd>... : exit 5 naming what is missing
team_require_cmd() {
  local c missing=""
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing="$missing $c"; done
  [[ -z $missing ]] || team_die "$TEAM_EXIT_PREREQ" "missing required tool(s):$missing"
}

# team_os_check : warn (never fail) unless this is Ubuntu 24.04 or a newer LTS
team_os_check() {
  local id ver
  id=$(team_conf_get /etc/os-release ID unknown)
  ver=$(team_conf_get /etc/os-release VERSION_ID unknown)
  if [[ $id == ubuntu && $ver =~ ^([0-9]+)\.04$ ]] && (( BASH_REMATCH[1] >= 24 && BASH_REMATCH[1] % 2 == 0 )); then
    return 0
  fi
  team_warn "untested OS ($id $ver): supported are Ubuntu 24.04 and newer LTS releases; continuing"
}

# team_flock <name> <wait-seconds> : exclusive lock on fd 9 for the rest of the script. Root's locks
# live in /run/team (root-only), never in a world-writable folder where a symlink could be planted.
team_flock() {
  local name=$1 wait=$2 file
  install -d -m 755 -o root -g root /run/team
  file=/run/team/$name.lock
  [[ -L $file ]] && rm -f -- "$file"
  exec 9>>"$file"
  flock -w "$wait" 9 || team_die "$TEAM_EXIT_FAIL" "another team job holds the $name lock (waited ${wait}s)"
}

# ---------------------------------------------------------------------------- validation
team_valid_project() { [[ $1 =~ ^[a-z][a-z0-9-]{1,20}$ && $1 != *- && $1 != *--* ]]; }
team_valid_env()     { [[ $1 == staging || $1 == production ]]; }
team_valid_sha()     { [[ $1 =~ ^[0-9a-f]{7,40}$ ]]; }
team_valid_ident()   { [[ $1 =~ ^[a-z][a-z0-9_]{0,62}$ ]]; }
team_valid_relpath() { [[ $1 =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ && /$1/ != */../* && /$1/ != */./* ]]; }

team_check_project_env() {
  team_valid_project "$1" || team_usage_error "bad project name '$1' (expected [a-z][a-z0-9-]{1,20})"
  team_valid_env "$2" || team_usage_error "bad environment '$2' (expected staging or production)"
}

# ---------------------------------------------------------------------------- per-environment names
team_app_user()  { printf '%s-%s' "$1" "$2"; }
team_app_dir()   { printf '%s/%s/%s' "$TEAM_SRV_ROOT" "$1" "$2"; }
team_db_ident()  { printf '%s_%s' "${1//-/_}" "$2"; }
team_conf_file() { printf '%s/%s-%s.conf' "$TEAM_PROJECTS_DIR" "$1" "$2"; }
team_ledger_file() { printf '%s/%s-%s.resources' "$TEAM_PROJECTS_DIR" "$1" "$2"; }
team_salt_file() { printf '%s/%s.salt' "$TEAM_PROJECTS_DIR" "$1"; }
team_dbpass_file() { printf '%s/%s-%s.dbpass' "$TEAM_PROJECTS_DIR" "$1" "$2"; }

# ---------------------------------------------------------------------------- resource ledger
# /etc/team/projects/<project>-<env>.resources (root 600): one `kind|name` line per thing the pack
# created. Only names listed here may be reused, changed or removed by the pack.
team_ledger_has() { # <project> <env> <kind> <name>
  local f; f=$(team_ledger_file "$1" "$2")
  [[ -r $f ]] && grep -Fxq -- "$3|$4" "$f"
}
team_ledger_add() { # <project> <env> <kind> <name>
  local f; f=$(team_ledger_file "$1" "$2")
  team_ledger_has "$@" && return 0
  mkdir -p "$TEAM_PROJECTS_DIR"
  [[ -e $f ]] || install -m 600 -o root -g root /dev/null "$f"
  printf '%s|%s\n' "$3" "$4" >> "$f"
}
team_ledger_remove() { # <project> <env> <kind> <name>
  local f tmp; f=$(team_ledger_file "$1" "$2")
  [[ -r $f ]] || return 0
  tmp="$f.tmp.$$"
  grep -Fxv -- "$3|$4" "$f" > "$tmp" || true
  chmod 600 "$tmp"
  mv -f "$tmp" "$f"
}
team_ledger_list() { # <project> <env> <kind> : names of that kind
  local f; f=$(team_ledger_file "$1" "$2")
  [[ -r $f ]] || return 0
  awk -F'|' -v k="$3" '$1 == k { sub(/^[^|]*\|/, ""); print }' "$f"
}

# ---------------------------------------------------------------------------- databases
# Postgres: the postgres superuser over the local socket. MySQL/MariaDB: root over the socket
# (unix_socket / auth_socket), or the client options in /etc/team/mysql-admin.cnf if that exists.
team_pg()      { runuser -u postgres -- psql -X -q -v ON_ERROR_STOP=1 "$@"; }
team_pg_dump() { runuser -u postgres -- pg_dump "$@"; }
# MariaDB 11+ ships its clients as mariadb / mariadb-dump (the mysql names may be absent); MySQL
# keeps mysql / mysqldump. Use whichever this server has, MariaDB names first.
team_mysql_bin() { if command -v mariadb >/dev/null 2>&1; then printf 'mariadb'; else printf 'mysql'; fi; }
team_mysqldump_bin() { if command -v mariadb-dump >/dev/null 2>&1; then printf 'mariadb-dump'; else printf 'mysqldump'; fi; }
team_mysql() {
  local bin; bin=$(team_mysql_bin)
  if [[ -r $TEAM_ETC_DIR/mysql-admin.cnf ]]; then "$bin" --defaults-extra-file="$TEAM_ETC_DIR/mysql-admin.cnf" "$@"
  else "$bin" "$@"; fi
}
team_mysqldump() {
  local bin; bin=$(team_mysqldump_bin)
  if [[ -r $TEAM_ETC_DIR/mysql-admin.cnf ]]; then "$bin" --defaults-extra-file="$TEAM_ETC_DIR/mysql-admin.cnf" "$@"
  else "$bin" "$@"; fi
}
team_mysqldump_is_mariadb() { "$(team_mysqldump_bin)" --version 2>/dev/null | grep -qi mariadb; }

team_is_mysql_family() { [[ $1 == mysql || $1 == mariadb ]]; }

# team_db_ready <engine> : the server answers as admin
team_db_ready() {
  case $1 in
    postgres) command -v psql >/dev/null 2>&1 && team_pg -d postgres -Atc 'SELECT 1' >/dev/null 2>&1 ;;
    mysql|mariadb) command -v "$(team_mysql_bin)" >/dev/null 2>&1 && team_mysql -N -B -e 'SELECT 1' >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

# team_db_query <engine> <db|""> <sql> : rows on stdout, fields separated by |
team_db_query() {
  local engine=$1 db=$2 sql=$3
  case $engine in
    postgres) team_pg -At -F '|' -d "${db:-postgres}" -c "$sql" ;;
    mysql|mariadb)
      if [[ -n $db ]]; then team_mysql -N -B -e "$sql" "$db" | tr '\t' '|'
      else team_mysql -N -B -e "$sql" | tr '\t' '|'; fi ;;
  esac
}

# team_db_exec <engine> <db|""> : run SQL from stdin, stop on the first error
team_db_exec() {
  case $1 in
    postgres) team_pg -d "${2:-postgres}" ;;
    mysql|mariadb) if [[ -n $2 ]]; then team_mysql "$2"; else team_mysql; fi ;;
  esac
}

team_db_exists() { # <engine> <name>  (name already validated)
  case $1 in
    postgres) [[ $(team_db_query postgres "" "SELECT 1 FROM pg_database WHERE datname = '$2'") == 1 ]] ;;
    *) [[ $(team_db_query "$1" "" "SELECT 1 FROM information_schema.schemata WHERE schema_name = '$2'") == 1 ]] ;;
  esac
}
team_dbuser_exists() { # <engine> <name>
  case $1 in
    postgres) [[ $(team_db_query postgres "" "SELECT 1 FROM pg_roles WHERE rolname = '$2'") == 1 ]] ;;
    *) [[ -n $(team_db_query "$1" "" "SELECT 1 FROM mysql.user WHERE user = '$2' LIMIT 1") ]] ;;
  esac
}
team_db_port() { # <engine>
  case $1 in
    postgres) team_db_query postgres "" "SHOW port" ;;
    *) team_db_query "$1" "" "SELECT @@port" ;;
  esac
}
team_db_size_bytes() { # <engine> <db>
  case $1 in
    postgres) team_db_query postgres "" "SELECT pg_database_size('$2')" ;;
    *) team_db_query "$1" "" "SELECT COALESCE(SUM(data_length + index_length), 0) FROM information_schema.tables WHERE table_schema = '$2'" ;;
  esac
}
team_db_table_count() { # <engine> <db>
  case $1 in
    postgres) team_db_query postgres "$2" "SELECT count(*) FROM information_schema.tables WHERE table_type = 'BASE TABLE' AND table_schema NOT IN ('pg_catalog', 'information_schema')" ;;
    *) team_db_query "$1" "" "SELECT count(*) FROM information_schema.tables WHERE table_type = 'BASE TABLE' AND table_schema = '$2'" ;;
  esac
}

# MySQL treats _ and % in GRANT database names as wildcards; escape them so a grant covers one DB.
team_mysql_grant_db() { local d=${1//_/\\_}; printf '%s' "${d//%/\\%}"; }
TEAM_MYSQL_APP_PRIVS="SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, ALTER, INDEX, REFERENCES, CREATE TEMPORARY TABLES, LOCK TABLES, CREATE VIEW, SHOW VIEW, TRIGGER, EXECUTE, CREATE ROUTINE, ALTER ROUTINE"

# team_db_create_user <engine> <user> <password> : login user with no server-wide privileges
team_db_create_user() {
  case $1 in
    postgres)
      team_db_exec postgres "" <<SQL
CREATE ROLE "$2" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION PASSWORD '$3';
ALTER ROLE "$2" SET timezone TO 'UTC';
SQL
      ;;
    *)
      team_db_exec "$1" "" <<SQL
CREATE USER '$2'@'localhost' IDENTIFIED BY '$3';
CREATE USER '$2'@'127.0.0.1' IDENTIFIED BY '$3';
SQL
      ;;
  esac
}

# team_db_create_app <engine> <db> <user> : the app database, reachable only by its own user
team_db_create_app() {
  case $1 in
    postgres)
      team_db_exec postgres "" <<SQL
CREATE DATABASE "$2" OWNER "$3" TEMPLATE template0;
SQL
      ;;
    *)
      team_db_exec "$1" "" <<SQL
CREATE DATABASE \`$2\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
SQL
      ;;
  esac
  team_db_grant_app "$@"
}

# team_db_grant_app <engine> <db> <user> : idempotent least-privilege grants
team_db_grant_app() {
  local gdb
  case $1 in
    postgres)
      team_db_exec postgres "" <<SQL
REVOKE ALL ON DATABASE "$2" FROM PUBLIC;
GRANT CONNECT, TEMPORARY ON DATABASE "$2" TO "$3";
SQL
      ;;
    *)
      gdb=$(team_mysql_grant_db "$2")
      team_db_exec "$1" "" <<SQL
GRANT $TEAM_MYSQL_APP_PRIVS ON \`$gdb\`.* TO '$3'@'localhost', '$3'@'127.0.0.1';
SQL
      ;;
  esac
}

# team_db_dump <engine> <db> <kind> : plain SQL on stdout. Never locks tables.
#   backup    faithful (owners, grants, routines, triggers, events) for restore
#   raw       snapshot input (no owners/grants; MySQL without triggers so updates don't fire them)
#   sanitized snapshot output (no owners/grants, portable)
#   triggers  MySQL only: trigger definitions, no data
team_db_dump() {
  local engine=$1 db=$2 kind=$3
  local -a opts
  case $engine in
    postgres)
      case $kind in
        backup) team_pg_dump --format=plain "$db" ;;
        *) team_pg_dump --format=plain --no-owner --no-privileges "$db" ;;
      esac
      ;;
    mysql|mariadb)
      opts=(--single-transaction --quick --skip-lock-tables --no-tablespaces --hex-blob --skip-dump-date)
      team_mysqldump_is_mariadb || opts+=(--set-gtid-purged=OFF)
      case $kind in
        backup) opts+=(--routines --triggers --events) ;;
        raw|sanitized) opts+=(--routines --skip-triggers) ;;
        triggers) opts+=(--no-data --no-create-info --skip-routines --triggers) ;;
      esac
      team_mysqldump "${opts[@]}" "$db"
      ;;
  esac
}

# team_db_restore <engine> <db> [pg-role] < sql : restore plain SQL (Postgres: optionally as <role>,
# so the objects belong to that role)
team_db_restore() {
  case $1 in
    postgres)
      if [[ -n ${3:-} ]]; then { printf 'SET ROLE "%s";\n' "$3"; cat; } | team_pg -d "$2"
      else team_pg -d "$2"; fi
      ;;
    *) team_mysql "$2" ;;
  esac
}

# Temporary databases (snapshot, backup --verify) are recorded before creation in
# /var/lib/team/<project>/tmp-databases, so a crashed run's leftovers can be dropped later
# without ever dropping by name pattern. Callers hold the project's db lock.
team_tmpdb_registry() { printf '%s/%s/tmp-databases' "$TEAM_VAR_ROOT" "$1"; }
team_tmpdb_create() { # <engine> <project> <purpose> → prints the name
  local engine=$1 project=$2 purpose=$3 name reg
  name="team_${purpose}_${project//-/_}_$(date -u +%Y%m%d%H%M%S)"
  reg=$(team_tmpdb_registry "$project")
  team_db_exists "$engine" "$name" && team_die "$TEAM_EXIT_FAIL" "temporary database $name already exists"
  printf '%s|%s\n' "$engine" "$name" >> "$reg"
  chmod 600 "$reg"
  case $engine in
    postgres) printf 'CREATE DATABASE "%s" TEMPLATE template0;\n' "$name" | team_db_exec postgres "" >&2 ;;
    *) printf 'CREATE DATABASE `%s` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\n' "$name" | team_db_exec "$engine" "" >&2 ;;
  esac
  printf '%s' "$name"
}
team_tmpdb_drop() { # <engine> <project> <name> : only a name this registry recorded
  local engine=$1 project=$2 name=$3 reg tmp
  reg=$(team_tmpdb_registry "$project")
  [[ -n $name && -r $reg ]] && grep -Fxq -- "$engine|$name" "$reg" || return 0
  case $engine in
    postgres) printf 'DROP DATABASE IF EXISTS "%s" WITH (FORCE);\n' "$name" | team_db_exec postgres "" ;;
    *) printf 'DROP DATABASE IF EXISTS `%s`;\n' "$name" | team_db_exec "$engine" "" ;;
  esac
  tmp="$reg.tmp.$$"
  grep -Fxv -- "$engine|$name" "$reg" > "$tmp" || true
  chmod 600 "$tmp"
  mv -f "$tmp" "$reg"
}
team_tmpdb_cleanup() { # <project> : drop leftovers of crashed runs
  local reg engine name entries
  reg=$(team_tmpdb_registry "$1")
  [[ -s $reg ]] || return 0
  entries=$(cat "$reg")
  while IFS='|' read -r engine name; do
    [[ -n $name ]] || continue
    team_warn "dropping leftover temporary database $name from an earlier run"
    team_tmpdb_drop "$engine" "$1" "$name" || team_warn "could not drop $name"
  done <<< "$entries"
}

# ---------------------------------------------------------------------------- PII column patterns
# Extended regexes, matched case-insensitively against the lower-cased column name. An exact copy of
# config/pii-patterns.txt (tests/server/run.sh fails if they drift). If a bundle carries
# pii-patterns.txt, provision installs it as $TEAM_PII_FILE and that copy wins.
TEAM_PII_PATTERNS_BUILTIN='e-?mail
phone
mobile
msisdn
(^|_)cell(_|$)
(^|_)(first|last|middle|full|given|family|sur|nick|display|user|maiden|legal|contact|customer|client|person)_?name($|_)
(^|_)name$
^name_
address
street
(^|_)(city|town|province|barangay)($|_)
(^|_)(zip|postal|post)_?code($|_)
(^|_)zip($|_)
birth
(^|_)dob($|_)
(^|_)age($|_)
token
pass(word|wd|code|phrase)?($|_)
(^|_)pwd($|_)
secret
(^|_)otp($|_)
(^|_)(api|private|access|secret)_?key($|_)
(^|_)(ssn|sss|tin|nin|nric|sin|passport|national_?id|tax_?id|gov_?id|umid|philhealth|pagibig)($|_)
licen[cs]e_?(no|num|number)
(^|_)ip(_?addr(ess)?)?($|_)
(^|_)card
(^|_)cvv|(^|_)cvc
(^|_)iban($|_)
(^|_)(bank|account|acct)_?(no|num|number)($|_)
(^|_)(lat|lng|lon|latitude|longitude|geo|location)($|_)
gender
salary
income
signature'

team_pii_patterns() {
  local line
  if [[ -r $TEAM_PII_FILE ]]; then
    while IFS= read -r line || [[ -n $line ]]; do
      line=$(team_trim "${line%$'\r'}")
      [[ -z $line || $line == '#'* ]] && continue
      printf '%s\n' "${line,,}"
    done < "$TEAM_PII_FILE"
  else
    printf '%s\n' "$TEAM_PII_PATTERNS_BUILTIN"
  fi
}

# ---------------------------------------------------------------------------- deploy helpers
# team_run_migrate <release dir> <env file> <command> : run MIGRATE_CMD in the release with the
# environment loaded (parsed, never sourced) and TZ=UTC
team_run_migrate() {
  local dir=$1 envf=$2 cmd=$3
  if [[ -z $cmd || $cmd == none ]]; then team_say "[skip] no MIGRATE_CMD"; return 0; fi
  (
    cd "$dir" || exit 1
    if [[ $TEAM_CALLER_LC_ALL == __unset__ ]]; then unset LC_ALL; else export LC_ALL=$TEAM_CALLER_LC_ALL; fi
    team_env_export "$envf"
    export TZ=UTC
    bash -c "$cmd"
  )
}

# team_php_fpm_version : newest installed php-fpm version (e.g. 8.3), or nothing
team_php_fpm_version() {
  local d best=""
  for d in /etc/php/*/fpm; do
    [[ -d $d ]] || continue
    d=${d#/etc/php/}; d=${d%/fpm}
    [[ $d =~ ^[0-9]+\.[0-9]+$ ]] || continue
    if [[ -z $best ]] || [[ $(printf '%s\n%s\n' "$best" "$d" | sort -V | tail -n 1) == "$d" ]]; then best=$d; fi
  done
  printf '%s' "$best"
}

# team_service_reload <service> : systemd reload, or the init script when systemd is not running
team_service_reload() {
  local svc=$1
  if team_systemd_running; then
    if systemctl is-active -q "$svc"; then systemctl reload "$svc"
    else team_plan skip "$svc is not running: configuration installed, not reloaded"; fi
  elif [[ -x /etc/init.d/$svc ]] && service "$svc" status >/dev/null 2>&1; then
    service "$svc" reload >/dev/null
  else
    team_plan skip "$svc is not running: configuration installed, not reloaded"
  fi
}
