#!/usr/bin/env bash
# tests/server/run.sh — test the server scripts (plugins/team/server/).
# 1. On this machine: shellcheck + bash -n on every server script, the one-open-item rule, and a scan
#    for infrastructure details. 2. In a throwaway container per Ubuntu LTS base (24.04 and 26.04 by
#    default): tests/server/in-container.sh.
# Run on the Mac with: /bin/bash tests/server/run.sh   (bash 3.2 + BSD tools; never touches a real server)
set -euo pipefail
export LC_ALL=C   # bash 3.2 in some locales (e.g. en_PH.UTF-8) lets [a-z] match capitals

usage() {
  cat <<'EOF'
Usage: tests/server/run.sh [--base ubuntu:24.04|ubuntu:26.04]... [--keep-image] [--static-only]

  --base IMAGE   Ubuntu base to test on (repeatable). Default: ubuntu:24.04, then ubuntu:26.04
                 (26.04 brings sudo-rs, Rust coreutils, PostgreSQL 18, MariaDB 11.8, PHP 8.5).
  --keep-image   keep the team-srvtest-img-<version> images afterwards (faster re-runs)
  --static-only  only shellcheck / bash -n / open-item / infrastructure scan; no Docker

For each base: builds team-srvtest-img-<version> from tests/server/Dockerfile, runs container
team-srvtest-run-<pid>-<version>, copies the server scripts, the tests and tests/lib (net-guard) in,
runs in-container.sh, and removes the container (and the image unless --keep-image) on exit, even
on failure. Only team-srvtest-* names are ever touched; Colima is never started or stopped.
Exit codes: 0 all passed, 1 a check failed, 2 usage, 5 Docker/shellcheck missing.
EOF
}

KEEP_IMAGE=0 STATIC_ONLY=0 BASES=""
while [ $# -gt 0 ]; do
  case $1 in
    -h|--help) usage; exit 0 ;;
    --keep-image) KEEP_IMAGE=1; shift ;;
    --static-only) STATIC_ONLY=1; shift ;;
    --base)
      [ $# -ge 2 ] || { echo "run.sh: --base needs an image (see --help)" >&2; exit 2; }
      case $2 in
        ubuntu:[0-9][0-9].[0-9][0-9]) BASES="$BASES $2" ;;
        *) printf 'run.sh: --base must be ubuntu:YY.MM (got %s)\n' "$2" >&2; exit 2 ;;
      esac
      shift 2 ;;
    *) printf 'run.sh: unknown argument %s (see --help)\n' "$1" >&2; exit 2 ;;
  esac
done
[ -n "$BASES" ] || BASES="ubuntu:24.04 ubuntu:26.04"

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
SERVER=$ROOT/plugins/team/server
CREATED_CTRS="" CREATED_IMGS=""
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
  # from the repo root, as the self-test runs it
  if (cd "$ROOT" && shellcheck -x "plugins/team/server/$f" >/dev/null 2>&1); then pass "shellcheck $f (from the repo root)"
  else fail "shellcheck $f (from the repo root)"; (cd "$ROOT" && shellcheck -x "plugins/team/server/$f" 2>&1 | head -n 20 | sed 's/^/      | /'); fi
  if /bin/bash -n "$SERVER/$f" 2>/dev/null; then pass "bash -n $f"; else fail "bash -n $f"; fi
done
for f in run.sh in-container.sh helpers.sh; do
  if (cd "$ROOT" && shellcheck -x "tests/server/$f" >/dev/null 2>&1); then pass "shellcheck tests/server/$f (from the repo root)"
  else fail "shellcheck tests/server/$f (from the repo root)"; (cd "$ROOT" && shellcheck -x "tests/server/$f" 2>&1 | head -n 20 | sed 's/^/      | /'); fi
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
  for c in $CREATED_CTRS; do docker rm -f "$c" >/dev/null 2>&1 || true; done
  if [ "$KEEP_IMAGE" = 0 ]; then for i in $CREATED_IMGS; do docker rmi "$i" >/dev/null 2>&1 || true; done; fi
  exit "$rc"
}
trap cleanup EXIT INT TERM

RESULTS="" ALL_OK=1
for base in $BASES; do
  ver=$(printf '%s' "${base#ubuntu:}" | tr -d '.')
  IMG=team-srvtest-img-$ver
  CTR=team-srvtest-run-$$-$ver
  t0=$(date +%s)
  printf '\n=== container tests on %s (%s)\n' "$base" "$CTR"
  printf 'building %s …\n' "$IMG"
  CREATED_IMGS="$CREATED_IMGS $IMG"
  if ! docker build -q --build-arg "BASE=$base" -t "$IMG" "$HERE" >/dev/null; then
    fail "docker build $IMG"; ALL_OK=0; RESULTS="$RESULTS
$base: image build FAILED"; continue
  fi
  CREATED_CTRS="$CREATED_CTRS $CTR"
  docker run -d --name "$CTR" "$IMG" sleep infinity >/dev/null
  docker exec "$CTR" mkdir -p /src
  docker cp "$SERVER" "$CTR:/src/server" >/dev/null
  docker cp "$HERE" "$CTR:/src/tests" >/dev/null
  docker cp "$ROOT/tests/lib" "$CTR:/src/tests-lib" >/dev/null
  set +e
  docker exec "$CTR" bash /src/tests/in-container.sh | tee "$GUARD_TMP/suite-$ver.log"
  crc=${PIPESTATUS[0]}
  set -e
  docker rm -f "$CTR" >/dev/null 2>&1 || true
  line=$(grep '^container suite:' "$GUARD_TMP/suite-$ver.log" | tail -n 1)
  if [ "$crc" = 0 ]; then RESULTS="$RESULTS
$base: PASSED · ${line#container suite: } · $(( $(date +%s) - t0 ))s with the image build"
  else ALL_OK=0; RESULTS="$RESULTS
$base: FAILED (exit $crc) · ${line#container suite: }"; fi
done

printf '\n=== summary\n'
printf 'host static checks: %d passed, %d failed\n' "$PASS" "$FAIL"
printf '%s\n' "$RESULTS" | sed '/^$/d'
printf 'runtime: %ss\n' "$(( $(date +%s) - START ))"
[ "$FAIL" = 0 ] && [ "$ALL_OK" = 1 ]
