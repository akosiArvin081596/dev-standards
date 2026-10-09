# shellcheck shell=bash disable=SC2034  # constants below are used by the commands that source this file
# Shared helpers for the local and VPS team-* commands (worktrees, ports, local
# databases, the local app, snapshots, VPS wrappers). Sourced after
# team-common.sh, never executed. bash 3.2 + BSD tools (docs/rules.md §16).
#
#   TEAM_SELF_DIR=$(cd "$(dirname "$0")" && pwd)
#   . "$TEAM_SELF_DIR/../lib/team-common.sh"
#   . "$TEAM_SELF_DIR/../lib/team-local.sh"

TEAM_WORKTREES_SUBDIR=".claude/worktrees"
TEAM_REMOTE_LIB="/usr/local/lib/team"

# ---------------------------------------------------------------- words, paths

# team_is_safe_word <s> : true for [A-Za-z0-9._-]+ that does not start with '-'
team_is_safe_word() {
  case "$1" in
    ''|-*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# team_canon_dir <dir> : physical absolute path (macOS: /var → /private/var)
team_canon_dir() { (cd "$1" 2>/dev/null && pwd -P); }

# team_slugify <text> : lowercase, non-alnum → '-', trimmed, at most 40 chars
team_slugify() {
  local s
  s=$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]' \
    | LC_ALL=C sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-40 \
    | LC_ALL=C sed -E 's/-+$//')
  printf '%s' "$s"
}

# team_project_name <repo dir> : PROJECT_NAME from ops/project.conf, else the
# main checkout's folder name made safe. Always [a-z][a-z0-9-]*.
team_project_name() {
  local dir="$1" name main
  name=$(team_conf_get "$dir/ops/project.conf" PROJECT_NAME "")
  if [ -z "$name" ]; then
    main=$(team_main_root "$dir")
    name=$(team_slugify "$(basename "$main")")
  fi
  case "$name" in
    [a-z]*) ;;
    *) name="p-$name" ;;
  esac
  case "$name" in
    *[!a-z0-9-]*|p-) team_die "$TEAM_EXIT_NOT_CONFIGURED" "PROJECT_NAME in ops/project.conf must match [a-z][a-z0-9-]{1,20}" ;;
  esac
  printf '%s' "$name"
}

# team_db_name <project> <issue> : <project_>_<issue>
team_db_name() { printf '%s_%s' "$(printf '%s' "$1" | tr '-' '_')" "$2"; }

# team_urlencode <s> : percent-encodes everything but unreserved characters
team_urlencode() {
  local s="$1" out="" c i
  local LC_ALL=C
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      [A-Za-z0-9._~-]) out="$out$c" ;;
      *) out="$out$(printf '%%%02X' "'$c")" ;;
    esac
  done
  printf '%s' "$out"
}

# ---------------------------------------------------------------- env files

# team_env_get <file> <key> [default]
team_env_get() { team_conf_get "$1" "$2" "${3-}"; }

# team_env_quote <value> : raw when plain; else single-quoted (literal in dotenv parsers,
# and read back unchanged by team_conf_get); double quotes when the value holds a ' but
# nothing a parser would expand. No escaping, so values round-trip.
team_env_quote() {
  case "$1" in
    *[!A-Za-z0-9_./:@%+=,~-]*)
      case "$1" in
        *\'*)
          case "$1" in
            *\"*|*\\*|*\$*) printf '%s' "$1" ;;
            *) printf '"%s"' "$1" ;;
          esac
          ;;
        *) printf "'%s'" "$1" ;;
      esac
      ;;
    *) printf '%s' "$1" ;;
  esac
}

# team_env_set <file> <key> <value> : replaces the first KEY= line (dropping later
# duplicates) or appends one. Keeps the file's mode. Values never pass through argv.
team_env_set() {
  local file="$1" key="$2" value tmp
  value=$(team_env_quote "$3")
  tmp="$file.tmp.$$"
  TEAM_ENV_KEY="$key" TEAM_ENV_VALUE="$value" awk '
    BEGIN { k = ENVIRON["TEAM_ENV_KEY"]; v = ENVIRON["TEAM_ENV_VALUE"]; done = 0 }
    {
      line = $0
      sub(/^[ \t]*export[ \t]+/, "", line)
      sub(/^[ \t]+/, "", line)
      if (index(line, k) == 1 && substr(line, length(k) + 1) ~ /^[ \t]*=/) {
        if (!done) { print k "=" v; done = 1 }
        next
      }
      print
    }
    END { if (!done) print k "=" v }' "$file" > "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

# team_env_has_key <file> <key>
team_env_has_key() {
  [ -r "$1" ] || return 1
  grep -Eq "^[[:space:]]*(export[[:space:]]+)?$2[[:space:]]*=" "$1"
}

# ---------------------------------------------------------------- ports, processes

# team_port_listening <port> : someone listens on it (lsof, plus a connect probe for
# listeners lsof cannot see without root)
team_port_listening() {
  lsof -nP -iTCP:"$1" -sTCP:LISTEN -t >/dev/null 2>&1 && return 0
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && return 0
  return 1
}

# team_port_listener_pids <port> : distinct PIDs listening on it
team_port_listener_pids() { lsof -nP -iTCP:"$1" -sTCP:LISTEN -t 2>/dev/null | sort -u; }

# team_warn_shared_port <port> <what> : warns when two different processes listen there
team_warn_shared_port() {
  local n
  n=$(team_port_listener_pids "$1" | grep -c . || true)
  if [ "${n:-0}" -gt 1 ]; then
    team_warn "$n different processes listen on port $1 ($2); database commands always pass an explicit host and port, so check which server you mean"
  fi
}

# team_pid_alive <pid>
team_pid_alive() { kill -0 "$1" 2>/dev/null; }

# team_pid_cwd <pid> : the process's working directory (lsof), or nothing
team_pid_cwd() { lsof -a -p "$1" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1; }

# team_pgid_members <pgid> : PIDs in that process group
team_pgid_members() {
  ps -A -o pid=,pgid= 2>/dev/null | awk -v g="$1" '$2 == g { print $1 }'
}

# team_path_within <path> <dir> : path is dir or below it
team_path_within() {
  case "$1" in
    "$2"|"$2"/*) return 0 ;;
  esac
  return 1
}

# ---------------------------------------------------------------- make

# team_make_status <log> <target> <make rc> : 0, 3 (not configured) or 1.
# Same rule as scripts/ci/make-target.sh: make turns a recipe's exit 3 into its own exit 2,
# so "not configured" needs make's exit 2 AND a "*** [...] Error 3" line AND the text
# "not configured". Anything else (a missing target or Makefile, a tool that happens to
# exit 3) is a failure.
team_make_status() {
  local log="$1" rc="$3"
  [ "$rc" -eq 0 ] && return 0
  if [ "$rc" -eq 2 ] && grep -Eq '\*\*\* \[[^]]*\] Error 3$' "$log" 2>/dev/null \
     && grep -q 'not configured' "$log" 2>/dev/null; then
    return 3
  fi
  return 1
}

# team_has_makefile <dir>
team_has_makefile() { [ -f "$1/Makefile" ] || [ -f "$1/makefile" ] || [ -f "$1/GNUmakefile" ]; }

# team_run_make <dir> <target> : runs make there (output → stderr); returns 0, 3 or 1
team_run_make() {
  local dir="$1" target="$2" log rc st
  log=$(mktemp "${TMPDIR:-/tmp}/team-make.XXXXXX")
  set +e
  (cd "$dir" && make "$target") 2>&1 | tee "$log" >&2
  rc=${PIPESTATUS[0]}
  team_make_status "$log" "$target" "$rc"
  st=$?
  set -e
  rm -f "$log"
  return "$st"
}

# team_run_cmd <dir> <command string> <what> : runs a project command (MIGRATE_CMD,
# SEED_CMD) with bash. Returns 3 only for "not configured": a make target per
# team_make_status, or any other command that exits 3 AND prints "not configured".
# Output → stderr.
team_run_cmd() {
  local dir="$1" cmd="$2" log rc st
  log=$(mktemp "${TMPDIR:-/tmp}/team-cmd.XXXXXX")
  set +e
  (cd "$dir" && bash -c "$cmd") 2>&1 | tee "$log" >&2
  rc=${PIPESTATUS[0]}
  st=0
  if [ "$rc" -ne 0 ]; then
    st=1
    case "$cmd" in
      make\ *) team_make_status "$log" "" "$rc"; st=$? ;;
      *) [ "$rc" -eq 3 ] && grep -q 'not configured' "$log" && st=3 ;;
    esac
  fi
  set -e
  rm -f "$log"
  return "$st"
}

# ---------------------------------------------------------------- registries

team_ports_registry() { printf '%s/ports.registry' "$TEAM_CONFIG_DIR"; }
team_db_registry() { printf '%s/databases.registry' "$TEAM_CONFIG_DIR"; }

# team_port_of_worktree <wt> : port recorded for that worktree, or nothing
team_port_of_worktree() {
  local f
  f=$(team_ports_registry)
  [ -r "$f" ] || return 0
  awk -F'|' -v w="$1" '$2 == w { print $1; exit }' "$f"
}

# team_ports_prune : drops registry lines whose worktree no longer exists (hold the ports lock)
team_ports_prune() {
  local f tmp port wt rest
  f=$(team_ports_registry)
  [ -r "$f" ] || return 0
  tmp="$f.tmp.$$"
  : > "$tmp"
  while IFS='|' read -r port wt rest || [ -n "$port" ]; do
    [ -n "$port" ] || continue
    if [ -d "$wt" ]; then printf '%s|%s|%s\n' "$port" "$wt" "$rest" >> "$tmp"; fi
  done < "$f"
  mv "$tmp" "$f"
  chmod 600 "$f"
}

# team_db_registered <engine> <port> <name> <wt> : the exact DB is recorded for that worktree
team_db_registered() {
  local f
  f=$(team_db_registry)
  [ -r "$f" ] || return 1
  awk -F'|' -v e="$1" -v p="$2" -v n="$3" -v w="$4" \
    '$1 == e && $3 == p && $4 == n && $6 == w { found = 1 } END { exit found ? 0 : 1 }' "$f"
}

# team_db_unregister <engine> <port> <name> <wt>
team_db_unregister() {
  local f tmp
  f=$(team_db_registry)
  [ -r "$f" ] || return 0
  tmp="$f.tmp.$$"
  awk -F'|' -v e="$1" -v p="$2" -v n="$3" -v w="$4" \
    '!($1 == e && $3 == p && $4 == n && $6 == w)' "$f" > "$tmp"
  mv "$tmp" "$f"
  chmod 600 "$f"
}

# ---------------------------------------------------------------- postgres

# team_pg <host> <port> <user> <password> <psql args...> : psql with an explicit host and
# port. The password travels in PGPASSWORD only (never argv); an empty one unsets it.
team_pg() {
  local h="$1" p="$2" u="$3" pw="$4"
  shift 4
  [ -n "$u" ] && set -- -U "$u" "$@"
  if [ -n "$pw" ]; then
    PGPASSWORD="$pw" PGCONNECT_TIMEOUT=5 psql -X -q -v ON_ERROR_STOP=1 -h "$h" -p "$p" "$@"
  else
    env -u PGPASSWORD PGCONNECT_TIMEOUT=5 psql -X -q -v ON_ERROR_STOP=1 -h "$h" -p "$p" "$@"
  fi
}

# team_pg_query <host> <port> <user> <password> <sql> : one unaligned result (maintenance DB)
team_pg_query() { team_pg "$1" "$2" "$3" "$4" -d postgres -Atc "$5" </dev/null; }

# team_pg_ping <host> <port> <user> <password> : exit 1 with a clear message when unreachable
team_pg_ping() {
  team_pg_query "$1" "$2" "$3" "$4" "SELECT 1" >/dev/null 2>&1 \
    || team_die "$TEAM_EXIT_FAIL" "cannot connect to Postgres on $1:$2 as ${3:-the default user} (is it running? are DB_USER/DB_PASSWORD or PGUSER/PGPASSWORD right?)"
}

team_pg_exists() {
  [ "$(team_pg_query "$1" "$2" "$3" "$4" "SELECT 1 FROM pg_database WHERE datname = '$5'")" = "1" ]
}

team_pg_comment() {
  team_pg_query "$1" "$2" "$3" "$4" "SELECT coalesce(shobj_description(oid, 'pg_database'), '') FROM pg_database WHERE datname = '$5'"
}

# team_sql_literal <s> : single-quoted SQL literal
team_sql_literal() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"; }

# team_pg_create <host> <port> <user> <password> <name> <comment>
team_pg_create() {
  team_pg_query "$1" "$2" "$3" "$4" "CREATE DATABASE \"$5\"" >/dev/null
  team_pg_query "$1" "$2" "$3" "$4" "COMMENT ON DATABASE \"$5\" IS $(team_sql_literal "$6")" >/dev/null
}

# team_pg_drop <host> <port> <user> <password> <name>
team_pg_drop() {
  local v force=""
  v=$(team_pg_query "$1" "$2" "$3" "$4" "SHOW server_version_num" 2>/dev/null || echo 0)
  [ "${v:-0}" -ge 130000 ] 2>/dev/null && force=" WITH (FORCE)"
  team_pg_query "$1" "$2" "$3" "$4" "DROP DATABASE IF EXISTS \"$5\"$force" >/dev/null
}

# team_pg_table_count <host> <port> <user> <password> <db> : user tables in that DB
team_pg_table_count() {
  team_pg "$1" "$2" "$3" "$4" -d "$5" -Atc \
    "SELECT count(*) FROM pg_catalog.pg_tables WHERE schemaname NOT IN ('pg_catalog', 'information_schema')" </dev/null
}

# team_pg_comment_for <project> <wt> : the comment that marks a pack-created database
team_pg_comment_for() { printf 'team-pack:%s:%s' "$1" "$2"; }

# ---------------------------------------------------------------- mysql / mariadb (project container)

team_mysql_container() { printf 'team-%s-db' "$1"; }

# team_mysql_exec <container> <password> <mysql args...> : client inside the container, over
# TCP (so it never talks to the image's init-time server). Password via MYSQL_PWD only.
team_mysql_exec() {
  local c="$1" pw="$2"
  shift 2
  MYSQL_PWD="$pw" docker exec -i -e MYSQL_PWD "$c" sh -c \
    'if command -v mariadb >/dev/null 2>&1; then exec mariadb "$@"; else exec mysql "$@"; fi' \
    sh --protocol=TCP -h 127.0.0.1 -P 3306 -uroot "$@"
}

# team_mysql_query <container> <password> <sql> : batch output, no column names
team_mysql_query() { team_mysql_exec "$1" "$2" -N -B -e "$3" </dev/null; }

# team_mysql_password <project> : the project container's root password, kept in
# $TEAM_CONFIG_DIR/projects/<project>.conf (LOCAL_DB_PASSWORD, mode 600); created once.
team_mysql_password() {
  local project="$1" f pw c
  f="$TEAM_CONFIG_DIR/projects/$project.conf"
  pw=$(team_conf_get "$f" LOCAL_DB_PASSWORD "")
  if [ -z "$pw" ]; then
    c=$(team_mysql_container "$project")
    pw=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$c" 2>/dev/null \
      | sed -n 's/^MYSQL_ROOT_PASSWORD=//p' | head -n 1 || true)
    [ -n "$pw" ] || pw=$(openssl rand -hex 16)
    mkdir -p "$TEAM_CONFIG_DIR/projects"
    [ -e "$f" ] || { : > "$f"; chmod 600 "$f"; }
    printf 'LOCAL_DB_PASSWORD=%s\n' "$pw" >> "$f"
    chmod 600 "$f"
  fi
  printf '%s' "$pw"
}

# team_mysql_ensure <project> <image> <host port> <password> : the project container runs
# and accepts connections. Refuses a same-named container the pack did not create.
team_mysql_ensure() {
  local project="$1" image="$2" port="$3" pw="$4" c state label i
  c=$(team_mysql_container "$project")
  team_require_cmd docker
  state=$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null || echo missing)
  case "$state" in
    true|false)
      label=$(docker inspect -f '{{index .Config.Labels "team-pack"}}' "$c" 2>/dev/null || true)
      [ "$label" = "$project" ] || team_die "$TEAM_EXIT_REFUSED" "container $c exists but was not created by the pack; not touching it"
      [ "$state" = true ] || docker start "$c" >/dev/null || team_die "$TEAM_EXIT_FAIL" "could not start container $c"
      ;;
    *)
      team_port_listening "$port" && team_die "$TEAM_EXIT_REFUSED" "LOCAL_DB_PORT $port is already in use; choose another in ops/project.conf"
      team_info "starting project database container $c ($image on 127.0.0.1:$port)"
      MYSQL_ROOT_PASSWORD="$pw" MARIADB_ROOT_PASSWORD="$pw" docker run -d --name "$c" \
        --label "team-pack=$project" -p "127.0.0.1:$port:3306" -v "$c-data:/var/lib/mysql" \
        -e MYSQL_ROOT_PASSWORD -e MARIADB_ROOT_PASSWORD "$image" >/dev/null \
        || team_die "$TEAM_EXIT_FAIL" "could not start container $c from $image"
      ;;
  esac
  for ((i = 0; i < 120; i++)); do
    if team_mysql_query "$c" "$pw" "SELECT 1" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  team_die "$TEAM_EXIT_FAIL" "database container $c did not become ready in 120 s (docker logs $c)"
}

team_mysql_exists() {
  [ "$(team_mysql_query "$1" "$2" "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = '$3'")" = "$3" ]
}

# ---------------------------------------------------------------- app pidfile

team_app_pidfile() { printf '%s/.team/app.pid' "$1"; }

# team_app_running <root> : prints "pid pgid" when the recorded app is alive and its
# process (or a member of its group) still works inside <root>; else returns 1.
team_app_running() {
  local root="$1" f pid pgid cwd rest m mcwd
  f=$(team_app_pidfile "$root")
  [ -r "$f" ] || return 1
  IFS='|' read -r pid pgid cwd rest < "$f" || true
  case "$pid$pgid" in ''|*[!0-9]*) return 1 ;; esac
  for m in $(team_pgid_members "$pgid"); do
    mcwd=$(team_pid_cwd "$m")
    [ -n "$mcwd" ] || continue
    if team_path_within "$mcwd" "$cwd"; then
      printf '%s %s' "$pid" "$pgid"
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------- VPS

# team_vps_alias : VPS_ALIAS from defaults.conf, refusing an IP, hostname, domain or a
# forbidden alias. Every VPS command connects through this alias only.
team_vps_alias() {
  local f="$TEAM_CONFIG_DIR/defaults.conf" alias a
  [ -r "$f" ] || team_die "$TEAM_EXIT_PREREQ" "missing $f (the pack's local config)"
  alias=$(team_default VPS_ALIAS "")
  [ -n "$alias" ] || team_die "$TEAM_EXIT_NOT_CONFIGURED" "VPS_ALIAS is not set in $f"
  team_is_safe_word "$alias" || team_die "$TEAM_EXIT_NOT_CONFIGURED" "VPS_ALIAS in $f has unexpected characters"
  for a in "$(team_default VPS_IP "")" "$(team_default VPS_HOSTNAME "")" "$(team_default DOMAIN "")"; do
    [ -n "$a" ] && [ "$alias" = "$a" ] && team_die "$TEAM_EXIT_REFUSED" "VPS_ALIAS must be an ssh alias, not the server's IP or name"
  done
  for a in $(team_default VPS_FORBIDDEN_ALIASES ""); do
    [ "$alias" = "$a" ] && team_die "$TEAM_EXIT_REFUSED" "VPS_ALIAS is listed in VPS_FORBIDDEN_ALIASES"
  done
  printf '%s' "$alias"
}

# team_vps_ssh_port <alias> : port from `ssh -G` (no connection), default 22
team_vps_ssh_port() {
  local p
  p=$(ssh -G "$1" 2>/dev/null | awk '$1 == "port" { print $2; exit }' || true)
  case "$p" in ''|*[!0-9]*) p=22 ;; esac
  printf '%s' "$p"
}

# team_redact_stream : filter for remote output. Masks token-like strings and any literal
# value passed in TEAM_REDACT_1..TEAM_REDACT_3 (read from the environment, never argv).
team_redact_stream() {
  awk '
    BEGIN { n = 0; for (i = 1; i <= 3; i++) { v = ENVIRON["TEAM_REDACT_" i]; if (length(v) >= 6) s[++n] = v } }
    {
      line = $0
      for (i = 1; i <= n; i++) {
        while ((p = index(line, s[i])) > 0) line = substr(line, 1, p - 1) "[REDACTED]" substr(line, p + length(s[i]))
      }
      gsub(/gh[opusr]_[A-Za-z0-9_]+/, "gh*_[REDACTED]", line)
      gsub(/github_pat_[A-Za-z0-9_]+/, "github_pat_[REDACTED]", line)
      if (line ~ /-----BEGIN [A-Z ]*PRIVATE KEY-----/) { line = "[REDACTED private key]"; inkey = 1 }
      else if (inkey) { if (line ~ /-----END [A-Z ]*PRIVATE KEY-----/) inkey = 0; next }
      print line
      fflush()
    }'
}

# team_require_project_conf <root> : ops/project.conf must exist (exit 3 otherwise)
team_require_project_conf() {
  [ -r "$1/ops/project.conf" ] || team_die "$TEAM_EXIT_NOT_CONFIGURED" "not configured: $1/ops/project.conf is missing"
}

# team_tar_create <dir> <out|-> <paths...> : portable tar.gz without macOS metadata.
# COPYFILE_DISABLE=1 stops macOS tar writing ._ AppleDouble files (GNU tar ignores it);
# bsdtar alone also gets --no-xattrs --no-mac-metadata (GNU tar rejects the latter), so
# Linux never sees LIBARCHIVE.xattr headers.
TEAM_TAR_FLAGS=""
team_tar_create() {
  local dir="$1" out="$2"
  shift 2
  if [ -z "$TEAM_TAR_FLAGS" ]; then
    case "$(tar --version 2>/dev/null | head -n 1)" in
      *bsdtar*) TEAM_TAR_FLAGS="--no-xattrs --no-mac-metadata" ;;
      *) TEAM_TAR_FLAGS="none" ;;
    esac
  fi
  if [ "$TEAM_TAR_FLAGS" = none ]; then
    COPYFILE_DISABLE=1 tar -czf "$out" -C "$dir" "$@"
  else
    COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata -czf "$out" -C "$dir" "$@"
  fi
}
