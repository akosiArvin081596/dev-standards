#!/usr/bin/env bash
# gitleaks.sh git|dir: secret scan with the pinned, checksum-verified gitleaks binary.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
CI_SELF_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=common.sh
. "$CI_SELF_DIR/common.sh"

usage() {
  cat <<'USAGE'
Usage: gitleaks.sh git --base <sha> [--head <sha>] [--repo DIR]
       gitleaks.sh dir <path> [--config FILE]
       gitleaks.sh verify --tarball FILE

Downloads gitleaks GITLEAKS_VERSION (config/tool-versions.env) for linux x64,
verifies its SHA-256 against GITLEAKS_SHA256 and refuses to run it on a
mismatch. --tarball FILE uses a local tarball instead of downloading (it is
still verified; `verify` only checks it).
  git  scans the commits <base>..<head> (env BASE_SHA, HEAD_SHA; default head
       HEAD) of the repo (default: the git top level of the current folder),
       with the repo's .gitleaks.toml when it has one. Needs full history.
  dir  scans a folder, e.g. the unpacked release artifact, with --config FILE
       or else the current repo's .gitleaks.toml when present.
Findings are redacted. Exit 0 clean, 1 on leaks, a checksum mismatch or a
failed download, 2 on usage error, 5 on an unsupported platform.
USAGE
}

mode="${1:-}"
case "$mode" in
  -h|--help) usage; exit 0 ;;
  git|dir|verify) shift ;;
  *) ci_usage_error "expected git, dir or verify" ;;
esac

base="${BASE_SHA:-}"
head="${HEAD_SHA:-HEAD}"
repo=""
target=""
config=""
tarball=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --base) [ "$#" -ge 2 ] || ci_usage_error "--base needs a value"; base="$2"; shift 2 ;;
    --head) [ "$#" -ge 2 ] || ci_usage_error "--head needs a value"; head="$2"; shift 2 ;;
    --repo) [ "$#" -ge 2 ] || ci_usage_error "--repo needs a value"; repo="$2"; shift 2 ;;
    --config) [ "$#" -ge 2 ] || ci_usage_error "--config needs a value"; config="$2"; shift 2 ;;
    --tarball) [ "$#" -ge 2 ] || ci_usage_error "--tarball needs a value"; tarball="$2"; shift 2 ;;
    -*) ci_usage_error "unknown option: $1" ;;
    *) [ -z "$target" ] || ci_usage_error "unexpected argument: $1"; target="$1"; shift ;;
  esac
done

version=$(ci_tool_version GITLEAKS_VERSION)
want=$(ci_tool_version GITLEAKS_SHA256)
[ -n "$version" ] && [ -n "$want" ] || ci_die "$CI_EXIT_PREREQ" "GITLEAKS_VERSION/GITLEAKS_SHA256 missing from config/tool-versions.env"
case "$version" in *[!0-9.]*) ci_die "$CI_EXIT_FAIL" "bad GITLEAKS_VERSION: $version" ;; esac

tmp=$(ci_mktemp_dir)
trap 'rm -rf "${tmp:?}"' EXIT

if [ -z "$tarball" ]; then
  if [ "$(uname -s)" != "Linux" ] || [ "$(uname -m)" != "x86_64" ]; then
    ci_die "$CI_EXIT_PREREQ" "the pinned gitleaks checksum is for linux x64; on this machine use an installed gitleaks"
  fi
  ci_require_cmd curl tar
  url="https://github.com/gitleaks/gitleaks/releases/download/v${version}/gitleaks_${version}_linux_x64.tar.gz"
  tarball="$tmp/gitleaks.tar.gz"
  curl -fsSL --retry 3 --retry-delay 2 -o "$tarball" "$url" || ci_die "$CI_EXIT_FAIL" "download failed: $url"
fi
[ -f "$tarball" ] || ci_die "$CI_EXIT_FAIL" "no such tarball: $tarball"
got=$(ci_sha256 "$tarball")
if [ "$got" != "$want" ]; then
  ci_die "$CI_EXIT_FAIL" "gitleaks checksum mismatch: expected $want, got $got. Refusing to run it."
fi
ci_info "gitleaks $version checksum verified"
[ "$mode" = verify ] && exit 0

mkdir -p "$tmp/bin"
tar -xzf "$tarball" -C "$tmp/bin" gitleaks
bin="$tmp/bin/gitleaks"
[ -x "$bin" ] || ci_die "$CI_EXIT_FAIL" "the tarball has no gitleaks binary"

set +e
if [ "$mode" = git ]; then
  [ -n "$base" ] || ci_usage_error "git mode needs --base (or BASE_SHA)"
  [ -z "$target" ] || ci_usage_error "git mode takes no path (use --repo)"
  if [ -z "$repo" ]; then repo=$(git rev-parse --show-toplevel 2>/dev/null) || ci_die "$CI_EXIT_PREREQ" "not inside a git checkout"; fi
  git -C "$repo" rev-parse --verify --quiet "$base^{commit}" >/dev/null || ci_die "$CI_EXIT_PREREQ" "base commit not found: $base (fetch-depth 0?)"
  git -C "$repo" rev-parse --verify --quiet "$head^{commit}" >/dev/null || ci_die "$CI_EXIT_PREREQ" "head commit not found: $head"
  ci_info "scanning commits $base..$head"
  "$bin" git --no-banner --redact --log-opts="$base..$head" "$repo"
  rc=$?
else
  [ -n "$target" ] || ci_usage_error "dir mode needs a path"
  [ -d "$target" ] || ci_die "$CI_EXIT_FAIL" "no such folder: $target"
  if [ -z "$config" ]; then
    top=$(git rev-parse --show-toplevel 2>/dev/null || true)
    if [ -n "$top" ] && [ -f "$top/.gitleaks.toml" ]; then config="$top/.gitleaks.toml"; fi
  fi
  ci_info "scanning folder $target"
  if [ -n "$config" ]; then
    "$bin" dir --no-banner --redact --config "$config" "$target"
  else
    "$bin" dir --no-banner --redact "$target"
  fi
  rc=$?
fi
set -e
if [ "$rc" -ne 0 ]; then
  ci_error "gitleaks found secrets (or failed, exit $rc). Remove the secret, rotate it, and never commit real values; fake test values belong under an allowlisted path in .gitleaks.toml."
  exit 1
fi
ci_info "ok: no secrets found"
