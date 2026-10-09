#!/usr/bin/env bash
# package.sh <artifact-dir> <out.tar.gz>: the release tarball = ARTIFACT_DIR contents + ops/.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
CI_SELF_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=common.sh
. "$CI_SELF_DIR/common.sh"

usage() {
  cat <<'USAGE'
Usage: package.sh <artifact-dir> <out.tar.gz>

Run in the project root. Writes the release tarball (docs/rules.md §11): the
contents of <artifact-dir> (what `make build` produced, normally ARTIFACT_DIR
from ops/project.conf) plus the project's ops/ folder at the tarball root, so
the server always has the release's own ops/anonymize and services.conf.
Refuses an empty artifact dir, a missing ops/, an artifact that has its own
ops/, and an output path inside the artifact. Step output: tarball=<path>.
Exit 0, 1 on failure, 2 on usage error, 5 when ops/ is missing.
USAGE
}

case "${1:-}" in -h|--help) usage; exit 0 ;; esac
[ "$#" -eq 2 ] || ci_usage_error "expected: package.sh <artifact-dir> <out.tar.gz>"
art="$1"
out="$2"
root=$(pwd)

[ -d "$art" ] || ci_die "$CI_EXIT_FAIL" "artifact dir not found: $art (did make build fill it?)"
art=$(cd "$art" && pwd)
[ -d "$root/ops" ] || ci_die "$CI_EXIT_PREREQ" "no ops/ folder in $root: the release needs ops/project.conf, services.conf and anonymize"
if [ -z "$(ls -A "$art")" ]; then
  ci_die "$CI_EXIT_FAIL" "artifact dir is empty: $art (make build must fill it with exactly the release)"
fi
[ ! -e "$art/ops" ] || ci_die "$CI_EXIT_FAIL" "the artifact has its own ops/ entry; it would clash with the project's ops/ in the release"
[ "$art" != "$root" ] || ci_die "$CI_EXIT_FAIL" "the artifact dir can't be the project root"

out_dir=$(dirname "$out")
mkdir -p "$out_dir"
out="$(cd "$out_dir" && pwd)/$(basename "$out")"
case "$out" in "$art"/*) ci_die "$CI_EXIT_FAIL" "the tarball can't be written inside the artifact dir" ;; esac

tar -czf "$out" -C "$art" . -C "$root" ops
size=$(wc -c < "$out" | tr -d ' ')
ci_info "wrote $out ($size bytes)"
ci_output tarball "$out"
