#!/usr/bin/env bash
# pr-title.sh: the PR title (env PR_TITLE) must be a Conventional Commit.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
CI_SELF_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=common.sh
. "$CI_SELF_DIR/common.sh"

usage() {
  cat <<'USAGE'
Usage: PR_TITLE='<title>' pr-title.sh

Checks that the pull request title is a Conventional Commit:
  <type>[(<scope>)][!]: <description>
<type> comes from config/pr-title-types.txt; ! marks a breaking change.
The title is read from the PR_TITLE environment variable only (never put
${{ }} expressions inside a script). Exit 0 when valid, 1 when not, 2 when
PR_TITLE is unset.
USAGE
}

case "${1:-}" in -h|--help) usage; exit 0 ;; '') ;; *) ci_usage_error "unexpected argument: $1" ;; esac
[ "${PR_TITLE+set}" = set ] || ci_usage_error "PR_TITLE is not set"

types=""
while IFS= read -r t; do
  case "$t" in *[!a-z]*|'') ci_die "$CI_EXIT_FAIL" "bad type in config/pr-title-types.txt: $t" ;; esac
  types="${types:+$types|}$t"
done <<LIST
$(ci_list "$CI_CONFIG_DIR/pr-title-types.txt")
LIST
[ -n "$types" ] || ci_die "$CI_EXIT_PREREQ" "no types in $CI_CONFIG_DIR/pr-title-types.txt"

title="$PR_TITLE"
re="^($types)(\([A-Za-z0-9_./-]+\))?!?: [^[:space:]].*$"

# Always print outside text after a prefix, so it can never start a workflow command.
printf 'title: %s\n' "$(ci_cut "$title" 200)"
if [[ "$title" =~ $re ]] && [ "${title%"${title##*[![:space:]]}"}" = "$title" ]; then
  ci_info "ok: Conventional Commits title"
  exit 0
fi
ci_error "the PR title must be a Conventional Commit: <type>[(<scope>)][!]: <description>, with <type> one of: ${types//|/, }. Example: feat(auth): add login rate limit"
exit 1
