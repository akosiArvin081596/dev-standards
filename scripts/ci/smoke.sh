#!/usr/bin/env bash
# smoke.sh <url>: the deployed app's health URL answers 2xx (with retries).
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
CI_SELF_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=common.sh
. "$CI_SELF_DIR/common.sh"

usage() {
  cat <<'USAGE'
Usage: smoke.sh <url> [--noindex]

Requests <url> (normally the environment's HEALTH_URL secret; it is never
printed) until it answers 2xx: SMOKE_ATTEMPTS tries (default 10),
SMOKE_DELAY seconds apart (default 6), SMOKE_TIMEOUT seconds each (default 15).
BASIC_AUTH_USER / BASIC_AUTH_PASSWORD, when set, are sent through a private
curl config file, never on the command line. --noindex also requires an
X-Robots-Tag header containing noindex (staging).
Exit 0 healthy, 1 not healthy, 2 on usage error, 3 when <url> is empty.
USAGE
}

url=""
noindex=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --noindex) noindex=1; shift ;;
    -*) ci_usage_error "unknown option: $1" ;;
    *) [ -z "$url" ] || ci_usage_error "unexpected argument"; url="$1"; [ -n "$url" ] || url=" "; shift ;;
  esac
done
url=$(ci_trim "$url")
if [ -z "$url" ]; then
  printf 'not configured: no health URL (team-provision sets the HEALTH_URL secret)\n' >&2
  exit "$CI_EXIT_NOT_CONFIGURED"
fi
attempts="${SMOKE_ATTEMPTS:-10}"
delay="${SMOKE_DELAY:-6}"
timeout="${SMOKE_TIMEOUT:-15}"
case "$attempts$delay$timeout" in *[!0-9]*) ci_usage_error "SMOKE_ATTEMPTS, SMOKE_DELAY and SMOKE_TIMEOUT are numbers" ;; esac
ci_require_cmd curl

tmp=$(ci_mktemp_dir)
trap 'rm -rf "${tmp:?}"' EXIT
conf="$tmp/curl.conf"
( umask 077; : > "$conf" )
if [ -n "${BASIC_AUTH_USER:-}" ]; then
  cred="${BASIC_AUTH_USER}:${BASIC_AUTH_PASSWORD:-}"
  cred="${cred//\\/\\\\}"
  cred="${cred//\"/\\\"}"
  printf 'user = "%s"\n' "$cred" > "$conf"
fi

i=1
while :; do
  code=$(curl -sS -K "$conf" -o /dev/null -D "$tmp/headers" -w '%{http_code}' --max-time "$timeout" -- "$url" 2>/dev/null || true)
  case "$code" in
    2??)
      if [ "$noindex" = 1 ] && ! grep -iq '^x-robots-tag:.*noindex' "$tmp/headers"; then
        ci_error "health check answered $code but without X-Robots-Tag: noindex (staging must not be indexed)"
        exit 1
      fi
      ci_info "ok: health check answered $code (attempt $i)"
      exit 0
      ;;
  esac
  ci_info "health check attempt $i/$attempts: ${code:-no answer}"
  [ "$i" -lt "$attempts" ] || break
  i=$((i + 1))
  sleep "$delay"
done
ci_error "the health check failed after $attempts attempts"
exit 1
