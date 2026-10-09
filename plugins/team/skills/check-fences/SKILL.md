---
name: check-fences
description: Check that the team-workflow fences are active in this session and this repo. Reports the permission mode, confirms the deny and ask rules and the team plugin are loaded, feeds simulated forbidden tool calls to the fence hook with team-check-fences, reads the GitHub rulesets, environments and settings back with team-verify-repo, and prints a pass/fail table. Never runs a forbidden action for real. Use after setup, after /team:sync-standards, or whenever the fences are in doubt.
---

# Check the fences

Never try a forbidden action for real: no pushes to `main`, no tags, no `owner-approved`, no VPS connection, no edits to fence files. The fence is tested only through simulated hook input.

Run every check, then print one table: check, expected, actual, PASS or FAIL.

1. **Permission mode.** Report the mode this session runs in. You know it from your own instructions; `bypassPermissions` is normal here. This is a report, not a pass or fail.
2. **Deny and ask rules.** Read `.claude/settings.json` with jq.
   - **Deny rules** (`.permissions.deny`) must include rules for:
     - force-push and pushes to `main`
     - skipping git hooks and changing the hooks path
     - tags
     - raw `gh` write subcommands (PR merge, issue create, `api` with `-X POST`, …)
     - credential reads (`gh auth token`, keychain)
     - production deploy, rollback and flags
     - nested `claude -p`
     - fence-file edits (`Edit(**/.claude/settings*.json)` or the repo-anchored `Edit(/.claude/…)` form)
     - `Edit(**/.github/workflows/**)` (outside `dev-standards`)
   - **Ask rules** (`.permissions.ask`) must include `Bash(team-gh pr edit * --add-label owner-approved)`, `Bash(ssh *)`, `Bash(team-discover *)`, `Bash(team-provision *)`, `Bash(team-flag *)`, `Bash(team-refresh-staging *)` and `Bash(team-bootstrap-repo *--apply*)`.
   - **Neither** `permissions.defaultMode` nor `defaultMode` may be set in `.claude/settings.json` or `.claude/settings.local.json`.
3. **Managed files unchanged.** Run `team-sync --check`. It must report that the managed files match `.claude/team-standards.lock`.
4. **Plugin loaded.**
   - `command -v team-check-fences` must find it: the plugin's `bin/` is on PATH only while the plugin is enabled.
   - `claude plugin list` must show `team@dev-standards` as enabled.
   - The session must not have shown the "team plugin … is OFF" warning at start.
5. **Fence hook decisions.** Run `team-check-fences` and include its table. It feeds simulated tool calls, one per forbidden action plus allowed controls, to the installed hook, and shows each decision. Every forbidden case must be `deny`, and every control must pass.
6. **Git hooks.** Run `team-hooks --check`.
7. **GitHub settings.**
   - Take `<owner>/<repo>` from `git remote get-url origin`.
   - The profile is `standards` for `dev-standards`, `template` for `project-starter`, and `project` otherwise.
   - Run `team-verify-repo <owner>/<repo> --profile <profile>` and include its table. It reads the rulesets, environments, settings, labels and variables back, and warns about disabled scheduled workflows.

Finish with an overall PASS (every check passed) or FAIL, the failing rows, and the fix for each. Some fixes are the owner's to run in their own terminal, for example `claude plugin install team@dev-standards --scope project`, or `team-bootstrap-repo <owner>/<repo> --profile <p> --apply` (a yes moment).
