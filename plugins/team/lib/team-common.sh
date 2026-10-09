# shellcheck shell=bash disable=SC2034  # constants below are used by the commands that source this file
# Shared helpers for the team-* commands. Sourced, never executed.
# bash 3.2 + BSD tools (see docs/rules.md §16). Every function is safe under `set -euo pipefail`.
#
# Usage from a command in plugins/team/bin/:
#   TEAM_SELF_DIR=$(cd "$(dirname "$0")" && pwd)
#   . "$TEAM_SELF_DIR/../lib/team-common.sh"

# Byte-order matching: under locales such as en_PH.UTF-8, bash 3.2 lets [a-z] match capitals,
# which silently weakens every name check. Must stay before any pattern match.
unset LC_ALL
LC_COLLATE=C
export LC_COLLATE

TEAM_CONFIG_DIR="${TEAM_CONFIG_DIR:-$HOME/.config/team}"
TEAM_STANDARDS_REPO="${TEAM_STANDARDS_REPO:-akosiArvin081596/dev-standards}"
TEAM_TEMPLATE_REPO="${TEAM_TEMPLATE_REPO:-akosiArvin081596/project-starter}"
TEAM_PLUGIN_ID="team@dev-standards"

TEAM_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TEAM_PLUGIN_ROOT=$(cd "$TEAM_LIB_DIR/.." && pwd)
TEAM_BIN_DIR="$TEAM_PLUGIN_ROOT/bin"
TEAM_SERVER_DIR="$TEAM_PLUGIN_ROOT/server"

# Exit codes (docs/rules.md §4)
TEAM_EXIT_FAIL=1
TEAM_EXIT_USAGE=2
TEAM_EXIT_NOT_CONFIGURED=3
TEAM_EXIT_REFUSED=4
TEAM_EXIT_PREREQ=5
TEAM_EXIT_OWNER=6

team_prog() { basename "$0"; }

team_info() { printf '%s: %s\n' "$(team_prog)" "$*" >&2; }
team_warn() { printf '%s: warning: %s\n' "$(team_prog)" "$*" >&2; }

# team_die <code> <message...>
team_die() {
  local code="$1"; shift
  printf '%s: %s\n' "$(team_prog)" "$*" >&2
  exit "$code"
}

team_usage_error() { team_die "$TEAM_EXIT_USAGE" "$* (see --help)"; }

# team_require_cmd <cmd>... : exit 5 naming what is missing
team_require_cmd() {
  local c missing=""
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
  done
  [ -z "$missing" ] || team_die "$TEAM_EXIT_PREREQ" "missing required tool(s):$missing"
}

team_in_claude_code() { [ "${CLAUDECODE:-}" = "1" ]; }

team_utc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
team_utc_stamp() { date -u +%Y%m%dT%H%M%SZ; }

# team_sha256 <file> : prints the hex digest
team_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

# team_trim <string> : strips surrounding whitespace
team_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# team_conf_get <file> <key> [default]
# Parses KEY=value lines (never sources). Last assignment wins. Strips one
# pair of surrounding double or single quotes. Missing file/key → default.
team_conf_get() {
  local file="$1" key="$2" default="${3-}" line k v found=""
  if [ -r "$file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in ''|'#'*) continue ;; esac
      case "$line" in *=*) ;; *) continue ;; esac
      k=$(team_trim "${line%%=*}")
      [ "$k" = "$key" ] || continue
      v=$(team_trim "${line#*=}")
      case "$v" in
        \"*\") v="${v#\"}"; v="${v%\"}" ;;
        \'*\') v="${v#\'}"; v="${v%\'}" ;;
      esac
      found="$v"
    done < "$file"
  fi
  if [ -n "$found" ]; then printf '%s' "$found"; else printf '%s' "$default"; fi
}

# team_default <key> [default] : value from defaults.conf
team_default() { team_conf_get "$TEAM_CONFIG_DIR/defaults.conf" "$1" "${2-}"; }

# team_accounts : prints accounts.conf data lines (kind|login|ssh_host|git_name|git_email)
team_accounts() {
  local f="$TEAM_CONFIG_DIR/accounts.conf" line
  [ -r "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in account\|*|agent\|*) printf '%s\n' "$line" ;; esac
  done < "$f"
}

# team_account_field <login> <field-number 1-5> : field of that login's line
team_account_field() {
  local login="$1" n="$2" line kind l h name email
  while IFS='|' read -r kind l h name email; do
    [ "$l" = "$login" ] || continue
    line="$kind|$l|$h|$name|$email"
    printf '%s' "$line" | cut -d'|' -f"$n"
    return 0
  done <<EOF
$(team_accounts)
EOF
  return 1
}

# team_agent_login : login on the `agent|` line, or empty
team_agent_login() {
  local kind l rest
  while IFS='|' read -r kind l rest; do
    [ "$kind" = "agent" ] && [ -n "$l" ] && { printf '%s' "$l"; return 0; }
  done <<EOF
$(team_accounts)
EOF
  return 0
}

# team_repo_root [dir] : top of the current worktree (exit 5 outside git)
team_repo_root() {
  git -C "${1:-.}" rev-parse --show-toplevel 2>/dev/null \
    || team_die "$TEAM_EXIT_PREREQ" "not inside a git repository: ${1:-$PWD}"
}

# team_main_root [dir] : the main checkout of the repo (same as repo root outside a worktree)
team_main_root() {
  local common
  common=$(git -C "${1:-.}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
    || team_die "$TEAM_EXIT_PREREQ" "not inside a git repository: ${1:-$PWD}"
  case "$common" in
    */.git) printf '%s' "${common%/.git}" ;;
    *) team_repo_root "${1:-.}" ;;
  esac
}

# team_project_conf_get <key> [default] [dir] : value from <repo root>/ops/project.conf
team_project_conf_get() {
  local root
  root=$(team_repo_root "${3:-.}")
  team_conf_get "$root/ops/project.conf" "$1" "${2-}"
}

# team_origin_repo [dir] : owner/name parsed from the origin URL (ssh, scp-like or https)
team_origin_repo() {
  local url path
  url=$(git -C "${1:-.}" config --get remote.origin.url 2>/dev/null) \
    || team_die "$TEAM_EXIT_PREREQ" "no origin remote in ${1:-$PWD}"
  case "$url" in
    *://*) path="${url#*://}"; path="${path#*/}" ;;
    *:*) path="${url#*:}" ;;
    *) path="$url" ;;
  esac
  path="${path%.git}"
  path="${path%/}"
  printf '%s' "$path"
}

# team_github_account [dir] : the login the project acts as on GitHub
team_github_account() {
  local acct=""
  if git -C "${1:-.}" rev-parse --show-toplevel >/dev/null 2>&1; then
    acct=$(team_project_conf_get GITHUB_ACCOUNT "" "${1:-.}")
  fi
  [ -n "$acct" ] || acct=$(team_default DEFAULT_GITHUB_ACCOUNT "")
  [ -n "$acct" ] || team_die "$TEAM_EXIT_NOT_CONFIGURED" "no GitHub account: set GITHUB_ACCOUNT in ops/project.conf or DEFAULT_GITHUB_ACCOUNT in $TEAM_CONFIG_DIR/defaults.conf"
  printf '%s' "$acct"
}

# team_owner_login [dir] : the human owner's login (owner-approved, environment reviewer)
team_owner_login() {
  local owner
  owner=$(team_default OWNER_LOGIN "")
  [ -n "$owner" ] || owner=$(team_github_account "${1:-.}")
  printf '%s' "$owner"
}

# team_gh_as <login> <gh args...> : run one gh command as <login>. Never prints the token,
# never switches the global account.
team_gh_as() {
  local login="$1" token
  shift
  team_require_cmd gh
  token=$(command gh auth token -u "$login" 2>/dev/null) || token=""
  [ -n "$token" ] || team_die "$TEAM_EXIT_PREREQ" "gh is not logged in as $login (run: gh auth login, then retry)"
  GH_TOKEN="$token" command gh "$@"
}

# team_gh <gh args...> : gh as the project's account (or the agent account when configured)
team_gh() {
  local login agent
  login=$(team_github_account .)
  agent=$(team_agent_login)
  [ -n "$agent" ] && login="$agent"
  team_gh_as "$login" "$@"
}

# team_lock_acquire <name> [wait-seconds] : mkdir lock under $TEAM_CONFIG_DIR/locks (stale after 120 s)
team_lock_acquire() {
  local name="$1" wait="${2:-60}" dir now mtime waited=0
  dir="$TEAM_CONFIG_DIR/locks/$name.lock"
  mkdir -p "$TEAM_CONFIG_DIR/locks"
  while ! mkdir "$dir" 2>/dev/null; do
    now=$(date +%s)
    mtime=$(stat -f %m "$dir" 2>/dev/null || stat -c %Y "$dir" 2>/dev/null || echo "$now")
    if [ $((now - mtime)) -gt 120 ]; then
      team_warn "removing stale lock $dir"
      rm -rf "${dir:?}"
      continue
    fi
    [ "$waited" -lt "$wait" ] || team_die "$TEAM_EXIT_FAIL" "timed out waiting for lock $name"
    sleep 1
    waited=$((waited + 1))
  done
  printf '%s\n' "$$" > "$dir/pid"
}

team_lock_release() {
  local dir="$TEAM_CONFIG_DIR/locks/$1.lock"
  rm -rf "${dir:?}"
}

# team_registry_add <file> <line> : append a line to a registry file (creates it, mode 600)
team_registry_add() {
  local file="$1" line="$2"
  mkdir -p "$(dirname "$file")"
  [ -e "$file" ] || { : > "$file"; chmod 600 "$file"; }
  printf '%s\n' "$line" >> "$file"
}

# team_registry_remove <file> <field-number> <value> : drop lines whose field equals value
team_registry_remove() {
  local file="$1" n="$2" value="$3" tmp
  [ -r "$file" ] || return 0
  tmp="$file.tmp.$$"
  awk -F'|' -v n="$n" -v v="$value" '$n != v' "$file" > "$tmp"
  mv "$tmp" "$file"
  chmod 600 "$file"
}

# team_redact <text> : mask tokens and secret-looking assignments for logs and plans
team_redact() {
  printf '%s' "$1" | sed -E \
    -e 's/gh[opusr]_[A-Za-z0-9_]+/gh*_[REDACTED]/g' \
    -e 's/github_pat_[A-Za-z0-9_]+/github_pat_[REDACTED]/g' \
    -e 's/(Bearer|token) [A-Za-z0-9._~+\/=-]+/\1 [REDACTED]/g' \
    -e 's/([A-Za-z_]*(TOKEN|SECRET|PASSWORD|KEY)[A-Za-z_]*=)[^[:space:]]+/\1[REDACTED]/g'
}

# Plan/apply: commands that change GitHub or a server call team_parse_apply "$@" first,
# then wrap each change in team_step.
TEAM_APPLY=0
team_parse_apply() {
  local a
  for a in "$@"; do [ "$a" = "--apply" ] && TEAM_APPLY=1; done
  return 0
}

# team_step <description> <command...> : prints the plan line, or runs the command with --apply
team_step() {
  local desc="$1"; shift
  if [ "$TEAM_APPLY" = "1" ]; then
    printf '[apply] %s\n' "$desc"
    "$@"
  else
    printf '[plan]  %s\n' "$desc"
  fi
}

# team_plan_footer : reminder printed at the end of a plan
team_plan_footer() {
  [ "$TEAM_APPLY" = "1" ] || printf '\nNothing changed. Re-run with --apply to make these changes.\n'
}
