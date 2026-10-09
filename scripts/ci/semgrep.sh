#!/usr/bin/env bash
# semgrep.sh: Semgrep CE (p/default), metrics off, only findings new since the base commit.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
CI_SELF_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=common.sh
. "$CI_SELF_DIR/common.sh"

usage() {
  cat <<'USAGE'
Usage: semgrep.sh --base <sha> [path]

Run in the ci working directory before anything changes tracked files (Semgrep
aborts on unstaged changes). Installs semgrep SEMGREP_VERSION from
config/tool-versions.env into a venv (unless that exact version is already on
PATH), then runs, with no login and no metrics:
  semgrep scan --config p/default --metrics=off --baseline-commit <merge-base> --error [path]
so only findings that are new compared with the base commit fail. The default
path is the current folder. Env BASE_SHA works for --base.
Exit 0 clean, 1 on new findings or a Semgrep error, 2 on usage error,
5 when python3 is missing.
USAGE
}

base="${BASE_SHA:-}"
target="."
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --base) [ "$#" -ge 2 ] || ci_usage_error "--base needs a value"; base="$2"; shift 2 ;;
    -*) ci_usage_error "unknown option: $1" ;;
    *) target="$1"; shift ;;
  esac
done
[ -n "$base" ] || ci_usage_error "missing --base (or BASE_SHA)"
git rev-parse --verify --quiet "$base^{commit}" >/dev/null || ci_die "$CI_EXIT_PREREQ" "base commit not found: $base (fetch-depth 0?)"
version=$(ci_tool_version SEMGREP_VERSION)
case "$version" in ''|*[!0-9.]*) ci_die "$CI_EXIT_PREREQ" "bad or missing SEMGREP_VERSION in config/tool-versions.env" ;; esac

export SEMGREP_SEND_METRICS=off
export SEMGREP_ENABLE_VERSION_CHECK=0
sg=""
if command -v semgrep >/dev/null 2>&1 && [ "$(semgrep --version 2>/dev/null | tail -n 1)" = "$version" ]; then
  sg=$(command -v semgrep)
else
  ci_require_cmd python3
  venv="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/team-semgrep-$version"
  if [ ! -x "$venv/bin/semgrep" ]; then
    ci_info "installing semgrep $version"
    python3 -m venv "$venv" || ci_die "$CI_EXIT_PREREQ" "python3 -m venv failed (install python3-venv)"
    "$venv/bin/pip" install --quiet --disable-pip-version-check "semgrep==$version" || ci_die "$CI_EXIT_FAIL" "pip install semgrep==$version failed"
  fi
  sg="$venv/bin/semgrep"
fi

merge_base=$(git merge-base "$base" HEAD) || ci_die "$CI_EXIT_FAIL" "no merge base between $base and HEAD"
ci_info "semgrep $version: p/default, new findings since $merge_base"
set +e
"$sg" scan --config p/default --metrics=off --disable-version-check --baseline-commit "$merge_base" --error "$target"
rc=$?
set -e
case "$rc" in
  0) ci_info "ok: no new Semgrep findings" ;;
  1) ci_error "Semgrep found new issues (above). Fix them, or explain a false positive with a nosemgrep comment and the reason."; exit 1 ;;
  *) ci_error "Semgrep failed (exit $rc)"; exit 1 ;;
esac
