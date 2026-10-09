---
paths:
  - "plugins/team/bin/**"
  - "plugins/team/lib/**"
  - "tests/commands/**"
---
# Mac commands (`team-*`)

- `#!/usr/bin/env bash`, `set -euo pipefail`, `--help`, safe to run twice, shellcheck-clean, bash 3.2 + BSD tools. Source `plugins/team/lib/team-common.sh` through the command's own path (`CLAUDE_PLUGIN_ROOT` is not set for Bash-tool commands).
- Exit codes follow `docs/rules.md` §4 (3 = not configured, 4 = refused, 5 = missing prerequisite, 6 = waiting for the owner).
- Anything that changes GitHub settings or a server prints a plan unless `--apply`.
- Never print a token or secret: pipe values on stdin (`gh secret set NAME` reads stdin). Act as the right account per command with `GH_TOKEN="$(gh auth token -u <login>)"`; never `gh auth switch`.
- Read config from `${TEAM_CONFIG_DIR:-$HOME/.config/team}`, parsed, never sourced. Tests use a fake `TEAM_CONFIG_DIR`, stub `gh`/`ssh`/`security`, and throwaway containers, never real servers or the owner's databases.
- Drop only databases recorded in `databases.registry`; stop only PIDs you recorded, after checking their cwd; never `pkill`/`killall`.
