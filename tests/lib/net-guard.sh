# shellcheck shell=bash
# Network guard for every test runner: tests must never reach a real server.
#
#   . "$REPO/tests/lib/net-guard.sh"
#   net_guard_install "$TMP/net-guard"     # fakes first on PATH, GIT_SSH_COMMAND, log
#   net_guard_assert || exit 1             # proves the fakes are in place before any test runs
#
# The fakes (ssh scp sftp rsync ssh-keyscan sshfs autossh mosh) log every call to
# $NET_GUARD_LOG and refuse with exit 255. A runner that needs canned server answers sets
# NET_GUARD_SIMULATOR to a folder of simulator scripts (same names); the fake logs the call
# first and then hands it to the simulator, which must never connect anywhere.
# bash 3.2 compatible.

NET_GUARD_TOOLS="ssh scp sftp rsync ssh-keyscan sshfs autossh mosh"
# The owner's real home, captured when this file is sourced (before a runner fakes HOME).
NET_GUARD_REAL_HOME="${NET_GUARD_REAL_HOME:-$HOME}"

net_guard_install() {
  local dir="$1" tool
  mkdir -p "$dir"
  for tool in $NET_GUARD_TOOLS; do
    cat > "$dir/$tool" <<'FAKE'
#!/bin/bash
# net-guard fake: logs, then refuses (or hands over to a test simulator). Never connects.
name=$(basename "$0")
printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$name" "$*" >> "${NET_GUARD_LOG:-/dev/null}"
if [ -z "${NET_GUARD_ACTIVE:-}" ] && [ -n "${NET_GUARD_SIMULATOR:-}" ] && [ -x "$NET_GUARD_SIMULATOR/$name" ]; then
  NET_GUARD_ACTIVE=1 exec "$NET_GUARD_SIMULATOR/$name" "$@"
fi
echo "net-guard: refused '$name $*' (tests never connect to a server)" >&2
exit 255
FAKE
    chmod 755 "$dir/$tool"
  done
  NET_GUARD_DIR="$dir"
  NET_GUARD_LOG="$dir/calls.log"
  : > "$NET_GUARD_LOG"
  PATH="$dir:$PATH"
  GIT_SSH_COMMAND="$dir/ssh"
  export NET_GUARD_DIR NET_GUARD_LOG PATH GIT_SSH_COMMAND
}

# net_guard_assert : non-zero (with a reason) unless every fake is first on PATH and refusing,
# git's ssh goes through the fake, and the test isn't using the owner's real pack config.
net_guard_assert() {
  local tool found before after rc
  [ -n "${NET_GUARD_DIR:-}" ] || { echo "net-guard: not installed" >&2; return 1; }
  for tool in $NET_GUARD_TOOLS; do
    found=$(command -v "$tool" 2>/dev/null || true)
    [ "$found" = "$NET_GUARD_DIR/$tool" ] || { echo "net-guard: '$tool' resolves to '${found:-nothing}', not the fake" >&2; return 1; }
  done
  [ "${GIT_SSH_COMMAND:-}" = "$NET_GUARD_DIR/ssh" ] || { echo "net-guard: GIT_SSH_COMMAND is not the fake" >&2; return 1; }
  before=$(wc -l < "$NET_GUARD_LOG" | tr -d ' ')
  rc=0
  NET_GUARD_SIMULATOR='' ssh -o BatchMode=yes net-guard-selftest true 2>/dev/null || rc=$?
  after=$(wc -l < "$NET_GUARD_LOG" | tr -d ' ')
  [ "$rc" = 255 ] || { echo "net-guard: fake ssh did not refuse (exit $rc)" >&2; return 1; }
  [ "$after" -gt "$before" ] || { echo "net-guard: fake ssh did not log" >&2; return 1; }
  if [ -z "${TEAM_CONFIG_DIR:-}" ] || [ "$TEAM_CONFIG_DIR" = "$HOME/.config/team" ] || [ "$TEAM_CONFIG_DIR" = "$NET_GUARD_REAL_HOME/.config/team" ] || [ "$TEAM_CONFIG_DIR" = "/Users/$(id -un)/.config/team" ]; then
    echo "net-guard: TEAM_CONFIG_DIR must point at a fake config, not the owner's" >&2
    return 1
  fi
  return 0
}

# net_guard_calls : prints the logged calls (for assertions in tests)
net_guard_calls() { cat "$NET_GUARD_LOG"; }
