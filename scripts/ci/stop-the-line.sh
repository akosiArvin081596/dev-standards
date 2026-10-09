#!/usr/bin/env bash
# stop-the-line.sh: while a main-red issue is open, only PRs labelled fixes-main may pass.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
CI_SELF_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=common.sh
. "$CI_SELF_DIR/common.sh"

usage() {
  cat <<'USAGE'
Usage: stop-the-line.sh --pr <number> [--issues-json FILE] [--labels-json FILE]

Fails when the repository (GITHUB_REPOSITORY) has an open issue labelled
main-red and the pull request isn't labelled fixes-main. Labels are read live
from the API (GH_TOKEN; read access is enough), so re-running the job after
adding fixes-main works. For tests, --issues-json (the open main-red issues, a
JSON array) and --labels-json (the PR's label names, a JSON array) replace the
API calls. Env PR_NUMBER works for --pr.
Exit 0 when the line is clear or the PR fixes main, 1 when it must wait,
2 on usage error, 5 when the repository is unknown.
USAGE
}

pr="${PR_NUMBER:-}"
issues_json=""
labels_json=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --pr) [ "$#" -ge 2 ] || ci_usage_error "--pr needs a value"; pr="$2"; shift 2 ;;
    --issues-json) [ "$#" -ge 2 ] || ci_usage_error "--issues-json needs a value"; issues_json="$2"; shift 2 ;;
    --labels-json) [ "$#" -ge 2 ] || ci_usage_error "--labels-json needs a value"; labels_json="$2"; shift 2 ;;
    *) ci_usage_error "unknown argument: $1" ;;
  esac
done
case "$pr" in ''|*[!0-9]*) ci_usage_error "missing or bad PR number" ;; esac

tmp=$(ci_mktemp_dir)
trap 'rm -rf "${tmp:?}"' EXIT

if [ -n "$issues_json" ]; then
  cp "$issues_json" "$tmp/issues.json"
else
  ci_require_repo
  ci_gh api "repos/$GITHUB_REPOSITORY/issues?labels=main-red&state=open&per_page=20" > "$tmp/issues.json" \
    || ci_die "$CI_EXIT_FAIL" "could not read the open main-red issues; re-run the job"
fi
jq -r '[.[] | select(has("pull_request") | not) | .number] | map(tostring) | join(" ")' "$tmp/issues.json" > "$tmp/open"
open=$(cat "$tmp/open")
if [ -z "$open" ]; then
  ci_info "ok: main is green (no open main-red issue)"
  exit 0
fi

if [ -n "$labels_json" ]; then
  cp "$labels_json" "$tmp/labels.json"
else
  ci_gh api "repos/$GITHUB_REPOSITORY/issues/$pr" --jq '[.labels[].name]' > "$tmp/labels.json" \
    || ci_die "$CI_EXIT_FAIL" "could not read the labels of #$pr; re-run the job"
fi
if jq -e 'index("fixes-main") != null' "$tmp/labels.json" >/dev/null; then
  ci_notice "main is red (issue #${open// /, #}); this PR is labelled fixes-main, so it may go ahead"
  exit 0
fi
ci_error "stop the line: main is red (issue #${open// /, #}). Fix main first; only a PR labelled fixes-main may merge until main is green again."
exit 1
