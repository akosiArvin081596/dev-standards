#!/usr/bin/env bash
# conf.sh get <file> <key> [default]: read one KEY=value from a config file.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
CI_SELF_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=common.sh
. "$CI_SELF_DIR/common.sh"

usage() {
  cat <<'USAGE'
Usage: conf.sh get <file> <key> [default]

Prints the value of <key> from a KEY=value file such as ops/project.conf.
The file is parsed, never sourced: comment lines start with #, the last
assignment wins, and one pair of surrounding quotes is stripped (same rules
as team_conf_get in plugins/team/lib/team-common.sh). A missing file or key
prints the default (empty when not given). Exit 0, or 2 on a usage error.
USAGE
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  get) ;;
  *) ci_usage_error "expected: conf.sh get <file> <key> [default]" ;;
esac
[ "$#" -ge 3 ] && [ "$#" -le 4 ] || ci_usage_error "expected: conf.sh get <file> <key> [default]"
ci_conf_get "$2" "$3" "${4-}"
printf '\n'
