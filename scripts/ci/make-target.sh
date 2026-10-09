#!/usr/bin/env bash
# make-target.sh <target>: run one Makefile target; "not configured" (exit 3) becomes a notice.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
CI_SELF_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=common.sh
. "$CI_SELF_DIR/common.sh"

usage() {
  cat <<'USAGE'
Usage: make-target.sh <target> [make args...]

Runs `make <target>` in the current directory and streams its output.
A target that exits 3 and prints "not configured" (docs/rules.md §4) counts as
not set up yet: a notice is printed and the script exits 0 with step output
status=not-configured. Make itself turns a recipe's exit 3 into its own exit 2,
so both the "Error 3" line and the "not configured" text are required; any
other failure (including a missing target or Makefile) exits 1.
Step outputs (in Actions): status=ok|not-configured|failed.
USAGE
}

case "${1:-}" in -h|--help) usage; exit 0 ;; '') ci_usage_error "missing target" ;; esac
target="$1"
shift
case "$target" in -*|*[!A-Za-z0-9_.-]*) ci_usage_error "bad target name: $target" ;; esac
ci_require_cmd make

if [ ! -f Makefile ] && [ ! -f makefile ] && [ ! -f GNUmakefile ]; then
  ci_output status failed
  ci_die "$CI_EXIT_FAIL" "no Makefile in $(pwd): every project needs the shared targets (setup lint test build audit anonymize-check …)"
fi

tmp=$(ci_mktemp_dir)
trap 'rm -rf "${tmp:?}"' EXIT
log="$tmp/make.log"

ci_info "make $target"
set +e
make "$target" "$@" 2>&1 | tee "$log"
rc=${PIPESTATUS[0]}
set -e

if [ "$rc" -eq 0 ]; then
  ci_output status ok
  exit 0
fi

# Make 3.81: "make: *** [test] Error 3"; GNU make 4: "make: *** [Makefile:5: test] Error 3".
# Both markers are required, so a real tool that happens to exit 3 (pytest's
# internal error, say) is never mistaken for "not configured".
if [ "$rc" -eq 2 ] && grep -Eq '\*\*\* \[[^]]*\] Error 3$' "$log" && grep -q 'not configured' "$log"; then
  ci_output status not-configured
  ci_notice "make $target: not configured (fill in the Makefile target for your stack); skipped"
  exit 0
fi

ci_output status failed
ci_error "make $target failed (exit $rc)"
exit 1
