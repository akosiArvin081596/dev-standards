---
name: health-check
description: Run the weekly read-only health audit of the current team-workflow repository with the team-health agent. It covers duplication, dead code, oversized files, complexity, outdated dependencies, stale flags and over-budget or contradictory context files, and files at most 5 health issues. Use weekly, or when the owner asks how healthy the codebase is.
---

# Health check

1. **Run the audit.** Run the subagent `team:team-health` in the foreground, with the prompt `Audit this repository.` and nothing else. It reads the code and the context files, runs `make audit`, and opens at most 5 deduplicated issues labelled `health`.
2. **Show the owner** its findings table, the issues it opened (with links: `team-gh issue list --label health --state open --json number,title,url`), the duplicates it skipped, and any command that was denied or not configured.
3. **Context-file findings** are fixed in one batch by `/team:tidy-context`, not one by one. Findings in `.claude/rules/team/` belong to dev-standards: the owner raises them in the standards chat.
4. **Suggest the deeper check.** If the owner's Claude Code `/doctor` offers `prompt-audit`, suggest they run `/doctor prompt-audit` themselves, to check the context files' instructions in depth. It's a built-in command, so this session can't run it.

To start new work from the issues it filed, the owner runs `/team:start-issue <n>…`.
