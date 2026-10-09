# dev-standards

The team workflow pack: everything a solo developer needs to run Claude Code agents in git worktrees as if they were a team. It is language- and framework-neutral; a project fills in its own stack in its Makefile and `ops/` files.

This repo holds:

- **A Claude Code plugin marketplace** (`dev-standards`) with one plugin, **`team`**: skills (`/team:new-project`, `/team:start-issue`, `/team:fix-bug`, `/team:build-feature`, `/team:ship`, `/team:review-pr`, `/team:report`, `/team:check-fences`, `/team:health-check`, `/team:tidy-context`, `/team:sync-standards`), four read-only review agents, the `fence` hook, and the `team-*` commands.
- **Reusable GitHub Actions workflows** every project calls `@v1`: `ci`, `pr-gates`, `pipeline`, `rollback`, `uptime`.
- **Scripts** for GitHub settings (`team-bootstrap-repo`, `team-verify-repo`), the VPS (`plugins/team/server/`) and local databases.
- **`managed/`**: the files every project receives unchanged (the always-on team rule, `.claude/settings.json` with the deny and ask rules, the SessionStart plugin check, PR and issue templates).

New projects start from the template repo [`project-starter`](https://github.com/akosiArvin081596/project-starter) through `/team:new-project`.

## How it works, in one minute

- **Trunk-based.** `main` deploys to staging on every merge; release-please cuts `vX.Y.Z` releases that deploy to production after your approval.
- **No manual code review.** A PR auto-merges once `ci / ci`, `gates / guarded-paths`, `gates / pr-title` and the reviewer statuses `ai-review`, `ai-security`, `ai-qa` are green. Changes to the safety system (`.claude/**`, `CLAUDE.md`, `.github/**`, `.githooks/**`, `Makefile`, `ops/**`, `.mcp.json`) and destructive migrations are **guarded**: they also need your `owner-approved` label.
- **Fences, in three layers.** `permissions.deny` rules (blocked in every mode, bypass included), `permissions.ask` rules for your "yes" moments, and the PreToolUse `fence` hook for everything rules can't express. See `docs/limitations.md` for what fences can't do.
- **Parallel work.** `/team:start-issue 12 13 14` gives each issue its own worktree, port, database and background writer session, after a conflict check.

## Set up a Mac (once)

1. Config lives in `~/.config/team/` (never in a repo): `accounts.conf` (your GitHub logins and SSH aliases) and `defaults.conf` (VPS alias and IP, domain pattern, default timezone and account, parallel-writer limit, `TEAM_BIN`). The formats are in `docs/rules.md` §5.
2. Store the release-please token once, in a normal terminal: `plugins/team/bin/team-store-token`.
3. Open Claude Code in a project (or this repo), accept the folder trust prompt, then install the plugin for that project once: `claude plugin install team@dev-standards --scope project` and `/reload-plugins`. The project's committed `.claude/settings.json` already declares the marketplace (pinned to `v1`) and enables the plugin.

Plugin auto-update is off on purpose (the fence runs in bypass mode). To take a new release: `claude plugin marketplace update dev-standards`, `claude plugin update team@dev-standards`, then restart or `/reload-plugins`.

## Work on this repo

- **Test plugin changes by hand** without releasing: `claude --plugin-dir ./plugins/team` from this repo (or from a scratch project). The SessionStart check recognises `--plugin-dir` sessions.
- **Run the tests:**
  ```
  /bin/bash tests/hooks/run.sh              # every fence rule, allowed and denied
  /bin/bash tests/ci/run.sh                 # CI helper scripts
  /bin/bash tests/commands/github/run.sh    # GitHub commands (stubbed gh)
  /bin/bash tests/commands/local/run.sh     # worktree/app/db commands (throwaway Postgres container)
  /bin/bash tests/server/run.sh             # server scripts in a throwaway Ubuntu container
  shellcheck … ; actionlint ; claude plugin validate . ; claude plugin validate ./plugins/team
  ```
- **Every change goes through a PR**, and every path here is guarded, so each PR waits for your `owner-approved`. `self-test.yml` runs the suites and calls `ci.yml` against `tests/fixture-project/`, so the real check names are always exercised.
- **Releases:** merging to `main` updates the release-please PR. Merging that PR (you, as admin) creates `vX.Y.Z`, and `release.yml` moves the `v1` tag to it and bumps the plugin version. Changes that need new managed files are a new major version (`v2`).

## Docs

- `docs/rules.md` — the contract: names, paths, config keys, commands, check names, labels and exit codes.
- `docs/platform-notes.md` — what Claude Code and GitHub actually do, with sources, and where that changed the original design.
- `docs/limitations.md` — known limitations and the one TODO (off-server backups).
- `docs/agent-account.md` — the optional agent machine account.
- `docs/CHANGELOG.md` — release notes (written by release-please).
