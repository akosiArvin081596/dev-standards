# Platform notes

What the current platforms actually do, as researched and tested for this pack. Where these notes and the original build spec disagree, the platform wins and the difference is listed at the end. Researched 2026-10-09 against **Claude Code 2.1.295** and docs.github.com / the GitHub REST OpenAPI of 2026-10-07.

Sources are the official docs: `code.claude.com/docs/en/<page>` (cited as `cc:<page>`) and `docs.github.com` (cited as `gh:<path>`). "Observed" means a probe on this machine (Phase 1/4).

## 1. Plugin basics

| Question | Answer | Source |
|---|---|---|
| Marketplace format | `.claude-plugin/marketplace.json` at the repo root: `name`, `owner.name`, `plugins[]` with `name` + `source`. A relative source starts with `./`, resolves from the repo root, no `..`. | cc:plugins/marketplace-reference |
| Plugin manifest | `plugins/team/.claude-plugin/plugin.json`; only `name` is required, but `validate --strict` fails without `version`, `description`, `author`. Components live at the plugin root: `skills/<n>/SKILL.md`, `agents/*.md`, `hooks/hooks.json`, `bin/`. | cc:plugins/manifest-reference |
| Naming | Skills `/team:<skill>`; agents `team:<agent>`. Observed: `subagent_type: "probe:probe-agent"` works, and the hook sees `agent_type: "probe:probe-agent"`. | cc:skills, observed |
| `bin/` on PATH | Yes: "on the Bash tool's PATH while the plugin is enabled". Observed under `-p --plugin-dir`. | cc:plugins/manifest-reference, observed |
| Env for commands | Hooks get `CLAUDE_PLUGIN_ROOT`, `CLAUDE_PLUGIN_DATA`, `CLAUDE_PROJECT_DIR`. Commands run by the Bash tool get **none** of them (observed: `CLAUDE_PLUGIN_ROOT` unset, `CLAUDECODE=1` set). Skill/agent Markdown may use `${CLAUDE_PLUGIN_ROOT}` (substituted on load). | cc:plugins/manifest-reference, observed |
| Permission rules from a plugin | Impossible: a plugin's `settings.json` honours only `agent` and `subagentStatusLine`. Rules live in each project's `.claude/settings.json`. | cc:plugins/manifest-reference |
| `claude plugin validate` | `claude plugin validate <path> [--strict] [--json]`; exit 0 pass, 1 errors (or warnings with `--strict`), 2 validator error. A marketplace run doesn't open plugin component files, so validate `plugins/team` too. Login: not documented; it works offline here. | cc:plugins/cli-reference, observed |

## 2. Project-scope enabling

- Committed `.claude/settings.json`: `extraKnownMarketplaces.dev-standards.source = {source: "github", repo: "akosiArvin081596/dev-standards", ref: "v1"}` and `enabledPlugins["team@dev-standards"] = true`. (cc:plugins/marketplace-reference, cc:settings-reference)
- First run on a machine: (1) the folder must be trusted — `extraKnownMarketplaces`, `allow` and `env` apply only after trust, while `deny`/`ask` apply at once; (2) the marketplace is cloned in the background; (3) **the plugin is not downloaded by the setting alone** — run once `claude plugin install team@dev-standards --scope project` (or `/plugin`), then `/reload-plugins`. (cc:plugins/install, cc:plugins/loading)
- Auto-update: off by default for third-party marketplaces; toggled per marketplace in `/plugin` → Marketplaces. **Recommendation: keep it off.** The fence runs in bypass mode, so hook changes should arrive deliberately: `claude plugin marketplace update dev-standards` then `claude plugin update team@dev-standards`, then restart or `/reload-plugins`. (cc:plugins/loading)
- Cache: `cache/<marketplace>/<plugin>/<version>/`. With `version` in `plugin.json` that string pins the cache, so a moved `v1` tag is ignored unless the version changes. The pack keeps `version` and `release.yml` bumps it on every release (release-please `extra-files`), so every move of `v1` carries a new version. (cc:plugins/loading)
- `claude -p`: installed project plugins load; `--plugin-dir` works under `-p` and loads hooks and `bin/` (observed). `-p` runs project hooks even in an untrusted folder; `--bare` skips plugins, hooks and CLAUDE.md. (cc:headless, observed)

## 3. Hooks

- PreToolUse input: `session_id`, `transcript_path`, `cwd`, `permission_mode`, `hook_event_name`, `tool_name`, `tool_input`, `tool_use_id`; `agent_id` only inside subagents; `agent_type` inside subagents (plugin agents: `team:<agent>`, observed). The hook also sees the `Agent` tool call itself. (cc:hooks, observed)
- Deny: JSON `hookSpecificOutput.permissionDecision: "deny"` with exit 0, or exit 2 with the reason on stderr. Several hooks combine as deny > defer > ask > allow; a hook's allow never overrides a deny/ask rule. (cc:hooks)
- **Hook deny holds in `bypassPermissions`** — not stated in the docs, observed: the denied call appears in `result.permission_denials`.
- **Fail-open cases:** exit codes other than 0/2 without JSON, a timeout ("doesn't block the tool call"), or a missing/non-executable script let the call through. The fence therefore converts every internal error to exit 2 with a trap, runs an 8 s internal watchdog under its 15 s hook timeout, and layer 1 deny rules stay the guaranteed block. (cc:hooks)
- Matchers: only `[A-Za-z0-9_\- ,|]` is an exact-name list; anything else is an unanchored regex. The fence uses `*`. Hooks fire for subagent tool calls. (cc:hooks)
- SessionStart: `additionalContext` (or plain stdout) reaches Claude; `systemMessage` warns the user. No env var tells a project hook whether a plugin is enabled, and `claude plugin list --json` would be a nested Claude process, so `.claude/hooks/plugin-check` reads `~/.claude/plugins/installed_plugins.json` (v2, `plugins` key) and the `enabledPlugins` values across user < project < local settings. (cc:hooks, cc:plugins/loading)
- `!` (bash mode) commands: whether hooks or permission rules apply is **not documented** — checked by hand (see the build report).

## 4. Permission rules

- Bash: `Bash(git push *)` (space-star; `:*` only at the end means the same). `*` matches across spaces. `Bash(ls *)` matches `ls` and `ls -la`, not `lsof`. (cc:permissions)
- Compound commands are split on `&& || ; | |& &` and newlines; deny/ask match if ANY subcommand matches, including inside `( )`, `$( )`, backticks and loop bodies. Deny/ask match past any leading `VAR=value`. Stripped wrappers: `timeout time nice nohup stdbuf command builtin noglob` and bare `xargs`. **Not matched by deny rules:** `env …`, `bash -c '…'`, `git -C . push`, `git -c k=v push`, quoted words (`git 'push'`), absolute paths (`/usr/bin/git`). The fence covers all of these. (cc:permissions)
- Paths: `//abs`, `~/…`, `/…` (relative to the settings file's project root), bare/`./` (cwd). In deny/ask a bare name or single segment matches at any depth. Read/Edit deny rules also cover Grep/Glob (best effort), `@file`, Bash `cat head tail sed tee` and redirect targets — not scripts that open files themselves. **`Write(…)`, `MultiEdit(…)`, `NotebookEdit(…)` and `Glob(…)` path rules are never consulted**: every write fence uses `Edit(…)`. (cc:permissions)
- MCP: `mcp__server`, `mcp__server__*`, `mcp__server__tool`. (cc:permissions)
- Order deny → ask → allow. In bypass, writes to protected paths (`.git`, `.claude`, `.mcp.json`, …) are **allowed**, which is why the fences protect their own files. Still prompting/denied in bypass: explicit ask rules, `AskUserQuestion`, critical-path `rm` (a `"${DIR:?}"` guard passes), and Bash reads outside the working directories when `blockReadsOutsideWorkingDirectories` is on. (cc:permission-modes)
- `-p` + bypass + ask rule → denied (no host to ask), listed in `permission_denials` — observed in the ask-rule probe, so **ask rules are the active "my yes" path**. `--permission-prompts none` exists for unattended runs. (cc:headless, observed)
- `defaultMode` is documented both top-level and as `permissions.defaultMode`; the pack sets neither. `autoMemoryEnabled` is a top-level key; `claudeMdExcludes` takes absolute-path globs. (cc:permission-modes, cc:settings-reference, cc:memory)

## 5. Worktrees

- `claude --worktree <name>` → `<repo>/.claude/worktrees/<name>/` on branch `worktree-<name>`; `isolation: worktree` subagents use the same folder with temporary worktrees. (cc:worktrees)
- A `WorktreeCreate` hook replaces git's behaviour for `--worktree`, `isolation: worktree` and background-session isolation; it gets only a `name` and must create the branch itself. The pack doesn't use it: `team-new-worktree` creates worktrees with the pack's branch names, ports, env file and database, and background sessions start inside them. (cc:hooks)
- **Memory inside `.claude/worktrees/<name>` (observed):** a session there loaded only that worktree's `CLAUDE.md` and always-on rule, not the main checkout's. Decision: pack worktrees live at `.claude/worktrees/<issue>-<slug>`; no `claudeMdExcludes`, no sibling folder. Project settings come from the worktree's own `.claude/settings.json`; `settings.local.json` from the main checkout. (cc:memory, cc:worktrees, observed)
- `worktree.baseRef`, `worktree.symlinkDirectories`, `worktree.sparsePaths`, `worktree.bgIsolation`; `.worktreeinclude` copies gitignored files into Claude-made worktrees (the pack's `.worktreeinclude` names the env file). (cc:settings-reference)

## 6. Subagents, background sessions and fan-out

- Plugin agents may use `tools`, `disallowedTools`, `model`, `effort`, `isolation`, `background`, `skills`, `memory`, `maxTurns`, `color`; `hooks`, `mcpServers`, `permissionMode`, `initialPrompt` are ignored. `tools: mcp__playwright` grants the project's Playwright MCP tools; team-qa runs in the foreground (background subagents have a smaller tool set). Nesting: 3 levels by default; 20 concurrent subagents. Review agents disallow `Agent`. (cc:sub-agents)
- Background sessions: `claude --bg [--name N] [--permission-mode M] "<prompt>"`; status via `claude agents --json --all` (states working/blocked/done/failed/stopped), `claude logs <id>`, `claude stop`, `claude rm` (keeps dirty sessions). A session starts the way a new session in that folder would; project settings can't grant bypass; `--permission-mode bypassPermissions` needs the bypass disclaimer accepted once (`skipDangerousModePermissionPrompt: true` is set on this Mac). (cc:agent-view, cc:cli-reference)
- **Trust (observed):** `claude --bg` in an untrusted folder exits "Workspace not trusted". Trust is not inherited from a trusted parent folder, but a worktree inherits it from its repo's main checkout.
- **Isolation:** background sessions move into their own worktree before editing unless `worktree.bgIsolation: "none"`. The managed settings set `"none"`, because `/team:start-issue` always starts them inside a pack worktree.
- **Fan-out decision for `/team:start-issue`:** background sessions, one per pack worktree: `cd <worktree> && claude --bg --name <n>-<slug> --permission-mode bypassPermissions "<prompt>"` (the flag only when `BACKGROUND_PERMISSION_MODE` is set; this Mac's sessions get bypass from a launch flag). Reviewers and QA run as foreground subagents from `/team:ship`.

## 7. GitHub

- Check names: `<caller job> / <called job>` (a `name:` replaces the id). So `ci / ci`, `gates / guarded-paths`, `gates / pr-title`. A caller job skipped by `if:` reports only `<caller job>` (skipped), so `X / Y` stays "Expected"; a workflow skipped by `paths:` stays pending. GitHub Actions app id **15368**; a check can only be bound to it after the app has reported in that repo. (gh:repositories/…/managing-rulesets/troubleshooting-rules, observed on public repos)
- Rulesets: branch ruleset with `RepositoryRole` 5 (admin) in `pull_request` bypass mode (merge via PR only, no direct push); tag ruleset `refs/tags/v*` needs `always` (pull_request mode is branch-only). Enforced on public repos on Free; unavailable on private Free repos (as are environments, required reviewers, secret scanning and code scanning). (gh:rest/repos/rules, gh:…/about-rulesets)
- Settings endpoints (all need only the classic `repo` scope): see `team-bootstrap-repo --help`. CodeQL counts GitHub Actions workflows as a language, so default setup applies to every pack repo. Immutable releases lock a published release's tag; `v1` has no release, so it stays movable. `sha_pinning_required` still allows reusable workflows by tag (`@v1`). Collaborator `permission` is ignored on personal repos (always write; the invite must be accepted). (gh:rest, gh:…/managing-github-actions-settings-for-a-repository)
- Reusable workflows: the environment key goes on the called job; callers pass `secrets: inherit`. **New (2026-04):** `job.workflow_repository` / `job.workflow_sha` let a called workflow check out its own repo at the exact commit the caller pinned — the pack's default standards ref. A public caller can call public workflows across accounts. Limits: 10 nesting levels, 50 reusable workflows per file. (gh:actions/reference/workflows-and-actions/contexts#job-context)
- release-please: action v5.0.0 (release-please 17.x). Manifest mode with `simple`, committed `version.txt`, `bump-minor-pre-major`, and **`initial-version: "0.1.0"`** (a manifest `0.0.0` alone gives 1.0.0). It never touches `v1`; the pack moves it with git after a release. Needs a PAT (`RELEASE_PLEASE_TOKEN`): the default token's PRs don't run CI and can't create protected tags. (googleapis/release-please-action README, release-please source)
- gitleaks 8.30.1 linux x64 SHA-256 `551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb`; `gitleaks git --log-opts="<base>..<head>"`, `gitleaks dir`; allowlists use `[[allowlists]]` (v8.25+). Semgrep CE: `semgrep scan` (not `semgrep ci`) with `--config p/default --metrics=off --baseline-commit`; `p/default` works without login. (gitleaks README v8.30.1, docs.semgrep.dev)
- Runners: `ubuntu-latest` moves to 26.04 between 2026-10-19 and 2026-11-19; the pack pins `ubuntu-24.04`. (actions/runner-images #14748)
- Dependabot: `cooldown.default-days: 7` (GitHub now applies 3 days by default); `commit-message: {prefix: chore, include: scope}` → `chore(deps): …`; Dependabot PR runs get a read-only token and no Actions secrets, but job `permissions:` can raise it, so labelling works; only fork PRs stay read-only. (gh:code-security/reference/supply-chain-security/dependabot-options-reference)
- Label events: `GET /repos/{o}/{r}/issues/{n}/events` (oldest first; `event`, `actor.login`, `label.name`), readable with the default token. User-posted commit statuses satisfy "any source" required checks. (gh:rest/issues/events, gh:…/available-rules-for-rulesets)

## 8. Weekly health check (Max plan, no API key)

| Option | Fit |
|---|---|
| Cloud routine (claude.ai) | Pro/Max; research preview; runs as you through the GitHub app; creating issues isn't documented; the project's plugin and fences aren't guaranteed in the cloud environment. |
| **Desktop scheduled task (local routine)** | Runs `/team:health-check` in the project folder on this Mac with the project's plugin, fences and `team-gh`; no token stored anywhere new; runs while the Desktop app is open and the Mac is awake, with one catch-up run within 7 days. |
| GitHub Action + `CLAUDE_CODE_OAUTH_TOKEN` | Documented issue writes, but it stores a long-lived subscription token as a secret in a **public** repo whose same-repo PRs get secrets, needs the plugin loaded in CI, and GitHub disables the schedule after 60 days without activity. |

**Recommendation: the Desktop local routine** — weekly, in each project folder, prompt `/team:health-check`, permission mode bypass (as the owner's sessions run), default model. Not created by this build.

## Where the platform changed the spec

1. **Plugin install is a per-machine step.** Committed `enabledPlugins` doesn't download the plugin; each machine runs `claude plugin install team@dev-standards --scope project` once after trusting the folder.
2. **Hooks fail open on timeout, odd exit codes or a missing script.** The fence adds a trap (exit 2) and an internal 8 s watchdog under its 15 s timeout; layer 1 deny rules remain the guaranteed block. Hook deny in bypass isn't documented but is observed to work.
3. **Commands don't get `CLAUDE_PLUGIN_ROOT`.** `bin/` commands locate the plugin from their own path.
4. **`plugin.json` `version` pins the cache.** release-please bumps it on every release so a moved `v1` is picked up; auto-update stays off.
5. **Agent types are namespaced:** `team:team-reviewer`, `team:team-security`, `team:team-qa`, `team:team-health`.
6. **`Write(…)` permission rules are ignored;** write fences use `Edit(…)`.
7. **Deny rules miss `env`, `bash -c`, `git -C`, `git -c`, quoted words and absolute paths;** the fence covers them.
8. **Protected paths are writable in bypass;** the fence and `Edit(…)` deny rules protect `.claude/`, `.git/` and `.mcp.json`.
9. **Worktree memory:** sessions in `.claude/worktrees/<name>` load only the worktree's own context files, so the default folder is kept with no exclusions.
10. **Background sessions need folder trust** (inherited from the main checkout) and the bypass disclaimer, and isolate themselves unless `worktree.bgIsolation: "none"`, which the managed settings set. No `WorktreeCreate` hook is used.
11. **Background subagents can surface permission prompts** in the main session (the spec says subagents can't ask). The skills still treat every subagent and background writer as unable to ask.
12. **Required check names are `caller / called`:** `ci / ci`, `gates / guarded-paths`, `gates / pr-title` (plus `self-test` and `template-ci`).
13. **Standards ref defaults to `job.workflow_sha`** (the commit the caller pinned, e.g. `@v1`) instead of a hardcoded major tag; `gates.yml` and `self-test.yml` still override it.
14. **release-please needs `initial-version: "0.1.0"`** and a committed `version.txt`.
15. **Dependabot PR runs can label PRs** when the job asks for write permissions; only fork PRs are read-only. GitHub also adds a 3-day default cooldown (the pack sets 7).
16. **A personal repo can't limit a collaborator's permission,** and the agent account must accept its invite (`docs/agent-account.md`).
17. **`gates.yml` with base-commit scripts protects the scripts, not the workflow YAML,** which `pull_request` takes from the PR; the backstop is `team-security` holding `ai-security` pending on gate changes until `owner-approved`.
18. **`!` bash-mode commands:** not documented whether rules/hooks apply — a one-minute manual check is in the build report.
