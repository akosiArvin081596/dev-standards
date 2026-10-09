---
name: new-project
description: Create a new team-workflow project end to end. Asks the owner the setup questions, checks the VPS, creates and configures the GitHub repo from project-starter, and clones it. Then, in the new clone, builds the walking skeleton, checks DNS, provisions staging and production, prints the planner setup, and hands over to /team:ship. Start it from ~/Projects/dev-standards; it continues in the new project's own session.
argument-hint: "[project-name]"
disable-model-invocation: true
---

# New project: $ARGUMENTS

## Where am I?
- **In `dev-standards`** (`git remote get-url origin` ends with `/dev-standards` or `/dev-standards.git`): run **Part A**.
- **In a fresh clone whose `.team/new-project.conf` exists:** run **Part B**. To resume, check what's already done and continue from the first unfinished step.
- **Anywhere else:** explain that this skill starts in `~/Projects/dev-standards`, and stop.

**Config:** `CFG="${TEAM_CONFIG_DIR:-$HOME/.config/team}"`. Read `$CFG/defaults.conf` and `$CFG/accounts.conf` with `grep` or `cat`. They're parsed, never sourced, and values may be wrapped in double quotes. Never write under `$CFG` yourself; it's fenced. Never put a server IP, alias or domain into a committed file.

**Yes moments** (VPS connections, `team-bootstrap-repo … --apply`):
1. Say in one line what the command does.
2. AskUserQuestion with the options "Yes, run it", "I'll run it myself" and "Not now".
3. **On yes:** run the exact command shown, as a command of its own. Claude Code's ask rule prompts once more; the owner approves it there.
4. **Fallback:** if the command is denied, or the owner chose to run it, print it in a code block for their own terminal. Wait until they say it's done, and ask them to paste the output if you need it.

## Part A: in dev-standards
1. **Ask the owner,** a few questions per AskUserQuestion call; free-text answers come through "Other".
   1. **Project name** (`$ARGUMENTS` if given; must match `^[a-z][a-z0-9-]{1,20}$`) and a one-line **purpose**.
   2. **Owner:** me, or a client (ask the client's name; it's only used in the planner header).
      - For a client, confirm the contract allows a public repo. If it doesn't, the repo is private: explain the private fallback (GitHub Free doesn't enforce rulesets or deploy approvals on private repos, so agents merge with `team-merge-if-green`, and the owner deploys production from the Mac with `team-deploy production`).
   3. **GitHub account:** the `account|<login>|<ssh alias>|…` lines in `accounts.conf`, with `DEFAULT_GITHUB_ACCOUNT` first. **Visibility:** public (default) or private.
   4. **Stack:** offer 3–4 options that fit the purpose.
      - If the owner's own instructions (their CLAUDE.md) name a house frontend standard, the first option uses it.
      - Each option names frontend, backend and database, and the resulting `DB_ENGINE` (`postgres`, `mysql`, `mariadb` or `none`) and `WEB_MODE` (`proxy` for an app server behind nginx, `php-fpm`, or `static`).
   5. **Timezone:** where the users and the client are. Offer `DEFAULT_TIMEZONE` (Asia/Manila) first; accept any IANA name that exists under `/usr/share/zoneinfo/`. The low-traffic hour defaults to 3 (in the project timezone).
   6. **Domain:**
      - **Default:** `PRODUCTION_HOST_PATTERN` and `STAGING_HOST_PATTERN` from `defaults.conf`, with `{app}` replaced by the name.
      - **Client domain:** ask for both hosts. They're recorded in `$CFG/projects/<name>.conf`, which is fenced, so print this for the owner's terminal and wait until they say it's done:
        ```bash
        mkdir -p "${TEAM_CONFIG_DIR:-$HOME/.config/team}/projects" && cat > "${TEAM_CONFIG_DIR:-$HOME/.config/team}/projects/<name>.conf" <<'EOF'
        PRODUCTION_HOST=<host>
        STAGING_HOST=<host>
        CLIENT_DOMAIN=<domain>
        EOF
        ```
   7. **Clone folder:** default `~/Projects/<name>`. It must not exist yet.

   Check the name is free: `team-gh repo view <owner>/<name> --json name` must fail with "not found". Then show a summary of every answer and confirm it with AskUserQuestion.
2. **Discover the server** (a yes moment): `team-discover`. It's read-only.
   - Show: the OS (and whether it's a supported Ubuntu LTS), the web server (nginx is applied; for others, provisioning prints the config instead), the database engines and versions (is the chosen `DB_ENGINE` there?), the existing sites (a clash with the chosen hosts means stop and ask), disk, RAM and firewall.
   - Ask the owner to confirm before going on.
3. **Create the repo** from project-starter.
   1. Show the plan: `team-bootstrap-repo <owner>/<name> --profile project --create --visibility <public|private>`.
   2. Yes moment: `team-bootstrap-repo <owner>/<name> --profile project --create --visibility <public|private> --apply`.
   3. Report any setting GitHub refused for a private repo.
4. **Clone** over the account's SSH alias (field 3 of its `accounts.conf` line): `git clone git@<alias>:<owner>/<name>.git <dir>`.
5. **Hand the answers to Part B:**
   - Run `mkdir -p <dir>/.team`, then write `<dir>/.team/new-project.conf` as `KEY=value` lines: `PROJECT_NAME PURPOSE OWNER_KIND CLIENT_NAME GITHUB_ACCOUNT GITHUB_SSH_HOST GITHUB_REPO VISIBILITY STACK DB_ENGINE WEB_MODE PROJECT_TIMEZONE LOW_TRAFFIC_HOUR PRODUCTION_HOST STAGING_HOST DOMAIN_KIND CLONE_DIR`.
   - Confirm `git -C <dir> check-ignore -q .team/new-project.conf` succeeds, meaning the file is ignored and never committed.
6. **Hand over.** This session's working folder is dev-standards, and the rest must run inside the new project with its own settings and fences. Tell the owner:
   - open a new terminal and run `cd <dir> && claude`, started the way they usually start Claude Code
   - accept the trust prompt (background writers need it later)
   - if a warning says the team plugin isn't installed, run `claude plugin install team@dev-standards --scope project`, then `/reload-plugins`
   - type `/team:new-project` there to continue

## Part B: in the new clone
Read `.team/new-project.conf`. Check that `origin` is `GITHUB_REPO`.
1. **Branch.** Run `team-hooks`, then `git fetch origin`, then `git switch -c chore/initial-stack --no-track origin/main`.
2. **Configure.** Fill in `ops/project.conf`, keeping its comments. Use every key from the contract:
   `PROJECT_NAME GITHUB_ACCOUNT GITHUB_SSH_HOST GITHUB_REPO VISIBILITY DB_ENGINE WEB_MODE HEALTH_PATH(/health) MIGRATE_CMD SEED_CMD MIGRATIONS_GLOB HIGH_RISK_GLOBS PROJECT_TIMEZONE LOW_TRAFFIC_HOUR ENV_FILE(.env) ARTIFACT_DIR(.team/artifact) SHARED_PATHS STATIC_ROOT`, plus `LOCAL_DB_IMAGE LOCAL_DB_PORT` for mysql and mariadb.
   - The globs match the stack's real layout.
   - `HIGH_RISK_GLOBS` covers auth, payments and permissions code.
3. **Sync.** Run `team-sync --init`: it deletes the template-only CI and writes `.claude/team-standards.lock`.
   - Check that `git status --porcelain` lists only `ops/project.conf`, `.claude/team-standards.lock`, the deleted `.github/workflows/template-ci.yml`, and files `team-sync` reports it wrote.
   - Then run `git add -A` (it stages the deletion too) and `git commit -m 'chore: configure project'`. Never skip git hooks.
4. **Settings.**
   1. Show the plan: `team-bootstrap-repo <owner>/<name> --profile project`.
   2. Yes moment: `team-bootstrap-repo <owner>/<name> --profile project --apply`.
   3. Then run `team-verify-repo <owner>/<name> --profile project`. Explain the failures that are expected until provisioning (environment secrets, `*_READY`).
5. **Walking skeleton.** Read `${CLAUDE_SKILL_DIR}/skeleton.md` and follow it on this branch.
6. **DNS.** For both hosts, run `dig +short <host>` and compare the last line with `VPS_IP` from `defaults.conf`.
   - If they differ, tell the owner the exact record (`A <host> <VPS_IP>`, or a CNAME to a host that already resolves there).
   - Wait until they say it's added, then check again. Never loop.
7. **Provision** staging, then production. For each environment:
   1. AskUserQuestion with the options "Show the plan first (recommended)", "Apply now", "I'll run it myself" and "Skip for now".
   2. The plan is `team-provision <env>` and applying is `team-provision <env> --apply`. Both connect to the VPS, so both are yes moments.
   3. Start production only after staging succeeds (`TEAM-RESULT ok`).
   4. Then run `team-verify-repo <owner>/<name> --profile project` again.
   5. Tell the owner that `team-staging-login <name>`, run in their own terminal, copies staging's login to the clipboard.
8. **Planner setup.** Print the block from `${CLAUDE_SKILL_DIR}/planner-block.md`, filled in. Never write it into a file in the repo, because it holds the URLs.
9. **Ship it.**
   - Remove `.team/new-project.conf`.
   - Tell the owner to type `/team:ship` in this session. It opens the skeleton PR with the standard report and runs the reviewers.
   - The PR is guarded, so `/team:ship` asks for their yes.
   - After the merge, `main` deploys to staging.
