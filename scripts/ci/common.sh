# shellcheck shell=bash disable=SC2034  # exit-code constants are used by the scripts that source this file
# Shared helpers for scripts/ci/*.sh. Sourced, never executed.
# bash 3.2 + BSD tools (docs/rules.md §16), so every script also runs on the Mac.
#
# Usage from a script in scripts/ci/:
#   CI_SELF_DIR=$(cd "$(dirname "$0")" && pwd)
#   . "$CI_SELF_DIR/common.sh"

# Byte collation: under a UTF-8 locale (e.g. en_PH.UTF-8) bash 3.2 makes [a-z]
# match capitals in case patterns and globs. Every scripts/ci script sources
# this file before it matches anything.
export LC_ALL=C

CI_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TEAM_STANDARDS_DIR="${TEAM_STANDARDS_DIR:-$(cd "$CI_LIB_DIR/../.." && pwd)}"
CI_CONFIG_DIR="${CI_CONFIG_DIR:-$TEAM_STANDARDS_DIR/config}"

# Exit codes (docs/rules.md §4)
CI_EXIT_FAIL=1
CI_EXIT_USAGE=2
CI_EXIT_NOT_CONFIGURED=3
CI_EXIT_REFUSED=4
CI_EXIT_PREREQ=5

ci_prog() { basename "$0"; }

# Workflow-command escaping: one line, no injection of further commands.
ci_escape() {
  local s="$1"
  s="${s//'%'/%25}"
  s="${s//$'\r'/%0D}"
  s="${s//$'\n'/%0A}"
  printf '%s' "$s"
}

ci_in_actions() { [ "${GITHUB_ACTIONS:-}" = "true" ]; }

ci_notice() {
  if ci_in_actions; then printf '::notice::%s\n' "$(ci_escape "$(ci_prog): $*")"
  else printf '%s: notice: %s\n' "$(ci_prog)" "$*" >&2; fi
}
ci_warning() {
  if ci_in_actions; then printf '::warning::%s\n' "$(ci_escape "$(ci_prog): $*")"
  else printf '%s: warning: %s\n' "$(ci_prog)" "$*" >&2; fi
}
ci_error() {
  if ci_in_actions; then printf '::error::%s\n' "$(ci_escape "$(ci_prog): $*")"
  else printf '%s: error: %s\n' "$(ci_prog)" "$*" >&2; fi
}
ci_info() { printf '%s: %s\n' "$(ci_prog)" "$*"; }

# ci_die <code> <message...>
ci_die() {
  local code="$1"; shift
  ci_error "$*"
  exit "$code"
}
ci_usage_error() { ci_die "$CI_EXIT_USAGE" "$* (see --help)"; }

# ci_require_cmd <cmd>... : exit 5 naming what is missing
ci_require_cmd() {
  local c missing=""
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
  done
  [ -z "$missing" ] || ci_die "$CI_EXIT_PREREQ" "missing required tool(s):$missing"
}

# ci_output <key> <value> : step output (GITHUB_OUTPUT) when running in Actions
ci_output() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"; fi
  return 0
}

# ci_summary <line> : appended to the job summary when running in Actions
ci_summary() {
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then printf '%s\n' "$1" >> "$GITHUB_STEP_SUMMARY"; fi
  return 0
}

# ci_trim <string>
ci_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# ci_conf_get <file> <key> [default]
# Same parser as team_conf_get in plugins/team/lib/team-common.sh: KEY=value lines,
# never sourced, last assignment wins, one pair of surrounding quotes stripped,
# missing file or key → default.
ci_conf_get() {
  local file="$1" key="$2" default="${3-}" line k v found=""
  if [ -r "$file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in ''|'#'*) continue ;; esac
      case "$line" in *=*) ;; *) continue ;; esac
      k=$(ci_trim "${line%%=*}")
      [ "$k" = "$key" ] || continue
      v=$(ci_trim "${line#*=}")
      case "$v" in
        \"*\") v="${v#\"}"; v="${v%\"}" ;;
        \'*\') v="${v#\'}"; v="${v%\'}" ;;
      esac
      found="$v"
    done < "$file"
  fi
  if [ -n "$found" ]; then printf '%s' "$found"; else printf '%s' "$default"; fi
}

# ci_tool_version <KEY> : value from config/tool-versions.env (an env var of the same name wins)
ci_tool_version() {
  local key="$1" v
  eval "v=\${$key:-}"
  [ -n "$v" ] || v=$(ci_conf_get "$CI_CONFIG_DIR/tool-versions.env" "$key" "")
  printf '%s' "$v"
}

# ci_list <file> : non-empty, non-comment lines, trimmed
ci_list() {
  local line
  [ -r "$1" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line=$(ci_trim "$line")
    case "$line" in ''|'#'*) continue ;; esac
    printf '%s\n' "$line"
  done < "$1"
}

# ci_patterns_file <src> <dest> : copy the patterns of a config list (comments dropped)
ci_patterns_file() {
  ci_list "$1" > "$2"
}

# ci_glob_to_regex <glob> : anchored ERE for a repo-relative path.
#   **/ → zero or more folders · ** → anything · * → anything but "/" · ? → one char
ci_glob_to_regex() {
  printf '%s\n' "$1" | awk '{
    s = $0; out = "^"; i = 1; n = length(s)
    while (i <= n) {
      c = substr(s, i, 1)
      if (c == "*") {
        if (substr(s, i + 1, 1) == "*") {
          if (substr(s, i + 2, 1) == "/") { out = out "(.*/)?"; i += 3; continue }
          out = out ".*"; i += 2; continue
        }
        out = out "[^/]*"; i++; continue
      }
      if (c == "?") { out = out "[^/]"; i++; continue }
      if (index(".+()|^$[]{}\\", c) > 0) { out = out "\\" c; i++; continue }
      out = out c; i++
    }
    print out "$"
  }'
}

# ci_globs_regex_file <dest> <glob>... : one ERE per glob (empty file when no globs)
ci_globs_regex_file() {
  local dest="$1" g
  shift
  : > "$dest"
  for g in "$@"; do
    [ -n "$g" ] || continue
    ci_glob_to_regex "$g" >> "$dest"
  done
}

# ci_filter_paths <regex-file> : stdin paths → the ones matching any regex
ci_filter_paths() {
  if [ -s "$1" ]; then grep -E -f "$1" || true; else cat >/dev/null; fi
}

# ci_path_matches <path> <glob>... : 0 when the path matches any glob
ci_path_matches() {
  local p="$1" g re
  shift
  for g in "$@"; do
    [ -n "$g" ] || continue
    re=$(ci_glob_to_regex "$g")
    if printf '%s\n' "$p" | grep -Eq -- "$re"; then return 0; fi
  done
  return 1
}

# ci_sha256 <file> : hex digest (sha256sum on Linux, shasum on the Mac)
ci_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# ci_mktemp_dir : a private temp dir under RUNNER_TEMP or TMPDIR
ci_mktemp_dir() {
  mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/team-ci.XXXXXX"
}

# ci_is_sha <value> [min] [max] : hex commit id of the given length range (default 7–40)
ci_is_sha() {
  local v="$1" min="${2:-7}" max="${3:-40}" n
  case "$v" in ''|*[!0-9a-f]*) return 1 ;; esac
  n=${#v}
  [ "$n" -ge "$min" ] && [ "$n" -le "$max" ]
}

# ci_tz : the project timezone for times people read (PROJECT_TIMEZONE, else UTC)
ci_tz() {
  local tz="${PROJECT_TIMEZONE:-}"
  case "$tz" in ''|*..*|/*) tz="UTC" ;; esac
  if [ "$tz" != "UTC" ] && [ ! -e "/usr/share/zoneinfo/$tz" ]; then tz="UTC"; fi
  printf '%s' "$tz"
}

# ci_human_time : "2026-10-09 15:00 Asia/Manila (07:00 UTC)" — times people read name the timezone
ci_human_time() {
  local tz local_t utc_t
  tz=$(ci_tz)
  utc_t=$(date -u '+%Y-%m-%d %H:%M')
  if [ "$tz" = "UTC" ]; then
    printf '%s UTC' "$utc_t"
  else
    local_t=$(TZ="$tz" date '+%Y-%m-%d %H:%M')
    printf '%s %s (%s UTC)' "$local_t" "$tz" "$(date -u '+%H:%M')"
  fi
}

# ci_run_url : link to the current Actions run (empty outside Actions)
ci_run_url() {
  if [ -n "${GITHUB_RUN_ID:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
    printf '%s/%s/actions/runs/%s' "${GITHUB_SERVER_URL:-https://github.com}" "$GITHUB_REPOSITORY" "$GITHUB_RUN_ID"
  fi
}

# ci_gh <args...> : gh with the job token (GH_TOKEN or GITHUB_TOKEN); never prints it
ci_gh() {
  if [ -z "${GH_TOKEN:-}" ] && [ -n "${GITHUB_TOKEN:-}" ]; then
    GH_TOKEN="$GITHUB_TOKEN" command gh "$@"
  else
    command gh "$@"
  fi
}

# ci_require_repo : GITHUB_REPOSITORY must look like owner/name
ci_require_repo() {
  case "${GITHUB_REPOSITORY:-}" in
    */*) ;;
    *) ci_die "$CI_EXIT_PREREQ" "GITHUB_REPOSITORY is not set (owner/name)" ;;
  esac
}

# ci_add_label <issue-or-pr-number> <label> : adds a label; a read-only token degrades to a notice
ci_add_label() {
  local n="$1" label="$2"
  if ci_gh api -X POST "repos/$GITHUB_REPOSITORY/issues/$n/labels" -f "labels[]=$label" >/dev/null 2>&1; then
    ci_info "added label $label to #$n"
    return 0
  fi
  ci_notice "could not add label '$label' to #$n (read-only token, e.g. a fork PR); add it by hand if needed"
  return 1
}

# ci_remove_label <number> <label> : removes a label; a read-only token degrades to a notice
ci_remove_label() {
  local n="$1" label="$2" enc
  enc=$(printf '%s' "$label" | jq -sRr @uri)
  if ci_gh api -X DELETE "repos/$GITHUB_REPOSITORY/issues/$n/labels/$enc" >/dev/null 2>&1; then
    ci_info "removed label $label from #$n"
    return 0
  fi
  ci_notice "could not remove label '$label' from #$n (read-only token or label already gone)"
  return 1
}

# ci_diff_added_lines <base> <head> <path> : the added lines of one file (without the leading +)
ci_diff_added_lines() {
  git diff --no-color --no-ext-diff -U0 "$1...$2" -- "$3" | awk '/^\+\+\+ /{next} /^\+/{print substr($0, 2)}'
}

# ci_diff_removed_lines <base> <head> <path> : the removed lines of one file (without the leading -)
ci_diff_removed_lines() {
  git diff --no-color --no-ext-diff -U0 "$1...$2" -- "$3" | awk '/^--- /{next} /^-/{print substr($0, 2)}'
}

# ci_unmatched_lines <a-file> <b-file> : lines of a whose trimmed text has no
# trimmed twin left in b (multiset difference; each twin is used once)
ci_unmatched_lines() {
  # FILENAME, not NR == FNR: an empty b-file must not swallow the a-file's lines.
  awk -v twins="$2" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
    FILENAME == twins { seen[trim($0)]++; next }
    { t = trim($0); if (seen[t] > 0) { seen[t]--; next } print }
  ' "$2" "$1"
}

# ci_cut <text> [max] : one line, at most max characters (for log excerpts)
ci_cut() {
  local s="$1" max="${2:-160}"
  s=$(printf '%s' "$s" | tr '\r\n\t' '   ')
  if [ "${#s}" -gt "$max" ]; then s="${s:0:$max}..."; fi
  printf '%s' "$s"
}
