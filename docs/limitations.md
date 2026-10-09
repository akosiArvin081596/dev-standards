# Known limitations

What the pack can't do, and what covers the gap. Read this before relying on a fence.

## Fences only work inside Claude Code
The deny rules, ask rules and the `fence` hook apply to tool calls Claude Code makes. Commands you type in a normal terminal are not fenced. Whether commands you type with `!` in a Claude Code prompt go through the rules and hooks is not documented; the build report includes a one-minute check.

## Shared identity without the agent account
Unless you set up `docs/agent-account.md`, agents act as you on GitHub. GitHub then can't tell an agent's push, comment, status or label from yours. The fences stop agents from adding `owner-approved`, posting the wrong `ai-*` status or merging release PRs, but GitHub itself would accept those from your account. Separation between agents comes from rules, hooks and instructions, not credentials.

## Hooks can fail open
Claude Code lets a tool call through when a hook times out, exits with a code other than 0 or 2, or is missing. The fence turns internal errors into a deny (exit 2) and stops itself with a deny after 8 seconds (its hook timeout is 15), but a hook that is killed or never starts is not a deny. The `permissions.deny` rules in `.claude/settings.json` are the guaranteed layer. If the `team` plugin isn't installed or enabled, the SessionStart check warns you and tells Claude that layer 3 is off.

## The fence reads shell syntax, not intent
It parses compound commands, subshells, `bash -c`, wrappers, `git -C`, refspecs and quoting, and scans scripts, interpreter one-liners and Makefile recipes one level deep. Anything it can't read plainly while touching `git`, `gh`, `team-gh`, `ssh`, `scp`, `rsync`, `curl` or `wget` is denied with "write the command plainly". Code that opens files or network connections on its own (a compiled tool, a script two levels deep) is outside what it can see.

## A pull request can edit its own workflow files
Pull-request runs use the PR's own workflow YAML. In projects the fence keeps agents out of `.github/workflows/**`, `team-sync` is the only writer there, and every such change is guarded (needs your `owner-approved`). In dev-standards `gates.yml` runs the gate scripts from the PR's base commit, but the YAML itself still comes from the PR. The backstop everywhere is `team-security`, which keeps `ai-security` pending on any PR that changes workflows, `scripts/ci/` or gate config until your `owner-approved` is on it.

## `ai-*` statuses come from "any source"
The reviewer statuses are commit statuses that anyone with write access can post. The fence lets only `team-post-check` post them, and only from the matching agent; GitHub doesn't check who posted.

## Scheduled workflows pause after 60 days
On public repos GitHub disables scheduled workflows (`uptime.yml`) after 60 days without repository activity. `team-verify-repo` warns about disabled schedules; re-enable them in the Actions tab.

## Off-server backups: TODO
Backups are compressed, timestamped, kept with retention and restore-tested weekly (`backup --verify`), but they live on the same VPS. The off-server copy is a marked TODO (`TODO(offsite-backup)` in `plugins/team/server/backup`): set `OFFSITE_BACKUP_TARGET` in `/etc/team/backup.conf` once you choose storage, and the copy will be encrypted with `age` before upload. Until then a lost server loses its backups.

## Anonymisation checks what it can recognise
The nightly snapshot refuses to store a dump when a column whose name looks personal has no rule, or when any value still looks like a real email or Philippine mobile number. Personal data hidden in free-text columns with innocent names (a name inside `notes`) is caught only if it matches those patterns. Give free-text columns a `text` or `redact` rule.

## Private repositories on GitHub Free
Rulesets, environments, required reviewers, secret scanning and code scanning aren't available on private repos under GitHub Free. Such a project switches to the private fallback: agents merge only through `team-merge-if-green`, production deploys run from your Mac with `team-deploy production`, and CI keeps to the essentials.

## Background sessions
Writers started by `/team:start-issue` need the project folder trusted (once, interactively; worktrees inherit it) and the bypass-mode disclaimer accepted. The managed settings set `worktree.bgIsolation: "none"` because writers always start inside a pack worktree; a background session you start by hand in the main checkout would edit the main checkout.

## Plugin updates are manual
Auto-update is off for this marketplace on purpose, since the fence runs in bypass mode. After a new release, run `claude plugin marketplace update dev-standards` and `claude plugin update team@dev-standards`, then restart or `/reload-plugins`.
