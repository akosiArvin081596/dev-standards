---
paths:
  - "plugins/team/hooks/**"
  - "tests/hooks/**"
---
# The fence hook

- `plugins/team/hooks/fence` is layer 3 of the fences. It must never fail open: internal errors and malformed input exit 2; a deny prints the JSON decision and exits 0; an allow prints nothing.
- bash 3.2 only, one `jq` call per invocation, no network. Run `git` only for push, branch and remote checks.
- Every rule id in `docs/rules.md` §13 has an allowed and a denied case in `tests/hooks/`. Add both whenever you add or change a rule; run `/bin/bash tests/hooks/run.sh`.
- Judge command words and flags, never message text: a commit message or PR body that mentions a forbidden action must pass.
- Test fixtures use fake config only (`vps-test`, TEST-NET `192.0.2.10`, `example.test`); never real infrastructure values.
- Keep the deny reasons actionable: say what to do instead.
