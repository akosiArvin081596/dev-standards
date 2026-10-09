#!/usr/bin/env bash
# incident.sh check: two failed production health checks in a row open one incident issue.
# shellcheck source-path=SCRIPTDIR disable=SC2016  # backticks in issue bodies are Markdown code spans
set -euo pipefail
CI_SELF_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=common.sh
. "$CI_SELF_DIR/common.sh"

usage() {
  cat <<'USAGE'
Usage: incident.sh check

Checks production's health URL (env HEALTH_URL, never printed) twice,
INCIDENT_INTERVAL seconds apart (default 60; the second check only runs when
the first fails).
  - both fail: opens one issue labelled incident (none is opened while one is
    already open) and exits 1, so the run shows red
  - healthy: closes any open incident issue with a comment naming the time in
    PROJECT_TIMEZONE, and exits 0
Env: GITHUB_REPOSITORY, GH_TOKEN (issues: write), INCIDENT_TIMEOUT (seconds per
check, default 20). Exit 2 on usage error, 3 when HEALTH_URL is empty.
USAGE
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  check) ;;
  *) ci_usage_error "expected: incident.sh check" ;;
esac
[ "$#" -eq 1 ] || ci_usage_error "expected one argument"
url="${HEALTH_URL:-}"
if [ -z "$url" ]; then
  printf 'not configured: HEALTH_URL is empty (the PRODUCTION_HEALTH_URL secret is set by team-provision)\n' >&2
  exit "$CI_EXIT_NOT_CONFIGURED"
fi
interval="${INCIDENT_INTERVAL:-60}"
timeout="${INCIDENT_TIMEOUT:-20}"
case "$interval$timeout" in *[!0-9]*) ci_usage_error "INCIDENT_INTERVAL and INCIDENT_TIMEOUT are seconds" ;; esac
ci_require_cmd curl jq
ci_require_repo
repo="$GITHUB_REPOSITORY"

tmp=$(ci_mktemp_dir)
trap 'rm -rf "${tmp:?}"' EXIT

probe() { curl -fsS -o /dev/null --max-time "$timeout" -- "$url" 2>/dev/null; }

healthy=1
if ! probe; then
  ci_info "health check 1 failed; checking again in ${interval}s"
  sleep "$interval"
  if ! probe; then healthy=0; else ci_notice "health check 1 failed, check 2 passed: treated as healthy"; fi
fi

ci_gh api "repos/$repo/issues?labels=incident&state=open&per_page=20" \
  --jq '[.[] | select(has("pull_request") | not) | .number] | map(tostring) | join(" ")' > "$tmp/open" \
  || ci_die "$CI_EXIT_FAIL" "could not list incident issues"
open=$(cat "$tmp/open")
when=$(ci_human_time)
run=$(ci_run_url)

if [ "$healthy" = 0 ]; then
  if [ -n "$open" ]; then
    ci_error "production is still down (incident #${open%% *} is open)"
    exit 1
  fi
  {
    printf 'Production failed its health check twice in a row, %s.\n\n' "$when"
    [ -n "$run" ] && printf 'Run: %s\n\n' "$run"
    printf 'Follow the incident runbook (`docs/runbooks/`). This issue closes itself when the health check passes again.\n'
  } > "$tmp/body"
  ci_gh api -X POST "repos/$repo/issues" -f "title=Production health check failing" -F "body=@$tmp/body" -f "labels[]=incident" \
    --jq '.number' > "$tmp/new" || ci_die "$CI_EXIT_FAIL" "could not open the incident issue"
  ci_error "production is down: opened incident #$(cat "$tmp/new")"
  exit 1
fi

ci_info "ok: production is healthy"
[ -n "$open" ] || exit 0
{
  printf 'Recovered: the production health check passes again, %s.\n' "$when"
  [ -n "$run" ] && printf '\nRun: %s\n' "$run"
} > "$tmp/body"
for n in $open; do
  ci_gh api -X POST "repos/$repo/issues/$n/comments" -F "body=@$tmp/body" >/dev/null || ci_die "$CI_EXIT_FAIL" "could not comment on #$n"
  ci_gh api -X PATCH "repos/$repo/issues/$n" -f state=closed -f state_reason=completed >/dev/null || ci_die "$CI_EXIT_FAIL" "could not close #$n"
  ci_info "closed incident #$n"
done
