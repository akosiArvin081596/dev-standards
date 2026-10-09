#!/usr/bin/env bash
# tests/server/run.sh — test the server scripts (plugins/team/server/).
# 1. On this machine: shellcheck + bash -n on every server script, the one-open-item rule, and a scan
#    for infrastructure details. 2. In a throwaway Ubuntu 24.04 container: tests/server/in-container.sh.
# Run on the Mac with: /bin/bash tests/server/run.sh   (bash 3.2 + BSD tools; never touches a real server)
set -euo pipefail
export LC_ALL=C   # bash 3.2 in some locales (e.g. en_PH.UTF-8) lets [a-z] match capitals

usage() {
  cat <<'EOF'
Usage: tests/server/run.sh [--keep-image] [--static-only]

  --keep-image   keep the team-srvtest-img image afterwards (faster re-runs); default removes it
  --static-only  only shellcheck / bash -n / open-item / infrastructure scan; no Docker

Builds image team-srvtest-img from tests/server/Dockerfile, runs container team-srvtest-run-<pid>,
copies the server scripts and tests in, runs in-container.sh, and removes the container (and the
image unless --keep-image) on exit, even on failure. Only team-srvtest-* names are ever touched.
Exit codes: 0 all passed, 1 a check failed, 2 usage, 5 Docker/shellcheck missing.
EOF
}

KEEP_IMAGE=0 STATIC_ONLY=0
for a in "$@"; do
  case $a in
    -h|--help) usage; exit 0 ;;
    --keep-image) KEEP_IMAGE=1 ;;
    --static-only) STATIC_ONLY=1 ;;
    *) printf 'run.sh: unknown argument %s (see --help)\n' "$a" >&2; exit 2 ;;
  esac
done

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
SERVER=$ROOT/plugins/team/server
IMG=team-srvtest-img
CTR=team-srvtest-run-$$
START=$(date +%s)
PASS=0 FAIL=0

# Network guard (tests/lib/net-guard.sh): this runner only drives Docker, but fake
# ssh/scp/sftp/rsync go first on PATH anyway (logging and refusing) with a fake pack config.
GUARD_TMP=$(mktemp -d)
trap 'rm -rf "${GUARD_TMP:?}"' EXIT
# shellcheck source=SCRIPTDIR/../lib/net-guard.sh
. "$ROOT/tests/lib/net-guard.sh"
export TEAM_CONFIG_DIR="$GUARD_TMP/config"
mkdir -p "$TEAM_CONFIG_DIR"
net_guard_install "$GUARD_TMP/net-guard"
if ! net_guard_assert; then echo "net-guard is not in place; refusing to run any test" >&2; exit 1; fi

pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }

command -v shellcheck >/dev/null 2>&1 || { echo "run.sh: shellcheck is not installed (brew install shellcheck)" >&2; exit 5; }

printf '=== static checks (host)\n'
SCRIPTS="discover provision deploy-receive snapshot serve-snapshot refresh-staging backup flag lib.sh"
for f in $SCRIPTS; do
  [ -f "$SERVER/$f" ] || { fail "server script present: $f"; continue; }
  if (cd "$SERVER" && shellcheck -x -s bash "$f" >/dev/null 2>&1); then pass "shellcheck $f"
  else fail "shellcheck $f"; (cd "$SERVER" && shellcheck -x -s bash "$f" 2>&1 | head -n 20 | sed 's/^/      | /'); fi
  if /bin/bash -n "$SERVER/$f" 2>/dev/null; then pass "bash -n $f"; else fail "bash -n $f"; fi
done
for f in run.sh in-container.sh helpers.sh; do
  if (cd "$HERE" && shellcheck -x -s bash "$f" >/dev/null 2>&1); then pass "shellcheck tests/server/$f"
  else fail "shellcheck tests/server/$f"; (cd "$HERE" && shellcheck -x -s bash "$f" 2>&1 | head -n 20 | sed 's/^/      | /'); fi
done
for f in $SCRIPTS; do
  [ "$f" = lib.sh ] && continue
  if [ -x "$SERVER/$f" ]; then pass "$f is executable"; else fail "$f is executable"; fi
done
tw='T''ODO'   # spelled split so a repo-wide grep finds only the real marker
todos=$(grep -rn "$tw" "$SERVER" | grep -v "$tw(offsite-backup)" || true)
offsite=$(grep -rln "$tw(offsite-backup)" "$SERVER" || true)
if [ -z "$todos" ] && [ "$offsite" = "$SERVER/backup" ]; then pass "exactly one open-item marker (offsite-backup), in backup"
else fail "exactly one open-item marker (offsite-backup), in backup"; printf '%s\n' "$todos" | sed 's/^/      | /'; fi
# No infrastructure details: the only IPv4 addresses allowed are loopback, 0.0.0.0 and TEST-NET.
ips=$(grep -rhoE '([0-9]{1,3}\.){3}[0-9]{1,3}' "$SERVER" "$HERE" 2>/dev/null \
      | grep -vE '^(127\.0\.0\.1|0\.0\.0\.0|192\.0\.2\.[0-9]+|198\.51\.100\.[0-9]+|203\.0\.113\.[0-9]+)$' | sort -u || true)
if [ -z "$ips" ]; then pass "no real IP addresses in server scripts or tests"; else fail "no real IP addresses (found: $ips)"; fi
hosts=$(grep -rhoE '[A-Za-z0-9.-]+\.(dev|com|net|org|io|ph|cloud)\b' "$SERVER" "$HERE" 2>/dev/null \
        | grep -vE '(^|\.)example\.(com|net|org)$|^company-mail\.ph$|^(gmail|yahoo|outlook|hotmail|github)\.com$|^letsencrypt\.org$' | sort -u || true)
if [ -z "$hosts" ]; then pass "no real host names in server scripts or tests"; else fail "no real host names (found: $hosts)"; fi
# lib.sh's built-in PII column patterns must be an exact copy of config/pii-patterns.txt.
if [ -r "$ROOT/config/pii-patterns.txt" ]; then
  builtin_list=$(awk "/^TEAM_PII_PATTERNS_BUILTIN='/ { on = 1; sub(/^TEAM_PII_PATTERNS_BUILTIN='/, \"\") }
                      on { line = \$0; end = sub(/'\$/, \"\", line); print line; if (end) exit }" "$SERVER/lib.sh")
  config_list=$(grep -vE '^[[:space:]]*(#|$)' "$ROOT/config/pii-patterns.txt" | sed 's/[[:space:]]*$//')
  if [ "$builtin_list" = "$config_list" ]; then pass "lib.sh PII patterns match config/pii-patterns.txt"
  else fail "lib.sh PII patterns match config/pii-patterns.txt"; diff <(printf '%s\n' "$builtin_list") <(printf '%s\n' "$config_list") | sed 's/^/      | /' || true; fi
else
  pass "config/pii-patterns.txt not present yet: lib.sh's built-in list is used"
fi

if [ "$STATIC_ONLY" = 1 ]; then
  printf '\nstatic checks: %d passed, %d failed\n' "$PASS" "$FAIL"
  [ "$FAIL" = 0 ]; exit $?
fi

command -v docker >/dev/null 2>&1 || { echo "run.sh: docker is not installed" >&2; exit 5; }
docker info >/dev/null 2>&1 || { echo "run.sh: Docker is not running (start Colima; this script never starts or stops it)" >&2; exit 5; }

cleanup() {
  rc=$?
  rm -rf "${GUARD_TMP:?}"
  docker rm -f "$CTR" >/dev/null 2>&1 || true
  if [ "$KEEP_IMAGE" = 0 ]; then docker rmi "$IMG" >/dev/null 2>&1 || true; fi
  exit "$rc"
}
trap cleanup EXIT INT TERM

printf '\n=== container tests (%s)\n' "$CTR"
printf 'building %s …\n' "$IMG"
if ! docker build -q -t "$IMG" "$HERE" >/dev/null; then fail "docker build $IMG"; exit 1; fi
docker run -d --name "$CTR" "$IMG" sleep infinity >/dev/null
docker exec "$CTR" mkdir -p /src
docker cp "$SERVER" "$CTR:/src/server" >/dev/null
docker cp "$HERE" "$CTR:/src/tests" >/dev/null
set +e
docker exec "$CTR" bash /src/tests/in-container.sh
crc=$?
set -e

printf '\n=== summary\n'
printf 'host static checks: %d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$crc" = 0 ]; then printf 'container suite: passed\n'; else printf 'container suite: FAILED (exit %s)\n' "$crc"; fi
printf 'runtime: %ss\n' "$(( $(date +%s) - START ))"
[ "$FAIL" = 0 ] && [ "$crc" = 0 ]
