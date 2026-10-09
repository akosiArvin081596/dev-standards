#!/usr/bin/env bash
# shellcheck disable=SC2016  # the single-quoted snippets run in child shells with "$1"...
# Proves the network guard works: every fake is first on PATH, logs, refuses, git's ssh goes
# through it, simulators still log, and no pack command or test calls a network tool by
# absolute path (which would bypass PATH). Run: /bin/bash tests/lib/net-guard-test.sh
set -uo pipefail
export LC_ALL=C
REPO=$(cd "$(dirname "$0")/../.." && pwd)
. "$REPO/tests/lib/net-guard.sh"
TMP=$(mktemp -d)
trap 'rm -rf "${TMP:?}"' EXIT
pass=0 fail=0
check() { local name="$1"; shift; if "$@"; then echo "PASS  $name"; pass=$((pass + 1)); else echo "FAIL  $name"; fail=$((fail + 1)); fi; }

mkdir -p "$TMP/cfg" "$TMP/home"
export TEAM_CONFIG_DIR="$TMP/cfg" HOME="$TMP/home"
check "assert fails before install" bash -c '. "$1/tests/lib/net-guard.sh"; ! net_guard_assert 2>/dev/null' _ "$REPO"
net_guard_install "$TMP/guard"
check "assert passes after install" net_guard_assert
for t in $NET_GUARD_TOOLS; do
  check "$t resolves to the fake" test "$(command -v "$t")" = "$TMP/guard/$t"
done
refused() { local rc=0; "$@" >/dev/null 2>&1 || rc=$?; [ "$rc" = 255 ]; }
check "ssh to an alias is refused" refused ssh vps uptime
check "ssh by IP is refused" refused ssh 192.0.2.10 true
check "scp is refused" refused scp a vps:/tmp/a
check "sftp is refused" refused sftp vps
check "rsync over ssh is refused" refused rsync -e ssh a vps:/tmp/a
check "every call was logged" test "$(grep -c . "$NET_GUARD_LOG")" -ge 6
check "log names the exact command" grep -q "ssh	vps uptime" "$NET_GUARD_LOG"
check "git uses the fake ssh" bash -c '! git ls-remote ssh://git@example.invalid/x.git >/dev/null 2>&1 && grep -q "example.invalid" "$1"' _ "$NET_GUARD_LOG"
mkdir -p "$TMP/sim"; printf '#!/bin/bash\necho simulated "$@"\n' > "$TMP/sim/ssh"; chmod +x "$TMP/sim/ssh"
check "a simulator answers and the call is still logged" bash -c 'out=$(NET_GUARD_SIMULATOR="$1" ssh vps-test hello) && [ "$out" = "simulated vps-test hello" ] && grep -q "vps-test hello" "$2"' _ "$TMP/sim" "$NET_GUARD_LOG"
printf '#!/bin/bash\nssh nested-call\n' > "$TMP/sim/scp"; chmod +x "$TMP/sim/scp"
check "a simulator calling ssh again is refused" bash -c '! NET_GUARD_SIMULATOR="$1" scp x y 2>/dev/null' _ "$TMP/sim"
check "the owner's real config is rejected" bash -c '. "$1/tests/lib/net-guard.sh"; NET_GUARD_REAL_HOME="$2"; net_guard_install "$3/g2"; TEAM_CONFIG_DIR="$2/.config/team"; ! net_guard_assert 2>/dev/null' _ "$REPO" "$NET_GUARD_REAL_HOME" "$TMP"
abs=$(grep -rEn '(^|[^A-Za-z0-9_./-])/(usr/(local/)?bin|bin|opt/homebrew/bin)/(ssh|scp|sftp|rsync|ssh-keyscan)([^A-Za-z0-9_-]|$)' "$REPO/plugins/team/bin" "$REPO/plugins/team/lib" "$REPO/scripts" "$REPO/tests" 2>/dev/null | grep -v 'tests/lib/net-guard' || true)
check "no pack command or test calls a network tool by absolute path" test -z "$abs"
[ -z "$abs" ] || printf '%s\n' "$abs"
echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
