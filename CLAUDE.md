# dev-standards

<!-- Lean on purpose: facts every session needs. Procedures live in skills, reasons in docs/. Budget: 150 lines. -->

The team workflow pack: a Claude Code plugin marketplace with one plugin, `team`, plus the reusable GitHub Actions workflows projects call and the scripts for GitHub settings, servers and databases. Language- and framework-neutral: nothing here may assume a project's programming language.

- Owner timezone: Asia/Manila. Store and log times in UTC.
- Public repo: no secrets, tokens, IPs, SSH aliases, login users or domains in any file. Machine values live in `~/.config/team/` on the owner's Mac.

## Repo map
- `.claude-plugin/marketplace.json` — this repo is the `dev-standards` marketplace.
- `plugins/team/` — the plugin: `skills/`, `agents/`, `hooks/` (the `fence`), `bin/` (Mac `team-*` commands), `lib/`, `server/` (VPS scripts).
- `managed/` — files every project receives unchanged via `team-sync` (here they're ordinary files).
- `.github/workflows/` — reusable `ci`, `pr-gates`, `pipeline`, `rollback`, `uptime`; this repo's `self-test`, `gates`, `release`.
- `scripts/ci/` — helpers the workflows run. `config/` — required checks, labels, guarded globs, test markers, PII patterns, tool versions.
- `tests/` — `hooks/`, `commands/`, `ci/`, `server/` (containers), `fixture-project/`.
- `docs/` — `docs/rules.md` (the contract: names, paths, config keys, exit codes), `docs/platform-notes.md`, `docs/limitations.md`, `docs/agent-account.md`.

## Commands
- `bash tests/hooks/run.sh`, `bash tests/ci/run.sh`, `bash tests/commands/local/run.sh`, `bash tests/commands/github/run.sh`, `bash tests/server/run.sh` (Docker).
- `shellcheck` every shell file; `actionlint` every workflow; `claude plugin validate .` and `claude plugin validate ./plugins/team`.

## Gotchas
- Mac scripts (hooks, `bin/`, `lib/`, `scripts/ci/`, tests) must run on `/bin/bash` 3.2 with BSD tools; Makefiles on GNU Make 3.81. The banned constructs are listed in `docs/rules.md`.
- Change `docs/rules.md` before changing an interface, and keep `config/required-checks.json` in step with real check names.
- Every path in this repo is guarded: each PR needs the owner's `owner-approved`.
- Changes that need new managed files are a new major version.
- Never weaken a test to make it pass.

New lessons go in the PR report's `Lessons:` line; `/team:tidy-context` routes them. A blocked action means stop and ask the owner, never work around it.
