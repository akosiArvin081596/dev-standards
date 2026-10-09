# Fence hook tests

Table-driven tests for `plugins/team/hooks/fence` (layer 3 of the fences). The cases encode the
spec (`docs/rules.md` §13, the build spec's "Fences", the fence interface and rules briefs), not
the implementation. Every case only **feeds hook JSON** to the fence. No case command is ever run.

```
/bin/bash tests/hooks/run.sh            # all cases
/bin/bash tests/hooks/run.sh push-main  # only rows (or files) containing "push-main"
```

Exit codes: 0 all pass, 1 any failure, 2 the hook is missing or setup failed.

## What the runner does
- Creates one `mktemp -d` holding the fixture repos, a fake `HOME` and a fake `TEAM_CONFIG_DIR`.
  It's removed at exit. The real `~/.config/team` and `~/.claude` are never touched.
- Installs `tests/lib/net-guard.sh` before anything else runs. This puts fake
  `ssh scp sftp rsync …` first on `PATH`, each refusing and logging. It asserts the guard
  (a `PASS net-guard` line), puts the guard dir first on the hook's `PATH`, and fails the run
  if the hook calls any network tool.
- Runs the hook exactly as the interface says:
  `printf '%s' "$json" | env -i PATH=<guard>:/usr/bin:/bin HOME=<fake> TEAM_CONFIG_DIR=<fake> CLAUDE_PLUGIN_ROOT=plugins/team [test env] /bin/bash plugins/team/hooks/fence`
- Classifies each result:
  - **allow**: exit 0 and empty stdout.
  - **deny**: exit 0, with the deny JSON and a reason starting `[fence:<id>] `.
  - **error-deny**: exit 2, with stderr's first line starting `[fence:<id>] `.

  Anything else fails open and counts as a failure.
- For every deny or error-deny, it checks for exactly one new `fence.log` line. That line must
  have a UTC ISO-8601 timestamp, the same rule id, the agent type (or `main`), text of 300 chars
  or less, and no secret text. Secret values in the cases contain `s3cr3t`, and the check also
  greps for `gh[opusr]_…`/`github_pat_…`.
- For `TEAM_FENCE_TEST_DELAY` cases, the hook must finish within WATCHDOG+1 s. Each probe runs
  as its own process group, and nothing may be left in that group afterwards (no orphan `sleep`).
- Prints PASS/FAIL per case with its note, a summary, and the per-call median and worst time.
  Delay cases are left out of the timing.

## Case tables (`cases/*.tsv`)
Tab-separated. Lines starting with `#` are comments.

| column | values |
|---|---|
| expect | `allow`, `deny`, `error` (exit-2 error-deny), `block` (deny or error-deny, both fail closed) |
| rule | rule id, or alternatives `a\|b` where the rules make more than one id correct; `-` for allow |
| agent | `main` (no `agent_id`), or an `agent_type` such as `team:team-qa`, `general-purpose` (adds `agent_id`) |
| tool | `Bash`, `Monitor`, `Write`, `Edit`, `MultiEdit`, `NotebookEdit`, `Read`, `Glob`, `Grep`, `Agent`, `WebFetch`, or `RAW` (column 6 is fed to stdin as-is) |
| cwd | fixture name: `main-repo` (on `main`, tag `v9.9.9`), `feat-repo` (on `feat/12-login`), `wt-feat` (linked worktree of main-repo on `feat/30-wt`), `standards-repo`, `std-https`, `std-fork`, `project`, `plain`, or an absolute path |
| command/path | Bash command, file path, Agent prompt, or raw stdin |
| note | shown in the output |
| env (optional) | space-separated `K=V` for the hook, e.g. `TEAM_FENCE_TEST_FAULT=1`, `TEAM_CONFIG_DIR={CFG_EMPTY}` |

Placeholders: `{MAIN} {FEAT} {STD} {PROJ} {PLAIN} {FX}` (fixture paths), `{HOME}` (fake home),
`{CFG} {CFG_EMPTY} {CFG_NOBYPASS}` (fake config dirs: full, empty, empty `BACKGROUND_PERMISSION_MODE`),
`{PLUGIN}` (`plugins/team`), `{NL}` (newline), `{TAB}`, `{EMPTY}`, `{ECHO500}` (500 x `echo a && `).

The fixtures (repos, scripts, Makefiles, untrusted `team-gh` look-alikes, fake keys and env files)
are built by `fixtures.sh` and listed in the header of `cases/scan-messages.tsv`.

## Adding a case
Every rule id needs at least one allowed and one denied case. Pick the table for the rule and
add a row. Use `a|b` only when the rules really make both ids correct. Never weaken a case to
make the hook pass. If the hook is wrong, leave the case failing and report it.

`FENCE_HOOK=/path/to/other-hook` runs the suite against another file. It exists only for testing
the runner itself.
