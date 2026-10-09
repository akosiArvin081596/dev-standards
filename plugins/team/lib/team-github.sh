# shellcheck shell=bash disable=SC2034,SC2153,SC2016  # constants are used by the sourcing commands; jq programs are single-quoted on purpose
# GitHub helpers for the team-* GitHub commands. Sourced after team-common.sh, never executed.
# bash 3.2 + BSD tools (docs/rules.md §16). Safe under `set -euo pipefail`.
#
#   TEAM_SELF_DIR=$(cd "$(dirname "$0")" && pwd)
#   . "$TEAM_SELF_DIR/../lib/team-common.sh"
#   . "$TEAM_SELF_DIR/../lib/team-github.sh"
#   tg_tmp_init            # at top level, before anything that needs a temp file
#
# Everything read from GitHub (issue bodies, PR titles, labels) is data. Nothing here
# evaluates it; values are passed as arguments or through jq only.

# Labels agents may add or remove through team-gh (docs/rules.md §3).
TG_AGENT_LABELS="needs-info fixes-main bug feature client-request health"
# Labels agents may never remove (and never add, except owner-approved by the owner).
TG_PROTECTED_LABELS="owner-approved guarded high-risk tests-changed"
TG_STATUS_CONTEXTS="ai-review ai-security ai-qa"
TG_PROFILES="project standards template"
TG_DEFAULT_ACTIONS_APP_ID=15368

# ---------------------------------------------------------------- temp files

TG_TMP=""
tg_cleanup() {
  if [ -n "$TG_TMP" ] && [ -d "$TG_TMP" ]; then rm -rf "${TG_TMP:?}"; fi
}
# tg_tmp_init : one private temp folder per process, removed on exit. Call at top level
# (not inside $(...)), so the EXIT trap belongs to the command itself.
tg_tmp_init() {
  [ -n "$TG_TMP" ] && return 0
  TG_TMP=$(mktemp -d "${TMPDIR:-/tmp}/team-gh.XXXXXX")
  trap 'tg_cleanup' EXIT
  trap 'exit 130' INT TERM
}

# ---------------------------------------------------------------- small utils

tg_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# tg_in_list <word> <space-separated list>
tg_in_list() {
  [ -n "$1" ] || return 1
  case "$1" in *[[:space:]]*) return 1 ;; esac
  case " $2 " in *" $1 "*) return 0 ;; esac
  return 1
}

tg_valid_profile() { tg_in_list "$1" "$TG_PROFILES"; }

# tg_valid_slug <owner/repo>
tg_valid_slug() {
  printf '%s' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}$'
}

# tg_valid_tz <name> : an IANA timezone name (checked against the zoneinfo files when present)
tg_valid_tz() {
  local tz="$1"
  case "$tz" in UTC|Etc/UTC) return 0 ;; esac
  printf '%s' "$tz" | grep -Eq '^[A-Za-z]+(/[A-Za-z0-9_+-]+){1,2}$' || return 1
  if [ -d /usr/share/zoneinfo ]; then [ -f "/usr/share/zoneinfo/$tz" ] || return 1; fi
  return 0
}

# tg_desired_settings_json <is_template true|false> <free_private 0|1> : repo merge settings
tg_desired_settings_json() {
  jq -cn --argjson t "$1" --arg fp "$2" '{
    allow_squash_merge: true, allow_merge_commit: false, allow_rebase_merge: false,
    squash_merge_commit_title: "PR_TITLE", squash_merge_commit_message: "BLANK",
    delete_branch_on_merge: true, allow_auto_merge: true, is_template: $t}
    | if $fp == "1" then del(.allow_auto_merge) else . end'
}

# tg_strip_host <[HOST/]OWNER/REPO> : drops a leading host segment
tg_strip_host() {
  local s="$1"
  case "$s" in */*/*) s="${s#*/}" ;; esac
  printf '%s' "$s"
}

# tg_same_repo <a> <b> : owner/repo equal, ignoring case and a leading host
tg_same_repo() {
  local a b
  a=$(tg_lower "$(tg_strip_host "${1%.git}")")
  b=$(tg_lower "$(tg_strip_host "${2%.git}")")
  [ -n "$a" ] && [ "$a" = "$b" ]
}

# tg_printable <text> : strip control characters (terminal escapes) from outside text
tg_printable() { printf '%s' "$1" | LC_ALL=C tr -d '\000-\010\013-\037\177'; }

tg_is_release_ref() {
  case "$1" in release-please--*|*:release-please--*) return 0 ;; esac
  return 1
}

# tg_remote_parts <url> : prints "<host>|<owner/repo>" for ssh, scp-like and https URLs
tg_remote_parts() {
  local url="$1" host="" path
  case "$url" in
    *://*)
      path="${url#*://}"
      host="${path%%/*}"
      path="${path#*/}"
      host="${host#*@}"
      host="${host%%:*}"
      ;;
    *:*)
      host="${url%%:*}"
      host="${host#*@}"
      path="${url#*:}"
      ;;
    *) path="$url" ;;
  esac
  path="${path%/}"
  path="${path%.git}"
  printf '%s|%s' "$host" "$path"
}

# tg_account_for_remote <url> : the accounts.conf login that should read this remote, or empty.
# Order: the repo owner is a configured account login; else the SSH host alias is a
# configured account's alias. Hosts that are neither github.com nor a configured alias → empty.
tg_account_for_remote() {
  local parts host slug owner kind login alias rest known_host=0 by_alias=""
  parts=$(tg_remote_parts "$1")
  host="${parts%%|*}"
  slug="${parts#*|}"
  owner="${slug%%/*}"
  [ "$host" = "github.com" ] && known_host=1
  while IFS='|' read -r kind login alias rest; do
    [ "$kind" = "account" ] || continue
    [ -n "$alias" ] && [ "$alias" = "$host" ] && { known_host=1; [ -n "$by_alias" ] || by_alias="$login"; }
  done <<EOF
$(team_accounts)
EOF
  [ "$known_host" = 1 ] || return 0
  while IFS='|' read -r kind login rest; do
    [ "$kind" = "account" ] || continue
    if [ "$(tg_lower "$login")" = "$(tg_lower "$owner")" ]; then printf '%s' "$login"; return 0; fi
  done <<EOF
$(team_accounts)
EOF
  printf '%s' "$by_alias"
}

# tg_is_account_login <login> : true when <login> has an `account|` line in accounts.conf
tg_is_account_login() {
  local kind login rest
  while IFS='|' read -r kind login rest; do
    [ "$kind" = "account" ] && [ "$login" = "$1" ] && return 0
  done <<EOF
$(team_accounts)
EOF
  return 1
}

# tg_require_login <login> : exit 5 unless gh holds a token for <login> (token never printed)
tg_require_login() {
  team_require_cmd gh
  command gh auth token -u "$1" >/dev/null 2>&1 \
    || team_die "$TEAM_EXIT_PREREQ" "gh is not logged in as $1 (run: gh auth login, then retry)"
}

# ---------------------------------------------------------------- gh api with captured results

# TG_LOGIN must be set by the command. tg_api_try <method> <path> [body-json]
# Never exits on HTTP errors. Sets TG_RC (gh exit code), TG_HTTP (status code: 200 on
# success, else the code gh reports, or empty when unknown), TG_OUT (stdout), TG_ERR (stderr).
tg_api_try() {
  local m="$1" p="$2" of ef
  of="$TG_TMP/api.out"
  ef="$TG_TMP/api.err"
  TG_RC=0
  if [ $# -ge 3 ]; then
    printf '%s' "$3" | team_gh_as "$TG_LOGIN" api -X "$m" "$p" --input - >"$of" 2>"$ef" || TG_RC=$?
  else
    team_gh_as "$TG_LOGIN" api -X "$m" "$p" </dev/null >"$of" 2>"$ef" || TG_RC=$?
  fi
  TG_OUT=$(cat "$of")
  TG_ERR=$(cat "$ef")
  TG_HTTP=$(printf '%s\n' "$TG_ERR" | sed -n 's/.*(HTTP \([0-9][0-9][0-9]\)).*/\1/p' | tail -n 1)
  if [ "$TG_RC" = 0 ] && [ -z "$TG_HTTP" ]; then TG_HTTP=200; fi
  return 0
}

# tg_api_get <path> : GET that must succeed; prints the body (exit 1 with gh's message otherwise)
tg_api_get() {
  tg_api_try GET "$1"
  [ "$TG_RC" = 0 ] || team_die "$TEAM_EXIT_FAIL" "GET $1 failed: $(tg_printable "$TG_ERR")"
  printf '%s' "$TG_OUT"
}

# tg_api_get_all <path> <jq-array-expression> : paginated GET, merged into one JSON array.
# The expression picks the list out of one page, e.g. '.' or '.check_runs'.
tg_api_get_all() {
  local p="$1" expr="$2" of="$TG_TMP/page.out" ef="$TG_TMP/page.err" rc=0
  team_gh_as "$TG_LOGIN" api --paginate "$p" </dev/null >"$of" 2>"$ef" || rc=$?
  [ "$rc" = 0 ] || team_die "$TEAM_EXIT_FAIL" "GET $p failed: $(tg_printable "$(cat "$ef")")"
  jq -s "[ .[] | ($expr) // [] | .[] ]" "$of"
}

# ---------------------------------------------------------------- release PR checks

# tg_pr_release_state <login> <repo-or-empty> [selector] : prints "release" or "normal".
# Returns 1 (prints nothing) when the PR can't be read: callers must then refuse.
tg_pr_release_state() {
  local login="$1" repo="$2" sel="${3-}" json
  local args
  args=(pr view)
  [ -n "$sel" ] && args+=("$sel")
  args+=(--json "headRefName,labels")
  [ -n "$repo" ] && args+=(-R "$repo")
  json=$(team_gh_as "$login" "${args[@]}" </dev/null 2>/dev/null) || return 1
  printf '%s' "$json" | jq -e 'type == "object" and has("headRefName")' >/dev/null 2>&1 || return 1
  if printf '%s' "$json" | jq -e '((.headRefName // "") | startswith("release-please--"))
        or any(.labels[]?; ((.name // "") | startswith("autorelease:")))' >/dev/null; then
    printf 'release'
  else
    printf 'normal'
  fi
}

# tg_issue_release_state <login> <owner/repo> <number> : for issue commands that may target a
# PR number. Prints "release", "normal" (a PR that isn't a release PR) or "issue"; returns 1 when unknown.
tg_issue_release_state() {
  local login="$1" repo="$2" n="$3" json
  json=$(team_gh_as "$login" api "repos/$repo/issues/$n" </dev/null 2>/dev/null) || return 1
  printf '%s' "$json" | jq -e 'type == "object" and has("number")' >/dev/null 2>&1 || return 1
  if ! printf '%s' "$json" | jq -e '.pull_request != null' >/dev/null; then
    printf 'issue'
    return 0
  fi
  json=$(team_gh_as "$login" api "repos/$repo/pulls/$n" </dev/null 2>/dev/null) || return 1
  printf '%s' "$json" | jq -e 'type == "object" and has("head")' >/dev/null 2>&1 || return 1
  if printf '%s' "$json" | jq -e '((.head.ref // "") | startswith("release-please--"))
        or any(.labels[]?; ((.name // "") | startswith("autorelease:")))' >/dev/null; then
    printf 'release'
  else
    printf 'normal'
  fi
}

# ---------------------------------------------------------------- dev-standards config files

# tg_standards_ref : the dev-standards ref to download config from when no local copy exists
tg_standards_ref() {
  local root lock rel=""
  if [ -n "${TEAM_STANDARDS_REF:-}" ]; then printf '%s' "$TEAM_STANDARDS_REF"; return 0; fi
  root=$(git rev-parse --show-toplevel 2>/dev/null) || root=""
  lock="$root/.claude/team-standards.lock"
  if [ -n "$root" ] && [ -r "$lock" ]; then
    rel=$(jq -r '.release // empty' "$lock" 2>/dev/null) || rel=""
  fi
  case "$rel" in v[0-9]*) printf '%s' "$rel" ;; *) printf 'v1' ;; esac
}

# tg_config_file <name> : sets TG_CONFIG_PATH to dev-standards config/<name>.
# Order: $TEAM_STANDARDS_DIR/config (authoritative when set) → the clone this plugin runs
# from (<plugin root>/../../config) → download from GitHub (a read) into the temp folder.
TG_CONFIG_PATH=""
tg_config_file() {
  local name="$1" clone ref login out
  case "$name" in ''|*/*|.*) team_die "$TEAM_EXIT_USAGE" "bad config file name: $name" ;; esac
  TG_CONFIG_PATH=""
  if [ -n "${TEAM_STANDARDS_DIR:-}" ]; then
    [ -r "$TEAM_STANDARDS_DIR/config/$name" ] \
      || team_die "$TEAM_EXIT_PREREQ" "TEAM_STANDARDS_DIR is set but $TEAM_STANDARDS_DIR/config/$name is missing"
    TG_CONFIG_PATH="$TEAM_STANDARDS_DIR/config/$name"
    return 0
  fi
  clone=$(cd "$TEAM_PLUGIN_ROOT/../.." 2>/dev/null && pwd) || clone=""
  if [ -n "$clone" ] && [ -r "$clone/.claude-plugin/marketplace.json" ] && [ -r "$clone/config/$name" ]; then
    TG_CONFIG_PATH="$clone/config/$name"
    return 0
  fi
  [ -n "$TG_TMP" ] || team_die "$TEAM_EXIT_FAIL" "internal: tg_tmp_init was not called"
  ref=$(tg_standards_ref)
  mkdir -p "$TG_TMP/config"
  out="$TG_TMP/config/$name"
  login="${TG_LOGIN:-$(team_default DEFAULT_GITHUB_ACCOUNT "")}"
  if [ -n "$login" ]; then
    team_gh_as "$login" api -H 'Accept: application/vnd.github.raw' \
      "repos/$TEAM_STANDARDS_REPO/contents/config/$name?ref=$ref" </dev/null >"$out" 2>/dev/null || : >"$out"
  else
    team_require_cmd gh
    command gh api -H 'Accept: application/vnd.github.raw' \
      "repos/$TEAM_STANDARDS_REPO/contents/config/$name?ref=$ref" </dev/null >"$out" 2>/dev/null || : >"$out"
  fi
  jq -e . "$out" >/dev/null 2>&1 \
    || team_die "$TEAM_EXIT_PREREQ" "config/$name not found locally and not downloadable from $TEAM_STANDARDS_REPO@$ref (set TEAM_STANDARDS_DIR to a dev-standards clone)"
  TG_CONFIG_PATH="$out"
}

# Normalizer for config/required-checks.json. Accepts the shapes a config writer is likely to
# use and returns [{context, integration_id}] (integration_id null = any source).
TG_JQ_REQUIRED_CHECKS='
def appid: (.github_actions_app_id // .actions_app_id // .github_actions.app_id // .app_id // .integration_id // '"$TG_DEFAULT_ACTIONS_APP_ID"');
def items: if type == "array" then . elif type == "string" then [.] else [] end;
def nm: if type == "string" then . else (.context // .name // .check // "") end;
def kind: (if type == "object" then (.source // .type // .kind // "") else "" end) | tostring | ascii_downcase;
appid as $app
| ((.profiles // {})[$profile] // .[$profile]) as $p
| if $p == null then error("profile \($profile) is not in required-checks.json")
  elif ($p | type) == "object" and ($p.required_status_checks != null) then
    [ $p.required_status_checks[] | {context: nm, integration_id: (if type == "object" then (.integration_id // null) else null end)} ]
  elif ($p | type) == "object" then
      [ ($p.actions // $p.github_actions // $p.checks // $p.check_runs // []) | items[]
        | {context: nm, integration_id: ((if type == "object" then (.integration_id // .app_id) else null end) // $app)} ]
    + [ ($p.statuses // $p.status // $p.commit_statuses // []) | items[] | {context: nm, integration_id: null} ]
  elif ($p | type) == "array" then
    [ $p[] | nm as $n | kind as $k
      | {context: $n,
         integration_id: (if ($k | test("status|any")) then null
                          elif ($k | test("action|app|check")) then ((if type == "object" then (.integration_id // .app_id) else null end) // $app)
                          elif (type == "object" and has("integration_id")) then .integration_id
                          elif ($n | startswith("ai-")) then null
                          else $app end)} ]
  else error("profile \($profile): unexpected shape") end
| if any(.[]; (.context | type) != "string" or .context == "") then error("empty check name") else . end'

# tg_required_checks_json <profile> : prints [{context, integration_id}] for the profile
tg_required_checks_json() {
  tg_config_file required-checks.json
  jq -c --arg profile "$1" "$TG_JQ_REQUIRED_CHECKS" "$TG_CONFIG_PATH" 2>/dev/null \
    || team_die "$TEAM_EXIT_PREREQ" "cannot read profile $1 from $TG_CONFIG_PATH"
}

# tg_actions_app_id : the GitHub Actions app id named in required-checks.json (default 15368)
tg_actions_app_id() {
  tg_config_file required-checks.json
  jq -r '(.github_actions_app_id // .actions_app_id // .github_actions.app_id // .app_id // .integration_id // '"$TG_DEFAULT_ACTIONS_APP_ID"') | tostring' "$TG_CONFIG_PATH"
}

# Normalizer for config/labels.json → [{name, color (6 lowercase hex, no #), description}]
TG_JQ_LABELS='
def color: (. // "ededed") | tostring | ltrimstr("#") | ascii_downcase;
def as_list: if type == "array" then .
  elif type == "object" then [ to_entries[] | if (.value | type) == "object" then (.value + {name: .key}) else {name: .key, color: .value} end ]
  else error("unexpected labels.json shape") end;
(if type == "object" and (.labels | type) as $t | ($t == "array" or $t == "object") then .labels else . end) | as_list
| [ .[] | if type == "string" then {name: ., color: "ededed", description: ""}
          else {name: .name, color: (.color | color), description: (.description // "")} end ]
| if any(.[]; (.name | type) != "string" or .name == "") then error("label without a name") else . end'

# tg_labels_json : prints the normalized label list
tg_labels_json() {
  tg_config_file labels.json
  jq -c "$TG_JQ_LABELS" "$TG_CONFIG_PATH" 2>/dev/null \
    || team_die "$TEAM_EXIT_PREREQ" "cannot read labels from $TG_CONFIG_PATH"
}

# ---------------------------------------------------------------- rulesets (research github.md §2)

# tg_branch_ruleset_json <checks-json> : the ruleset for the default branch
tg_branch_ruleset_json() {
  jq -cn --argjson checks "$1" '{
    name: "main",
    target: "branch",
    enforcement: "active",
    conditions: {ref_name: {include: ["~DEFAULT_BRANCH"], exclude: []}},
    bypass_actors: [{actor_id: 5, actor_type: "RepositoryRole", bypass_mode: "pull_request"}],
    rules: [
      {type: "deletion"},
      {type: "non_fast_forward"},
      {type: "pull_request", parameters: {
        required_approving_review_count: 0,
        dismiss_stale_reviews_on_push: false,
        require_code_owner_review: false,
        require_last_push_approval: false,
        required_review_thread_resolution: false,
        allowed_merge_methods: ["squash"]}},
      {type: "required_status_checks", parameters: {
        strict_required_status_checks_policy: false,
        do_not_enforce_on_create: false,
        required_status_checks: [ $checks[] | if .integration_id == null then {context} else {context, integration_id} end ]}}
    ]}'
}

# tg_tag_ruleset_json : the ruleset for release tags
tg_tag_ruleset_json() {
  jq -cn '{
    name: "release-tags",
    target: "tag",
    enforcement: "active",
    conditions: {ref_name: {include: ["refs/tags/v*"], exclude: []}},
    bypass_actors: [{actor_id: 5, actor_type: "RepositoryRole", bypass_mode: "always"}],
    rules: [
      {type: "creation"},
      {type: "update", parameters: {update_allows_fetch_and_merge: false}},
      {type: "deletion"}
    ]}'
}

# Canonical form used to compare a desired ruleset with what GitHub returns (GitHub adds
# fields and may reorder lists; only what the pack sets is compared).
TG_JQ_RULESET_CANON='
def b: if . == null then false else . end;
def params($t):
  if $t == "pull_request" then {
      required_approving_review_count: (.required_approving_review_count // 0),
      dismiss_stale_reviews_on_push: (.dismiss_stale_reviews_on_push | b),
      require_code_owner_review: (.require_code_owner_review | b),
      require_last_push_approval: (.require_last_push_approval | b),
      required_review_thread_resolution: (.required_review_thread_resolution | b),
      allowed_merge_methods: ((.allowed_merge_methods // ["merge","squash","rebase"]) | sort)}
  elif $t == "required_status_checks" then {
      strict: (.strict_required_status_checks_policy | b),
      on_create: (.do_not_enforce_on_create | b),
      checks: ([ (.required_status_checks // [])[] | {context, integration_id: (.integration_id // null)} ] | sort_by(.context))}
  elif $t == "update" then {fetch_and_merge: (.update_allows_fetch_and_merge | b)}
  else {} end;
{ target, enforcement,
  include: ((.conditions.ref_name.include // []) | sort),
  exclude: ((.conditions.ref_name.exclude // []) | sort),
  bypass: ([ (.bypass_actors // [])[] | {actor_id, actor_type, bypass_mode} ] | sort_by(.actor_type, .actor_id)),
  rules: ([ (.rules // [])[] | .type as $t | {type: $t, parameters: ((.parameters // {}) | params($t))} ] | sort_by(.type)) }'

# tg_ruleset_matches <desired-json> <current-json>
tg_ruleset_matches() {
  local a b
  a=$(printf '%s' "$1" | jq -cS "$TG_JQ_RULESET_CANON") || return 1
  b=$(printf '%s' "$2" | jq -cS "$TG_JQ_RULESET_CANON") || return 1
  [ "$a" = "$b" ]
}

# tg_ruleset_diff <desired-json> <current-json> : short, human list of what differs
tg_ruleset_diff() {
  jq -rn --argjson d "$(printf '%s' "$1" | jq -c "$TG_JQ_RULESET_CANON")" \
         --argjson c "$(printf '%s' "$2" | jq -c "$TG_JQ_RULESET_CANON")" '
    [ ($d | keys[]) as $k | select($d[$k] != $c[$k]) | $k ]
    + [ ($d.rules[] | .type) as $t
        | select(([$c.rules[] | select(.type == $t)] | first) != ([$d.rules[] | select(.type == $t)] | first))
        | "rule " + $t ]
    | unique | join(", ")'
}
