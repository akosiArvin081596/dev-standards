#!/usr/bin/env bash
# main-red.sh open|close: one main-red issue while the main pipeline fails.
# shellcheck source-path=SCRIPTDIR disable=SC2016  # backticks in issue bodies are Markdown code spans
set -euo pipefail
CI_SELF_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=common.sh
. "$CI_SELF_DIR/common.sh"

usage() {
  cat <<'USAGE'
Usage: main-red.sh open|close

open:  when no issue labelled main-red is open, opens one ("main is red") with
       the failing run, commit and time; otherwise comments on the open one.
close: comments that main is green again and closes every open main-red issue.
Env: GITHUB_REPOSITORY, GH_TOKEN (issues: write), GITHUB_SHA, GITHUB_RUN_ID,
GITHUB_WORKFLOW, PROJECT_TIMEZONE (times people read name the timezone).
Exit 0, 1 when GitHub refuses, 2 on usage error, 5 when the repository is unknown.
USAGE
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  open|close) action="$1" ;;
  *) ci_usage_error "expected open or close" ;;
esac
[ "$#" -eq 1 ] || ci_usage_error "expected one argument"
ci_require_repo
repo="$GITHUB_REPOSITORY"

tmp=$(ci_mktemp_dir)
trap 'rm -rf "${tmp:?}"' EXIT

ci_gh api "repos/$repo/issues?labels=main-red&state=open&per_page=20" \
  --jq '[.[] | select(has("pull_request") | not) | .number] | map(tostring) | join(" ")' > "$tmp/open" \
  || ci_die "$CI_EXIT_FAIL" "could not list main-red issues"
open=$(cat "$tmp/open")
sha="${GITHUB_SHA:-unknown}"
when=$(ci_human_time)
run=$(ci_run_url)
workflow="${GITHUB_WORKFLOW:-pipeline}"

if [ "$action" = open ]; then
  {
    printf 'The `%s` workflow failed on `main` at commit %s, %s.\n\n' "$workflow" "${sha:0:12}" "$when"
    [ -n "$run" ] && printf 'Run: %s\n\n' "$run"
    printf 'While this issue is open, `ci` fails on every PR that is not labelled `fixes-main`. Fix main first; the issue closes itself when main is green again.\n'
  } > "$tmp/body"
  if [ -n "$open" ]; then
    first="${open%% *}"
    ci_gh api -X POST "repos/$repo/issues/$first/comments" -F "body=@$tmp/body" >/dev/null \
      || ci_die "$CI_EXIT_FAIL" "could not comment on #$first"
    ci_info "main-red #$first is already open; added the new failure"
  else
    ci_gh api -X POST "repos/$repo/issues" -f "title=main is red" -F "body=@$tmp/body" -f "labels[]=main-red" \
      --jq '.number' > "$tmp/new" || ci_die "$CI_EXIT_FAIL" "could not open the main-red issue"
    ci_info "opened main-red issue #$(cat "$tmp/new")"
  fi
  exit 0
fi

if [ -z "$open" ]; then
  ci_info "main is green; no main-red issue to close"
  exit 0
fi
{
  printf 'main is green again: the `%s` workflow passed at commit %s, %s.\n' "$workflow" "${sha:0:12}" "$when"
  [ -n "$run" ] && printf '\nRun: %s\n' "$run"
} > "$tmp/body"
for n in $open; do
  ci_gh api -X POST "repos/$repo/issues/$n/comments" -F "body=@$tmp/body" >/dev/null || ci_die "$CI_EXIT_FAIL" "could not comment on #$n"
  ci_gh api -X PATCH "repos/$repo/issues/$n" -f state=closed -f state_reason=completed >/dev/null || ci_die "$CI_EXIT_FAIL" "could not close #$n"
  ci_info "closed main-red #$n"
done
