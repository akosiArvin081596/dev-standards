# Walking skeleton (new-project, Part B step 5)

Build this on `chore/initial-stack` in the new clone, for the stack in `.team/new-project.conf`.
- Use the stack's own standard scaffolding tool where one exists, pinned to current stable versions. Keep it minimal.
- Everything must pass locally before the hand-over.

## The app
- **Health endpoint** at `HEALTH_PATH` (default `/health`): returns 200 without auth, and reports the database as reachable.
- **One page** (`/`): shows the project name and the current time in the project timezone, with the zone named (for example "3:00 PM Asia/Manila"). Times are stored in UTC.
- **Flags table** `feature_flags` (`name`, `enabled`, `updated_at`, `updated_by`), created by a migration. Add a small reader the app uses, `flag_enabled(name)`, defaulting to off for unknown flags.
- **Sample data:** a small `customers` table (`id`, `name`, `email`, `phone`, `created_at`), with fake seed data only: `@example.invalid` emails and `+1555…` phones.
- **Outside services** (mail, SMS, payments, webhooks) stay in log or sandbox mode, read from the env.

## Makefile (GNU Make 3.81: no `.ONESHELL`, `.RECIPEPREFIX`, `undefine` or grouped targets)
- **Fill every shared target** the template defines for this stack: `setup dev lint test e2e build audit migrate db-pull anonymize-check hooks`, plus `seed` (`SEED_CMD`).
  - A filled target no longer exits 3.
  - Pack commands come from PATH, or from `TEAM_BIN` outside Claude Code, as the template already does.
- **`setup`:** installs dependencies, and creates the env file's database if it's missing. It connects only through the env file's `DB_HOST` and `DB_PORT`, never repoints or stops another server, and is safe to run twice.
- **`dev`:** listens on `$PORT` from the env file.
- **`lint`:** formatter check plus linter. Configure one standard formatter and one linter for the stack.
- **`test`:** the stack's test runner, with `TZ=UTC`.
- **`build`:** fills `ARTIFACT_DIR` with exactly the release.
- **`audit`:** the dependency audit.
- **`e2e`:** Playwright in `e2e/`, against `APP_URL`.

## Tests
- **Unit:** health returns 200; `flag_enabled` defaults to off; a UTC timestamp formats correctly in the project timezone.
- **Playwright** (`e2e/`, which the template provides; adapt it to the skeleton):
  - **the smoke test:** `/` loads and the health endpoint returns 200
  - **the midnight test:** with `timezoneId` set to the project timezone, a UTC instant just before and just after local midnight shows the right local date on the page, or through the formatting helper the page uses

## Data and ops
- **`ops/anonymize`:**
  - `rule|customers|name|name`, `rule|customers|email|email`, `rule|customers|phone|phone`
  - a `devlogin|…` line if the skeleton has a users table
  - `make anonymize-check` must pass
- **`ops/services.conf`:** `web|web|<command that listens on $PORT>`.
- **`ops/env/staging.env.tmpl` and `production.env.tmpl`:** every key the app reads, using the `{{PORT}} {{APP_URL}} {{APP_TIMEZONE}} {{DB_*}} {{RANDOM_SECRET}}` placeholders.
- **`.env.example`:**
  - every key: `PORT APP_URL APP_TIMEZONE DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD` (plus `DATABASE_URL` if the stack uses it), `PLAYWRIGHT_PROFILE_DIR=.team/playwright-profile`
  - `MAIL_MODE=log SMS_MODE=log PAYMENTS_MODE=sandbox WEBHOOKS_MODE=log`
  - no real values
- **This checkout's own `.env`** (gitignored), so `/team:ship` can run the app here:
  - copy `.env.example`
  - **`PORT`:** the first port from `WORKTREE_PORT_MIN` to `WORKTREE_PORT_MAX` (`defaults.conf`) that isn't listening (`lsof -nP -iTCP:<port> -sTCP:LISTEN`) and isn't in `ports.registry`
  - **`APP_URL`:** `http://localhost:<PORT>`
  - **`APP_TIMEZONE`:** the project timezone
  - **`DB_*`:** a database `<name_with_underscores>_dev`
    - Postgres: on `LOCAL_PG_HOST`:`LOCAL_PG_PORT`
    - MySQL or MariaDB: the project-local container on `LOCAL_DB_PORT`
  - never point it at another project's database

## Context files and docs
- **`CLAUDE.md`** (at most 150 lines; no `@` imports):
  - what the project is, its stack, and its timezone
  - a repo map
  - the shared `make` targets
  - gotchas
  - mention docs as plain backtick paths
  - keep the template's lines on lessons and blocked actions
- **`.claude/rules/project/`:** fill the template's commented rule files with this stack's real globs in their `paths:` frontmatter (testing, database and migrations, security-sensitive, frontend, API). Delete the ones that don't apply. At most 80 lines each.
- **`docs/commands.md`:** every `make` target, what it runs, and its exit codes.
- **`docs/architecture.md`:** the layout, request flow, flag mechanism, time handling (UTC storage and display zone), data and anonymisation.
- **`docs/flags.md`:** keep the empty registry table.
- **Budget:** `wc -l CLAUDE.md .claude/rules/*/*.md`. At most 250 lines load every session (`CLAUDE.md` plus rule files without `paths:`).

## Verify, then commit
1. Run each target as its own command: `make setup`, `make lint`, `make test`, `make build`, `make migrate`, `make seed`, `make anonymize-check`, `make audit`, then `team-app up`, `make e2e`, `team-app down`. Each must exit 0. Output with `Error 3` plus "not configured: fill in for your stack" means a target is still unfilled: fill it in.
2. Check that `git status --porcelain` shows only skeleton files (no `.env`, no `.team/`), then commit with `git add -A` in small Conventional Commits (for example `feat: walking skeleton`, `test: smoke and midnight e2e tests`, `docs: commands and architecture`). Never skip git hooks.
3. Don't push or open the PR here: `/team:ship` does both.
