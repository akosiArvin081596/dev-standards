#!/usr/bin/env bash
# guarded-paths.sh: guarded PRs need the owner's own owner-approved label.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
CI_SELF_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=common.sh
. "$CI_SELF_DIR/common.sh"

usage() {
  cat <<'USAGE'
Usage: guarded-paths.sh --pr <n> --base <sha> --head <sha> [--profile project|standards|template]
                        [--event <action>] [--owner <login>]
                        [--labels-json FILE] [--events-json FILE] [--suites-json FILE]

Run at the root of the caller's checkout (full history). A PR is guarded when:
  - a changed path matches config/guarded-globs.txt (profile standards: every path)
  - a file under the BASE commit's MIGRATIONS_GLOB (ops/project.conf) is deleted,
    or gets an added line matching config/destructive-migration-patterns.txt
It also notes high-risk paths (the BASE commit's HIGH_RISK_GLOBS).
Labels: adds guarded and high-risk; removes owner-approved on `synchronize`
(new commits) and whenever it is stale. A read-only token only prints a notice.
Approval: owner-approved must be on the PR, the latest labeled/unlabeled event
for it must be `labeled` by the owner (--owner, else OWNER_LOGIN, else the repo
owner), and it must be newer than the head commit's first check suite (when the
commit arrived). So an approval never carries over to new commits.
Env fallbacks: PR_NUMBER BASE_SHA HEAD_SHA PROFILE EVENT_ACTION OWNER_LOGIN
GITHUB_REPOSITORY GITHUB_REPOSITORY_OWNER GH_TOKEN. The *-json options replace
the API reads (tests): labels = array of names, events = the issue events array,
suites = the check-suites response.
Step outputs: guarded, high_risk, approved (true|false).
Exit 0 when not guarded or approved, 1 when guarded without a valid approval,
2 on usage error, 5 on a missing prerequisite.
USAGE
}

pr="${PR_NUMBER:-}"
base="${BASE_SHA:-}"
head="${HEAD_SHA:-}"
profile="${PROFILE:-project}"
event="${EVENT_ACTION:-}"
owner="${OWNER_LOGIN:-}"
labels_json=""
events_json=""
suites_json=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --pr) [ "$#" -ge 2 ] || ci_usage_error "--pr needs a value"; pr="$2"; shift 2 ;;
    --base) [ "$#" -ge 2 ] || ci_usage_error "--base needs a value"; base="$2"; shift 2 ;;
    --head) [ "$#" -ge 2 ] || ci_usage_error "--head needs a value"; head="$2"; shift 2 ;;
    --profile) [ "$#" -ge 2 ] || ci_usage_error "--profile needs a value"; profile="$2"; shift 2 ;;
    --event) [ "$#" -ge 2 ] || ci_usage_error "--event needs a value"; event="$2"; shift 2 ;;
    --owner) [ "$#" -ge 2 ] || ci_usage_error "--owner needs a value"; owner="$2"; shift 2 ;;
    --labels-json) [ "$#" -ge 2 ] || ci_usage_error "--labels-json needs a value"; labels_json="$2"; shift 2 ;;
    --events-json) [ "$#" -ge 2 ] || ci_usage_error "--events-json needs a value"; events_json="$2"; shift 2 ;;
    --suites-json) [ "$#" -ge 2 ] || ci_usage_error "--suites-json needs a value"; suites_json="$2"; shift 2 ;;
    *) ci_usage_error "unknown argument: $1" ;;
  esac
done
case "$profile" in project|standards|template) ;; *) ci_usage_error "profile must be project, standards or template" ;; esac
if [ -z "$pr" ]; then
  ci_notice "not a pull request: guarded-paths has nothing to check"
  exit 0
fi
case "$pr" in *[!0-9]*) ci_usage_error "bad PR number: $pr" ;; esac
[ -n "$base" ] && [ -n "$head" ] || ci_usage_error "missing --base or --head"
[ -n "$owner" ] || owner="${GITHUB_REPOSITORY_OWNER:-}"
[ -n "$owner" ] || owner="${GITHUB_REPOSITORY%%/*}"
[ -n "$owner" ] || ci_die "$CI_EXIT_PREREQ" "unknown owner login (OWNER_LOGIN or GITHUB_REPOSITORY_OWNER)"
ci_require_cmd git jq
top=$(git rev-parse --show-toplevel 2>/dev/null) || ci_die "$CI_EXIT_PREREQ" "not inside a git checkout"
cd "$top"
git rev-parse --verify --quiet "$base^{commit}" >/dev/null || ci_die "$CI_EXIT_PREREQ" "base commit not found: $base (fetch-depth 0?)"
head_sha=$(git rev-parse --verify --quiet "$head^{commit}") || ci_die "$CI_EXIT_PREREQ" "head commit not found: $head"
if [ -z "$labels_json" ] || [ -z "$events_json" ] || [ -z "$suites_json" ]; then ci_require_repo; fi

tmp=$(ci_mktemp_dir)
trap 'rm -rf "${tmp:?}"' EXIT

# --- what makes it guarded ---------------------------------------------------
globs=()
while IFS= read -r g; do globs+=("$g"); done <<EOF
$(ci_list "$CI_CONFIG_DIR/guarded-globs.txt")
EOF
ci_globs_regex_file "$tmp/guarded.re" ${globs[@]+"${globs[@]}"}

# The guard config comes from the BASE commit, so a PR can't move its own fences.
git show "$base:ops/project.conf" > "$tmp/base.conf" 2>/dev/null || : > "$tmp/base.conf"
mig_globs=$(ci_conf_get "$tmp/base.conf" MIGRATIONS_GLOB "")
risk_globs=$(ci_conf_get "$tmp/base.conf" HIGH_RISK_GLOBS "")
set -f
# shellcheck disable=SC2086  # space-separated glob lists
ci_globs_regex_file "$tmp/mig.re" $mig_globs
# shellcheck disable=SC2086
ci_globs_regex_file "$tmp/risk.re" $risk_globs
set +f
ci_patterns_file "$CI_CONFIG_DIR/destructive-migration-patterns.txt" "$tmp/destructive.re"

: > "$tmp/reasons"
: > "$tmp/risky"
git diff -z --no-color --no-ext-diff --name-status --no-renames "$base...$head" > "$tmp/status"
n_files=0
while IFS= read -r -d '' st; do
  IFS= read -r -d '' path
  n_files=$((n_files + 1))
  if [ "$profile" = standards ]; then
    printf '%s (every path is guarded in this repo)\n' "$path" >> "$tmp/reasons"
  elif printf '%s\n' "$path" | ci_filter_paths "$tmp/guarded.re" | grep -q .; then
    printf '%s (safety system)\n' "$path" >> "$tmp/reasons"
  fi
  if printf '%s\n' "$path" | ci_filter_paths "$tmp/mig.re" | grep -q .; then
    if [ "$st" = D ]; then
      printf '%s (migration deleted)\n' "$path" >> "$tmp/reasons"
    else
      ci_diff_added_lines "$base" "$head" "$path" > "$tmp/added"
      if grep -Ei -f "$tmp/destructive.re" "$tmp/added" > "$tmp/hits" 2>/dev/null; then
        printf '%s (destructive migration: %s)\n' "$path" "$(ci_cut "$(ci_trim "$(head -n 1 "$tmp/hits")")" 80)" >> "$tmp/reasons"
      fi
    fi
  fi
  if printf '%s\n' "$path" | ci_filter_paths "$tmp/risk.re" | grep -q .; then
    printf '%s\n' "$path" >> "$tmp/risky"
  fi
done < "$tmp/status"

guarded=false; [ -s "$tmp/reasons" ] && guarded=true
high_risk=false; [ -s "$tmp/risky" ] && high_risk=true
ci_info "changed files: $n_files · guarded: $guarded · high-risk: $high_risk · event: ${event:-unknown}"

# --- labels, events, check suites -----------------------------------------
if [ -n "$labels_json" ]; then cp "$labels_json" "$tmp/labels.json"
else
  ci_gh api "repos/$GITHUB_REPOSITORY/issues/$pr" --jq '[.labels[].name]' > "$tmp/labels.json" \
    || ci_die "$CI_EXIT_FAIL" "could not read the labels of #$pr; re-run the job"
fi
has_label() { jq -e --arg l "$1" 'index($l) != null' "$tmp/labels.json" >/dev/null; }

if [ "$guarded" = true ] && ! has_label guarded; then ci_add_label "$pr" guarded || true; fi
if [ "$high_risk" = true ] && ! has_label high-risk; then ci_add_label "$pr" high-risk || true; fi

present=false
has_label owner-approved && present=true

approved=false
if [ "$present" = true ]; then
  if [ "$event" = synchronize ]; then
    ci_info "new commits arrived: owner-approved no longer applies"
    ci_remove_label "$pr" owner-approved || true
    present=false
  else
    if [ -n "$events_json" ]; then cp "$events_json" "$tmp/events.json"
    else
      if ! ci_gh api --paginate "repos/$GITHUB_REPOSITORY/issues/$pr/events?per_page=100" --jq '.[]' > "$tmp/events.jsonl"; then
        ci_die "$CI_EXIT_FAIL" "could not read the label events of #$pr; re-run the job"
      fi
      jq -s '.' "$tmp/events.jsonl" > "$tmp/events.json"
    fi
    if [ -n "$suites_json" ]; then cp "$suites_json" "$tmp/suites.json"
    else
      ci_gh api "repos/$GITHUB_REPOSITORY/commits/$head_sha/check-suites?per_page=100" > "$tmp/suites.json" 2>/dev/null \
        || echo '{"check_suites":[]}' > "$tmp/suites.json"
    fi
    last=$(jq -r '[.[] | select((.event == "labeled" or .event == "unlabeled") and .label.name == "owner-approved")]
                  | last | if . == null then "none\t\t" else "\(.event)\t\(.actor.login // "")\t\(.created_at // "")" end' "$tmp/events.json")
    last_event=$(printf '%s' "$last" | cut -f1)
    last_actor=$(printf '%s' "$last" | cut -f2)
    last_at=$(printf '%s' "$last" | cut -f3)
    pushed_at=$(jq -r '[.check_suites[]?.created_at // empty] | sort | first // ""' "$tmp/suites.json")
    owner_lc=$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]')
    actor_lc=$(printf '%s' "$last_actor" | tr '[:upper:]' '[:lower:]')
    if [ "$last_event" != labeled ]; then
      ci_notice "owner-approved has no matching labeled event; it doesn't count"
    elif [ "$actor_lc" != "$owner_lc" ]; then
      ci_notice "owner-approved was added by $last_actor, not the owner ($owner); it doesn't count"
      ci_remove_label "$pr" owner-approved || true
    elif [ -z "$pushed_at" ]; then
      ci_notice "could not tell when the head commit arrived; owner-approved can't be verified (re-run the job)"
    elif [[ "$last_at" > "$pushed_at" ]]; then
      approved=true
    else
      ci_notice "owner-approved ($last_at) predates the latest commits ($pushed_at); the owner must approve again"
      ci_remove_label "$pr" owner-approved || true
    fi
  fi
fi

ci_output guarded "$guarded"
ci_output high_risk "$high_risk"
ci_output approved "$approved"

if [ "$high_risk" = true ]; then
  ci_notice "high-risk paths changed: $(head -n 5 "$tmp/risky" | tr '\n' ' ')(team-security reviews these)"
fi
if [ "$guarded" = false ]; then
  ci_info "ok: not guarded"
  exit 0
fi
ci_summary "### Guarded paths"
while IFS= read -r r; do ci_summary "- \`$r\`"; done < <(head -n 30 "$tmp/reasons")
n_reasons=$(wc -l < "$tmp/reasons" | tr -d ' ')
head -n 30 "$tmp/reasons" | sed 's/^/guarded: /'
[ "$n_reasons" -le 30 ] || ci_info "… and $((n_reasons - 30)) more"
if [ "$approved" = true ]; then
  ci_notice "guarded PR approved by the owner ($owner)"
  exit 0
fi
ci_error "guarded PR: it changes the safety system or a migration destructively ($n_reasons path(s)). It needs owner-approved added by the owner ($owner) after the latest commit. Agents never add it."
exit 1
