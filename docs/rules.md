# Contract: names, paths, config, commands, checks

<!-- The single source of truth every component builds against. Change it before changing an interface. -->

This file is the contract between the pack's components. If code and this file disagree, the code is wrong. Platform facts and the reasons behind some choices are in `docs/platform-notes.md`.

## 1. Names

| Thing | Value |
|---|---|
| Standards repo | `akosiArvin081596/dev-standards` (marketplace name `dev-standards`) |
| Template repo | `akosiArvin081596/project-starter` |
| Plugin | `team` → enable key `team@dev-standards`, pinned to ref `v1` |
| Skills | `/team:new-project`, `start-issue`, `fix-bug`, `build-feature`, `ship`, `review-pr`, `report`, `check-fences`, `health-check`, `tidy-context`, `sync-standards` |
| Agents (files) | `team-reviewer`, `team-security`, `team-qa`, `team-health` |
| Agents (`subagent_type` and hook `agent_type`) | `team:team-reviewer`, `team:team-security`, `team:team-qa`, `team:team-health` (observed, namespaced) |
| Commit statuses | `ai-review` (team-reviewer), `ai-security` (team-security), `ai-qa` (team-qa) |
| Caller job ids (every repo) | `ci`, `gates` (+ `self-test` in dev-standards, `template-ci` in project-starter) |
| Branches | `<type>/<issue>-<slug>`; type ∈ `feat fix chore docs refactor hotfix`; slug `[a-z0-9-]{1,40}` |
| Release-please branches | `release-please--*` (never pushed to or merged by agents) |
| Worktree folder | `<repo>/.claude/worktrees/<issue>-<slug>` |
| Worktree database | `<project_>_<issue>` (project name with `-` → `_`) |
| Server OS user | `<project>-<env>` (env ∈ `staging production`), max 32 chars |

## 2. Required checks (exact names GitHub reports)

Kept in `config/required-checks.json`. Reusable-workflow checks are named `<caller job> / <called job>`.

| Profile | GitHub Actions checks (bound to the GitHub Actions app) | Statuses (any source) |
|---|---|---|
| `project` | `ci / ci`, `gates / guarded-paths`, `gates / pr-title` | `ai-review`, `ai-security`, `ai-qa` |
| `standards` | `self-test`, `ci / ci`, `gates / guarded-paths`, `gates / pr-title` | `ai-review`, `ai-security` |
| `template` | `template-ci`, `gates / guarded-paths`, `gates / pr-title` | `ai-review`, `ai-security` |

Required workflows never use `paths:` filters. The `ci / ci` check comes from a single job named `ci` in `ci.yml`.

## 3. Labels (`config/labels.json`)

`bug`, `feature`, `client-request`, `high-risk`, `guarded`, `owner-approved`, `tests-changed`, `needs-info`, `health`, `incident`, `main-red`, `fixes-main`.

- `guarded`, `high-risk`, `tests-changed`: added by workflows only.
- `owner-approved`: counts only when the latest `labeled` event for it came from the owner login. Removed by `gates` on every new push.
- Agents may add (via `team-gh`): `needs-info`, `fixes-main`, `bug`, `feature`, `client-request`, `health`. Never `owner-approved`, and never remove `guarded`, `high-risk`, `tests-changed`, `owner-approved`.
- Owner login: repo variable `OWNER_LOGIN` (always set by `team-bootstrap-repo`: defaults.conf `OWNER_LOGIN`, else the repo owner), else `github.repository_owner`. The production environment reviewer is the same login. `owner-approved` also counts only when its latest `labeled` event is newer than the head commit's first check suite.

## 4. Exit codes (every `team-*` command, `scripts/ci/*`, server scripts, Makefile targets)

| Code | Meaning |
|---|---|
| 0 | success (a plan shown without `--apply` is success) |
| 1 | failure |
| 2 | usage error (bad or missing arguments) |
| 3 | not configured (Makefile target or config not filled in yet: "not configured: fill in for your stack"). A recipe that exits 3 makes GNU make itself exit 2 and print `*** [<target>] Error 3`; callers treat a target as not configured only when that line AND the message text are both present (a real tool exiting 3 is a failure). |
| 4 | refused by policy (release PR, forbidden subcommand, wrong agent, would reuse a foreign resource) |
| 5 | missing prerequisite (tool not installed, not in a git repo, config file missing) |
| 6 | waiting for the owner (needs `--apply` with my yes, or a manual step I must do) |
| 7 | (deploy-receive only) release not on the server: rebuild needed |

## 5. Local config (Mac): `${TEAM_CONFIG_DIR:-$HOME/.config/team}`

All config files are `KEY=value` lines (or `|` tables), **parsed, never sourced**. A value may be wrapped in double quotes. `#` starts a comment line. Unknown keys are ignored.

### `defaults.conf`
`VPS_ALIAS`, `VPS_IP`, `VPS_HOSTNAME`, `VPS_ADMIN_USER`, `VPS_FORBIDDEN_ALIASES` (space-separated), `DOMAIN`, `PRODUCTION_HOST_PATTERN` / `STAGING_HOST_PATTERN` (`{app}` placeholder), `DEFAULT_TIMEZONE`, `DEFAULT_GITHUB_ACCOUNT`, `OWNER_LOGIN`, `MAX_PARALLEL_WRITERS`, `WORKTREE_PORT_MIN`, `WORKTREE_PORT_MAX`, `BACKGROUND_PERMISSION_MODE` (empty or `bypassPermissions`), `LOCAL_PG_HOST`, `LOCAL_PG_PORT`, `TEAM_BIN`, optional `ACME_EMAIL`, optional `OFFSITE_BACKUP_TARGET`.

### `accounts.conf`
`kind|login|ssh_host_alias|git_name|git_email`, kind ∈ `account agent`. At most one `agent` line (the optional agent machine account, `AGENT_LOGIN`).

### Other files the pack writes there
| Path | Format / purpose |
|---|---|
| `projects/<project>.conf` | per-project local overrides: `PRODUCTION_HOST`, `STAGING_HOST`, `CLIENT_DOMAIN`, `LOCAL_DB_PASSWORD` (mysql/mariadb container root password, written once, 600) — never committed |
| `projects/<project>-<env>.deploy.pub`, `projects/<project>.known_hosts` | the deploy key's public half (reuse check) and the pinned VPS host key (`team-deploy`) |
| `ports.registry` | `port|worktree_path|project|created_utc` |
| `databases.registry` | `engine|host|port|name|project|worktree_path|created_utc` (the only DBs the pack may drop) |
| `locks/<name>.lock/` | `mkdir` locks (`ports`, `databases`, `worktrees`); stale after 120 s |
| `fence.log` | `utc_ts<TAB>rule_id<TAB>agent_type|main<TAB>redacted command or path` |

Local Postgres credentials come from the standard `PGUSER`/`PGPASSWORD` (default: the macOS user, no password). Caches outside it: `~/.cache/team-snapshots/<project>/` (sanitized dumps), keychain items `team-release-please-token` and `team-staging-<project>`.

## 6. Project files (in each project repo)

| Path | Owner | Purpose |
|---|---|---|
| `CLAUDE.md` | project | ≤150 lines, no `@` imports |
| `.claude/rules/team/*.md` | managed | one always-on file ≤60 lines |
| `.claude/rules/project/*.md` | project | mostly `paths:`-scoped, each ≤80 lines |
| `.claude/settings.json` | managed | plugin enable, deny/ask rules, SessionStart check, `autoMemoryEnabled: false`, `worktree.bgIsolation: "none"`, `enabledMcpjsonServers: ["playwright"]` |
| `.claude/hooks/plugin-check` | managed | SessionStart: warns when the `team` plugin isn't installed+enabled |
| `.claude/team-standards.lock` | `team-sync` | JSON: `{"standards_repo","release","files":{path: "sha256:<hex>"}}` |
| `.mcp.json` | managed by template | Playwright MCP, isolated + headless, output dir `.team/evidence` |
| `.github/workflows/{ci,gates,pipeline,rollback,uptime}.yml` | `team-sync` | thin callers pinned `@v1` |
| `.github/pull_request_template.md`, `.github/ISSUE_TEMPLATE/*` | managed | standard report; bug/feature/client-request |
| `ops/project.conf` | project | see §7 |
| `ops/services.conf` | project | `name|type|command`, type ∈ `web worker scheduler`; `web` listens on `$PORT` |
| `ops/anonymize` | project | see §8 |
| `ops/env/staging.env.tmpl`, `ops/env/production.env.tmpl` | project | server env templates (`{{KEY}}` placeholders, §11) |
| `ops/flag` | project | `ops/flag <env> <name> on|off` → `team-flag` |
| `docs/flags.md` | project | registry table `| flag | issue | created | status |`, status ∈ `active removed` |
| `.env.example` → `.env` | project | worktree env file (§9) |
| `.team/` (gitignored) | local | `evidence/<pr>/`, `app.pid`, `app.log`, `artifact/`, `playwright-profile/` |

## 7. `ops/project.conf` keys

| Key | Example | Notes |
|---|---|---|
| `PROJECT_NAME` | `sandbox-app` | `[a-z][a-z0-9-]{1,20}` |
| `GITHUB_ACCOUNT` | `akosiArvin081596` | `team-gh` acts as this login |
| `GITHUB_SSH_HOST` | `github.com` | the account's SSH alias |
| `GITHUB_REPO` | `owner/name` | |
| `VISIBILITY` | `public` / `private` | private → private fallback |
| `DB_ENGINE` | `postgres` / `mysql` / `mariadb` / `none` | |
| `WEB_MODE` | `proxy` / `php-fpm` / `static` | |
| `HEALTH_PATH` | `/health` | must return 200 without auth |
| `MIGRATE_CMD` | `make migrate` | run in the release dir with the env loaded |
| `SEED_CMD` | `make seed` | fake data for new worktrees |
| `MIGRATIONS_GLOB` | `db/migrations/**` | space-separated globs |
| `HIGH_RISK_GLOBS` | `src/auth/** src/payments/**` | adds `high-risk` |
| `PROJECT_TIMEZONE` | `Asia/Manila` | IANA |
| `LOW_TRAFFIC_HOUR` | `3` | 0–23, project timezone |
| `ENV_FILE` | `.env` | worktree env file name |
| `ARTIFACT_DIR` | `.team/artifact` | `make build` fills it with exactly the release |
| `SHARED_PATHS` | `storage` | release paths symlinked to `shared/` on the server |
| `STATIC_ROOT` | `public` | web root inside the release (static, php-fpm) |
| `LOCAL_DB_IMAGE` | `mysql:8.4` | mysql/mariadb worktree container image |
| `LOCAL_DB_PORT` | `5440` | mysql/mariadb container host port |

## 8. `ops/anonymize` format

One directive per line, `|`-separated, `#` comments:
```
rule|<table>|<column>|<strategy>[|<arg>]
ignore|<table>|<column>|<reason>
devlogin|<table>|<key column>|<key value>|<col>=<value>[;<col>=<value>]
```
Strategies (deterministic: same input → same output, salted per project on the server): `email` (`u<10 hex>@example.invalid`), `name`, `first_name`, `last_name`, `phone` (`+1555<7 digits>`), `address`, `text` (fixed lorem), `null`, `redact` (`<arg>` or `REDACTED`), `hash` (hex digest). `<table>` may be `*` only in `ignore`. Allowed fake email domains everywhere: `example.invalid`, `example.com`, `example.org`, `example.net`, `*.test`.

## 9. Worktree env file (`ENV_FILE`, default `.env`)

`team-new-worktree` copies `.env.example` and sets: `PORT`, `APP_URL` (`http://localhost:<PORT>`), `APP_TIMEZONE`, `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`, `DATABASE_URL` (if the key exists), `PLAYWRIGHT_PROFILE_DIR` (`.team/playwright-profile`), `TEAM_WORKTREE=1`. Outside services stay in sandbox/log modes: `MAIL_MODE=log`, `SMS_MODE=log`, `PAYMENTS_MODE=sandbox`, `WEBHOOKS_MODE=log`.

## 10. Mac commands (`plugins/team/bin/`, bash 3.2)

Every command: `#!/usr/bin/env bash`, `set -euo pipefail`, `--help` (exit 0), reads `${TEAM_CONFIG_DIR:-$HOME/.config/team}`, safe to run twice, shellcheck-clean, never prints a token. Commands that change GitHub settings or a server print a plan unless `--apply`. Shared code: `plugins/team/lib/team-common.sh` (sourced via the command's own path; `CLAUDE_PLUGIN_ROOT` is not set for Bash-tool commands). Inside Claude Code the env has `CLAUDECODE=1`.

| Command | Synopsis | Notes |
|---|---|---|
| `team-gh` | `team-gh <gh args…>` | runs `gh` as the project's account (`GH_TOKEN="$(gh auth token -u <login>)"`); reads pass; writes only: `pr create`, `pr edit` (title/body/allowed labels), `pr comment`, `pr review --comment`, `pr merge --auto --squash [--delete-branch]`, `issue create`, `issue comment`, `issue edit --add-label <allowed>`; `pr edit <n> --add-label owner-approved` only in that exact form and always as the OWNER account. Refuses release PRs (checks online), `api` writes, settings/secrets/rulesets/workflows/releases (exit 4). With an agent line in accounts.conf, acts as the agent login (except the owner-approved label). |
| `team-post-check` | `team-post-check <sha> <context> <state> <description> [--target-url URL]` | context ∈ `ai-review ai-security ai-qa`; state ∈ `pending success failure error`; sha = 40 hex; refuses release PRs (4) |
| `team-bootstrap-repo` | `team-bootstrap-repo <owner/repo> [--profile project|standards|template] [--timezone <IANA>] [--create [--visibility public|private]] [--apply]` | `--create` generates the repo from the template first; then §2–3, repo variable `OWNER_LOGIN` (always), rulesets, settings, environments, variables, secrets, agent invite; plan by default |
| `team-verify-repo` | `team-verify-repo <owner/repo> [--profile …]` (also checks `OWNER_LOGIN`) | pass/fail table; exit 1 on any fail; warns on disabled scheduled workflows |
| `team-new-worktree` | `team-new-worktree <issue|pr> [--type T] [--slug S] [--no-setup]` (with both `--type` and `--slug` no issue lookup is made) | branch from `origin/main --no-track`; port under `locks/ports.lock`; env file; DB; `.team/evidence` → symlink to the main checkout's `.team/evidence`; `make setup`; snapshot or seed; prints `key=value` summary (`path branch port db app_url`) |
| `team-remove-worktree` | `team-remove-worktree <path|issue> [--force]` | stops the app, drops only the registry-recorded DB, frees the port, removes the worktree (keeps `.team/evidence` in the main checkout) |
| `team-conflict-check` | `team-conflict-check <issue>… [--json]` | reads each issue's "Likely files"; prints groups that must run one after another |
| `team-hooks` | `team-hooks [--check]` | the only way to set `core.hooksPath`; chains to an existing path |
| `team-app` | `team-app up|down|status [--timeout S]` | `make dev` in its own process group, pidfile `.team/app.pid`, waits for `HEALTH_PATH` |
| `team-db-pull` | `team-db-pull [--fresh]` | restore cached sanitized dump (or `SEED_CMD` if none) into the worktree DB, then `MIGRATE_CMD` |
| `team-sync` | `team-sync [--init] [--to <tag>] [--check]` | managed files + lock + workflow pins from a dev-standards release; `--init` deletes `template-ci.yml` |
| `team-store-token` | `team-store-token` | hidden prompt → keychain `team-release-please-token` → sets `RELEASE_PLEASE_TOKEN` on dev-standards; refuses inside Claude Code |
| `team-staging-login` | `team-staging-login <project>` | keychain → clipboard, never printed; refuses inside Claude Code (`CLAUDECODE`) |
| `team-worktree-report` | `team-worktree-report [--root DIR]… [--depth N] [--stale-days N] [--offline]` | read-only list of all worktrees, merged (PR state) / stale |
| `team-check-fences` | `team-check-fences [--hook PATH]` | feeds simulated tool calls to the fence; pass/fail table |
| `team-discover` | `team-discover` | runs `server/discover` over `ssh <VPS_ALIAS>`; read-only |
| `team-provision` | `team-provision <staging|production> [--apply]` | §12 |
| `team-flag` | `team-flag <staging|production> <name> on|off` | production: owner only (fence denies it in Claude Code) |
| `team-refresh-staging` | `team-refresh-staging [--apply]` | sanitized dump → staging DB → staging migrations |
| `team-merge-if-green` | `team-merge-if-green <pr> [--profile …] [--dry-run]` | private fallback: verifies every required check, then squash-merges |
| `team-deploy` | `team-deploy <staging|production> [--sha SHA] [--apply]` | private fallback; production refused inside Claude Code (I run it in a terminal) |

## 11. Server (`plugins/team/server/`, Linux bash, run as root via sudo)

Installed root-owned to `/usr/local/lib/team/`. Scripts: `discover`, `provision`, `deploy-receive`, `snapshot`, `serve-snapshot`, `refresh-staging`, `backup`, `flag`, `lib.sh`.

| Path on server | Owner/mode | Purpose |
|---|---|---|
| `/etc/team/projects/<project>-<env>.conf` | root:`<user>` 640 | `PROJECT ENV APP_USER APP_DIR PORT HEALTH_PATH MIGRATE_CMD DB_ENGINE DB_NAME DB_USER UNITS WEB_MODE HOST TIMEZONE LOW_TRAFFIC_HOUR SHARED_PATHS STATIC_ROOT` |
| `/etc/team/projects/<project>.salt` | root 600 | anonymization salt |
| `/srv/team/<project>/<env>/{releases,shared,current}` | `<user>` | `current` → `releases/<sha>`; env file `shared/.env` 600 |
| `/var/lib/team/<project>/backups/` | root 700 | `backup-<utc>.sql.gz` (14 kept), `backup-<utc>-pre-deploy.sql.gz` (5 kept) |
| `/var/lib/team/<project>/snapshots/` | root:`<project>-production` 750 | `sanitized-<utc>.sql.gz`, `latest` symlink |
| `/var/log/team/flags.log` | root 640 | `utc_ts project env flag on|off by` |
| `/etc/team/projects/<project>-<env>.resources` | root 600 | every resource the pack created (users, DBs, DB users, nginx/php-fpm/sudoers/unit files); only these may be reused or removed |
| `/etc/team/projects/<project>-<env>.dbpass` | root 600 | the DB password, to fill new template keys later |
| `/etc/team/backup.conf` | root 600 | `OFFSITE_BACKUP_TARGET` (empty = off-server copy TODO) |
| `/etc/team/mysql-admin.cnf` | root 600 | optional, when MySQL root can't use the socket |
| `/run/team/` | root 700 | lock files |
| `/var/log/team/<project>-<env>/` | `<user>` | app logs (logrotate) |
| nginx | | `/etc/nginx/sites-available/team-<project>-<env>.conf` (+ enabled link), `/etc/nginx/team/<project>-staging.htpasswd` |
| systemd | | `team-<project>-<env>-<proc>.service`; production timers `team-<project>-snapshot.timer`, `team-<project>-backup.timer`, `team-<project>-backup-verify.timer` |
| sudoers / logrotate | | `/etc/sudoers.d/team-<project>-<env>` (validated `visudo -cf`), `/etc/logrotate.d/team-<project>-<env>` |

- Release tarball `release-<sha>.tar.gz` = the contents of `ARTIFACT_DIR` plus the repo's `ops/` folder at its root (so `ops/anonymize` of production's current release is always on the server). Built once per commit by `pipeline.yml` (`scripts/ci/package.sh`).
- Ports for apps on the server: 9100–9899, first free (not listening, not in any `/etc/team/projects/*.conf`).
- Deploy key line: `command="/usr/local/lib/team/deploy-receive <project> <env>",restrict <pubkey> team-deploy-<project>-<env>`; db-pull key (production user): `command="/usr/local/lib/team/serve-snapshot <project>",restrict <pubkey> team-dbpull-<project>`.
- `deploy-receive` reads `SSH_ORIGINAL_COMMAND` ∈ `deploy <sha>` (tar.gz on stdin), `rollback <sha>`, `health`. sha = 7–40 hex. Exit 7 = release not on server.
- `serve-snapshot` accepts `latest` (streams the newest sanitized dump) and `latest-name`; exit 3 = no snapshot yet (`team-db-pull` then loads the seed data). `snapshot` exits 4 when the PII check refuses. Pack OS users are system users (uid < 1000) with root-owned `authorized_keys`. Nightly jobs are staggered in the low-traffic hour: backup :00, snapshot :20, weekly verify Sunday :40. Supported: Ubuntu 24.04 and 26.04 LTS (sudo-rs, Rust coreutils, PostgreSQL 18, MariaDB 11.8); `discover` reports `SUDO:`, `SUDOERS_CHECK:` and `COREUTILS:`. A sudo rule counts only when `visudo -cf` on the file passes and `sudo -l -U <user>` lists every command. Sanitized dumps drop PostgreSQL 18's `SET transaction_timeout` line so an older local Postgres can restore them.
- Env templates: `{{PORT}} {{APP_URL}} {{APP_TIMEZONE}} {{DB_HOST}} {{DB_PORT}} {{DB_NAME}} {{DB_USER}} {{DB_PASSWORD}} {{RANDOM_SECRET}}` (a fresh 32-byte hex per occurrence, only when the env file is first created; existing values are never overwritten; new template keys are appended).

## 12. `team-provision` ↔ `server/provision`

`team-provision <env> [--apply]` (run in a project root):
1. Builds a bundle in `mktemp -d`: `server/*`, the project's `ops/`, and `inputs.conf` (chmod 600): `PROJECT ENV HOST BASIC_AUTH_USER BASIC_AUTH_PASSWORD(staging) DEPLOY_PUBKEY DBPULL_PUBKEY(production) TIMEZONE LOW_TRAFFIC_HOUR ACME_EMAIL`. Keys are generated locally with `ssh-keygen` in the temp dir.
2. One connection: `tar -cz … | ssh <VPS_ALIAS> 'd=$(mktemp -d) && tar -xz -C "$d" && sudo bash "$d/provision" --bundle "$d" [--apply]; rc=$?; rm -rf "${d:?}"; exit $rc'`.
3. `provision` prints a plan (`[create]`, `[update]`, `[ok]`, `[skip]` lines) and, with `--apply`, applies it; it prints `TEAM-HOSTKEY <keytype> <base64>` (the server's host key, for pinning, so no second connection is needed) and ends with `TEAM-RESULT ok` or `TEAM-RESULT fail <reason>`.
4. On success with `--apply`, `team-provision` sets environment secrets `DEPLOY_HOST DEPLOY_USER DEPLOY_PORT DEPLOY_SSH_KEY DEPLOY_KNOWN_HOSTS APP_URL HEALTH_URL` (+ staging `BASIC_AUTH_USER BASIC_AUTH_PASSWORD`), repo secret `PRODUCTION_HEALTH_URL` (production), repo variable `STAGING_READY=true` / `PRODUCTION_READY=true`, keychain `team-staging-<project>`, and installs the db-pull private key at `~/.ssh/team-dbpull-<project>` (600). Values are piped into `gh secret set` on stdin, never printed.

## 13. The fence (`plugins/team/hooks/fence`)

- PreToolUse, matcher `*`, `timeout` 15 s; internal watchdog 8 s → deny.
- Input: hook JSON on stdin, parsed with **one** `jq` call. Uses `tool_name`, `tool_input.{command,file_path,notebook_path,path}`, `cwd`, `agent_type`, `agent_id`.
- Decision: deny → JSON `hookSpecificOutput.permissionDecision="deny"` + reason, exit 0. Internal error, malformed input or watchdog → reason on stderr, exit 2. Allow → no output, exit 0 (normal permission flow continues).
- Rule ids (log + tests): `push-main`, `push-release-branch`, `force-push`, `push-tags`, `tag-write`, `release-write`, `skip-hooks`, `hooks-path`, `git-config`, `merge-admin`, `merge-no-auto`, `owner-approved`, `gh-write`, `gh-api-write`, `gh-credential`, `curl-github-write`, `credential-read`, `workflow-edit`, `fence-file`, `prod-action`, `nested-claude`, `ssh-dest`, `ssh-form`, `disguised`, `script-scan`, `agent-bash`, `agent-tool`, `post-check-agent`, `internal-error`, `malformed-input`, `timeout`.
- Config read: `defaults.conf` (`VPS_ALIAS VPS_IP VPS_HOSTNAME DOMAIN VPS_FORBIDDEN_ALIASES BACKGROUND_PERMISSION_MODE`), `accounts.conf` (GitHub SSH aliases → allowlist). Missing config → every ssh-family command except to GitHub aliases is denied.
- Standards repo = a repo whose `origin` URL path ends `/dev-standards` or `/dev-standards.git`; there, workflows and `managed/**`, `tests/**` copies are ordinary files.
- Trusted commands (not scanned): the `team-*` commands in the plugin's own `bin/`.
- The decision runs in a child process the 8 s watchdog can always kill, so every call returns (deny on timeout) well inside the 15 s hook timeout; measured: median ~20 ms, 5,000-command chains ~3 s, 1–2 MB inputs end in a `timeout` deny at ~8.1 s. Extra deny-side rules beyond this table are listed in `plugins/team/hooks/README.md` with an example each; known gaps are listed there too.
- Agent Bash allowlists: all review agents → read-only `git` and `gh`, plain readers, `team-post-check` (own context only); `team:team-reviewer`, `team:team-security` → + `team-gh pr comment`, `team-gh pr review --comment`; `team:team-qa` → + `team-app`, `make e2e` (also as `cd "<dir>" && …`), `ls`, `curl` GET to localhost; `team:team-health` → + `team-gh issue create|list`, `make audit`. Review agents get no Write/Edit/NotebookEdit.
- Nested Claude allowed form only: `[cd <dir> &&] claude --bg [--name <n>] [--permission-mode <BACKGROUND_PERMISSION_MODE>] <prompt>` (writers use the prompt `"/team:ship <n> background-writer"`; ship's writer mode runs fix-bug or build-feature first), plus read-only management `claude agents --json [--all]`, `claude logs <id>`, `claude stop <id>`, `claude rm <id>`, `claude --version`, `claude plugin list|validate …`.

## 14. Reusable workflows (`.github/workflows/`, called `@v1`)

| Workflow | Inputs | Jobs (→ check names) |
|---|---|---|
| `ci.yml` | `standards-ref` (default empty → `job.workflow_sha`), `working-directory` (default `.`), `allow-unreleased-lock` (bool, default false) | `ci` |
| `pr-gates.yml` | `standards-ref`, `profile` (`project`/`standards`/`template`) | `guarded-paths`, `pr-title` |
| `pipeline.yml` | `standards-ref` | `build`, `scan-artifact`, `deploy-staging`, `e2e-staging`, `release`, `deploy-production`, `smoke-production`, `main-red` |
| `rollback.yml` | `tag` (required), `standards-ref` | `rollback` (environment `production`) |
| `uptime.yml` | `standards-ref` | `uptime` |

- Standards checkout: `actions/checkout` with `repository: ${{ job.workflow_repository }}` and `ref: ${{ inputs.standards-ref || job.workflow_sha }}` (the exact commit the caller pinned, e.g. `@v1`), path `.team-standards/` (added to `.git/info/exclude`). `gates.yml` in dev-standards passes the PR's base SHA; `self-test.yml` calls `./.github/workflows/ci.yml`, so `job.workflow_sha` is the PR's own commit.
- Secrets: environment secrets (§12) on the called jobs that set `environment:`; repo secrets `RELEASE_PLEASE_TOKEN`, `PRODUCTION_HEALTH_URL`; callers pass `secrets: inherit`. Variables: `PROJECT_TIMEZONE`, `STAGING_READY`, `PRODUCTION_READY`, `OWNER_LOGIN`.
- Runner: `ubuntu-24.04`. Third-party actions pinned by full SHA with the version in a comment, using the newest release at least 7 days old (same rule as the Dependabot cooldown).

### `scripts/ci/` (bash, run from the standards checkout; `$TEAM_STANDARDS_DIR` = its path)
`common.sh` (sets `LC_ALL=C`), `package.sh <artifact-dir> <out.tar.gz>`, `make-target.sh <target>` (exit 3 → notice + success), `test-guard.sh`, `pii-guard.sh`, `context-check.sh`, `gitleaks.sh git|dir`, `semgrep.sh`, `stop-the-line.sh`, `main-red.sh open|close`, `guarded-paths.sh`, `pr-title.sh` (title from `PR_TITLE` env), `deploy.sh <env> <artifact>`, `smoke.sh <url>`, `incident.sh check`, `anonymize-lint.sh`, `conf.sh get <file> <key>`.

Extra flags: `context-check.sh [--root D] [--standards-dir D] [--tags-from F] [--allow-unreleased-lock] [--standards-self]`, `gitleaks.sh verify --tarball F`, `deploy.sh … [--sha S] [--rollback S] [--health]`, `smoke.sh <url> [--noindex]`. `make-target.sh` treats a target as not configured only when make exits 2 with both the `Error 3` line and the "not configured" text. Runners: `tests/ci/self-test.sh` (the `self-test` job; `SELF_TEST_SUITES` limits suites), `tests/ci/sync-fixture.sh` (re-run whenever `managed/` changes), `tests/lib/net-guard.sh` (every test runner installs it first).

### `config/`
`required-checks.json`, `labels.json`, `guarded-globs.txt`, `destructive-migration-patterns.txt`, `test-globs.txt`, `test-markers.txt`, `assertion-patterns.txt`, `pii-patterns.txt`, `pr-title-types.txt`, `tool-versions.env`.

## 15. Standard report (PR body, `/team:report`)

```
## Report: #<issue> <title>
Status: merged | waiting for checks | waiting for your yes | blocked
What changed: <2–4 lines>
Tests: <added/changed> · results <pass/fail counts>
Evidence: before/after screenshots (local: .team/evidence/<pr>/)
Flags: none | <flag> (off in production until client approval)
Guarded / risks: <none or plain-language summary>
Lessons: <none, or one line each>
Questions for you: <none or list>
PR: <link>
```

The PR body ends with `Fixes #<issue>` (or `Refs #<issue>` for a logging-only `needs-info` change).

## 16. Mac bash rules (hooks, `bin/`, `lib/`, tests)

bash 3.2 + BSD tools: no associative arrays, `mapfile`/`readarray`, `${v,,}`/`${v^^}`, `|&`, `&>>`, `sed -i` without a suffix argument, `grep -P`, GNU-only `date`/`stat`/`readlink -f`/`timeout`. Expand possibly-empty arrays as `${a[@]+"${a[@]}"}`. Under this Mac's UTF-8 locale bash 3.2 lets `[a-z]` match capitals (set `LC_COLLATE=C`/`LC_ALL=C` before matching) and reads a non-ASCII character right after `$var` as part of the name (write `${var}→`). Test with `/bin/bash` explicitly. Makefiles: Make 3.81 (no `.ONESHELL`, `.RECIPEPREFIX`, `undefine`, grouped targets). Every removal guards its variables: `rm -rf "${DIR:?}"/…`. Never `pkill`/`killall`; stop only PIDs you recorded, after checking their cwd.

## 17. Ownership during the build (one writer per folder)

| Folder | Writer |
|---|---|
| `plugins/team/hooks/` | fence engineer |
| `tests/hooks/` | fence test engineer (QA), independent of the hook's author |
| `.github/workflows/`, `scripts/ci/`, `config/`, `tests/ci/`, `tests/fixture-project/` | workflows engineer |
| `plugins/team/server/`, `tests/server/` | server engineer |
| `plugins/team/lib/team-common.sh` | lead (frozen; ask the lead for changes) |
| `plugins/team/bin/` GitHub commands (`team-gh team-post-check team-bootstrap-repo team-verify-repo team-sync team-store-token team-merge-if-green team-worktree-report team-conflict-check`), `lib/team-github.sh`, `tests/commands/github/` | GitHub commands engineer |
| `plugins/team/bin/` local + VPS commands (`team-new-worktree team-remove-worktree team-hooks team-app team-db-pull team-staging-login team-check-fences team-discover team-provision team-flag team-refresh-staging team-deploy`), `lib/team-local.sh`, `tests/commands/local/` | local commands engineer |
| `plugins/team/skills/`, `plugins/team/agents/`, `managed/` | skills engineer |
| `project-starter/` | template engineer |
| everything else, all commits | lead |
