#!/bin/bash
# shellcheck disable=SC2016  # fixture file contents are literal on purpose
# tests/hooks/fixtures.sh — builds the fence test fixtures (sourced by run.sh).
# build_fixtures <tmpdir> sets FX, FAKE_HOME, FAKE_CFG, CFG_EMPTY, CFG_NOBYPASS.
# Only local repos and fake config values (vps-test, TEST-NET 192.0.2.10, example.test).

# fx_git: git isolated from the real user/system config.
fx_git() {
  HOME="$FAKE_HOME" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    git -c user.name="Fence Test" -c user.email=fence@example.test -c init.defaultBranch=main \
      -c commit.gpgsign=false -c tag.gpgsign=false "$@"
}

# fx_write <file> <content>: create parent dirs and write content (with trailing newline).
fx_write() {
  mkdir -p "$(dirname "$1")"
  printf '%s\n' "$2" >"$1"
}

# fx_repo <dir> <branch> <origin-url>: git repo with one commit on <branch>.
fx_repo() {
  local dir=$1 branch=$2 origin=$3
  mkdir -p "$dir"
  fx_git -C "$dir" init -q || return 1
  fx_git -C "$dir" symbolic-ref HEAD "refs/heads/$branch" || return 1
  [ -f "$dir/README.md" ] || fx_write "$dir/README.md" "fixture"
  fx_git -C "$dir" add -A || return 1
  fx_git -C "$dir" commit -q -m "fixture" || return 1
  if [ -n "$origin" ]; then fx_git -C "$dir" remote add origin "$origin" || return 1; fi
}

build_fixtures() {
  local root=$1
  FX="$root/fx"
  FAKE_HOME="$root/home"
  FAKE_CFG="$root/cfg"
  CFG_EMPTY="$root/cfg-empty"
  CFG_NOBYPASS="$root/cfg-nobypass"
  mkdir -p "$FX" "$FAKE_HOME" "$FAKE_CFG" "$CFG_EMPTY" "$CFG_NOBYPASS" || return 1

  # --- fake config ---
  cat >"$FAKE_CFG/defaults.conf" <<'EOF'
# fake values for fence tests only
VPS_ALIAS=vps-test
VPS_IP=192.0.2.10
VPS_HOSTNAME=srv-test.example.net
DOMAIN=example.test
VPS_FORBIDDEN_ALIASES=vps-test-root
BACKGROUND_PERMISSION_MODE=bypassPermissions
EOF
  cat >"$FAKE_CFG/accounts.conf" <<'EOF'
account|owner-test|github.com|Owner Test|owner@example.test
account|work-test|github.com-work|Work Test|work@example.test
EOF
  # same, but background sessions need no permission flag
  sed 's/^BACKGROUND_PERMISSION_MODE=.*/BACKGROUND_PERMISSION_MODE=/' "$FAKE_CFG/defaults.conf" >"$CFG_NOBYPASS/defaults.conf"
  cp "$FAKE_CFG/accounts.conf" "$CFG_NOBYPASS/accounts.conf"
  # CFG_EMPTY: exists but holds no config at all

  # --- fake HOME ---
  mkdir -p "$FAKE_HOME/.ssh" "$FAKE_HOME/.claude/agents" "$FAKE_HOME/.config/gh" || return 1
  fx_write "$FAKE_HOME/.ssh/id_ed25519" "FAKE PRIVATE KEY (fixture)"
  fx_write "$FAKE_HOME/.ssh/id_ed25519.pub" "ssh-ed25519 AAAAFAKE fixture"
  fx_write "$FAKE_HOME/.ssh/config" "Host vps-test"
  fx_write "$FAKE_HOME/.ssh/known_hosts" "# fixture"
  fx_write "$FAKE_HOME/.claude/settings.json" "{}"
  fx_write "$FAKE_HOME/.claude/CLAUDE.md" "# fixture"
  fx_write "$FAKE_HOME/.config/gh/hosts.yml" "github.com: {}"
  fx_write "$FAKE_HOME/notes.txt" "fixture"

  # --- bare origin shared by main-repo / feat-repo ---
  local origin="$FX/origin.git"

  # main-repo: on main, origin = local bare repo, local tag v9.9.9
  fx_repo "$FX/main-repo" main "" || return 1
  fx_git -C "$FX/main-repo" tag v9.9.9 || return 1
  fx_git clone -q --bare "$FX/main-repo" "$origin" || return 1
  fx_git -C "$FX/main-repo" remote add origin "$origin" || return 1
  # wt-feat: a linked worktree of main-repo on a feature branch (its .git is a file)
  fx_git -C "$FX/main-repo" worktree add -q -b feat/30-wt "$FX/wt-feat" || return 1
  fx_write "$FX/wt-feat/.claude/settings.json" "{}"

  # feat-repo: on feat/12-login, same origin
  fx_repo "$FX/feat-repo" main "$origin" || return 1
  fx_git -C "$FX/feat-repo" checkout -q -b feat/12-login || return 1
  mkdir -p "$FX/feat-repo/x"

  # standards-repo: origin path ends /dev-standards.git
  fx_write "$FX/standards-repo/managed/.claude/settings.json" "{}"
  fx_write "$FX/standards-repo/managed/.claude/agents/team-qa.md" "# fixture"
  fx_write "$FX/standards-repo/managed/.mcp.json" "{}"
  fx_write "$FX/standards-repo/tests/fixture-project/.claude/settings.json" "{}"
  fx_write "$FX/standards-repo/tests/fixture-project/.mcp.json" "{}"
  fx_write "$FX/standards-repo/.github/workflows/ci.yml" "name: ci"
  fx_write "$FX/standards-repo/.claude/settings.json" "{}"
  fx_repo "$FX/standards-repo" feat/20-sync "git@github.com:someone/dev-standards.git" || return 1

  # std-https: also a standards repo (https URL without .git)
  fx_write "$FX/std-https/.github/workflows/ci.yml" "name: ci"
  fx_repo "$FX/std-https" feat/21-x "https://github.com/someone/dev-standards" || return 1

  # std-fork: NOT a standards repo (path ends dev-standards-fork)
  fx_write "$FX/std-fork/.github/workflows/ci.yml" "name: ci"
  fx_write "$FX/std-fork/managed/.claude/settings.json" "{}"
  fx_repo "$FX/std-fork" feat/22-x "git@github.com:someone/dev-standards-fork.git" || return 1

  # project: ordinary project repo on a feature branch
  local p="$FX/project"
  fx_write "$p/.claude/settings.json" "{}"
  fx_write "$p/.claude/settings.local.json" "{}"
  fx_write "$p/.claude/agents/helper.md" "# fixture"
  fx_write "$p/.claude/hooks/check.sh" "#!/bin/bash"
  fx_write "$p/.claude/rules/style.md" "# fixture"
  fx_write "$p/.mcp.json" "{}"
  fx_write "$p/.github/workflows/ci.yml" "name: ci"
  fx_write "$p/.github/CODEOWNERS" "* @someone"
  fx_write "$p/.env" "APP_ENV=local"
  fx_write "$p/.env.example" "APP_ENV=local"
  fx_write "$p/.env.production" "APP_KEY=decoy-fixture"
  fx_write "$p/src/app.txt" "fixture"
  fx_write "$p/notes.md" "fixture"
  # Makefile: every recipe harmless
  printf '%s\n' \
    '.PHONY: test e2e audit lint' \
    'test:' '	echo test-ok' \
    'e2e:' '	echo e2e-ok' \
    'audit:' '	echo audit-ok' \
    'lint:' '	@echo lint-ok' >"$p/Makefile"
  # bad.mk: a recipe that pushes to main
  printf '%s\n' \
    '.PHONY: ship' \
    'ship:' '	git push origin main' >"$p/bad.mk"
  # sub/Makefile: a recipe that hides the push behind $$ variables
  mkdir -p "$p/sub"
  printf '%s\n' \
    '.PHONY: all' \
    'all:' '	G=git; $$G push origin main' >"$p/sub/Makefile"
  # tag.mk: recipe creates and pushes a tag
  printf '%s\n' \
    'release:' '	git tag v1.0.0 && git push origin v1.0.0' >"$p/tag.mk"
  # scripts
  fx_write "$p/scripts/deploy.sh" '#!/bin/bash
set -e
echo "deploying"
git push origin main'
  fx_write "$p/scripts/clean.sh" '#!/bin/bash
# a harmless script; mentions git push only in a comment
echo "cleaning"
rm -rf ./build'
  fx_write "$p/scripts/settings.sh" '#!/bin/bash
echo "{}" > .claude/settings.json'
  fx_write "$p/scripts/admin-merge.sh" '#!/bin/bash
gh pr merge "$1" --admin --squash'
  fx_write "$p/scripts/release.py" 'import subprocess
subprocess.run(["git", "push", "origin", "main"], check=True)'
  fx_write "$p/scripts/ok.py" 'print("hello")'
  fx_write "$p/scripts/write-settings.py" 'open(".claude/settings.local.json", "w").write("{}")'
  fx_write "$p/scripts/tool.js" 'const cp = require("child_process");
cp.execSync("gh pr merge 5 --admin");'
  fx_write "$p/scripts/ok.js" 'console.log("hello");'
  fx_write "$p/scripts/api.rb" 'system("curl -X POST https://api.github.com/repos/o/r/labels")'
  fx_write "$p/scripts/env.py" 'print(open(".env.production").read())'
  fx_write "$p/scripts/gh-api.py" 'import urllib.request
req = urllib.request.Request("https://api.github.com/repos/o/r/issues", method="POST")
urllib.request.urlopen(req)'
  fx_write "$p/scripts/gh-get.py" 'import urllib.request
print(urllib.request.urlopen("https://api.github.com/repos/o/r").read())'
  fx_write "$p/scripts/push-feat.sh" '#!/bin/bash
git push -u origin HEAD'
  # untrusted look-alikes of pack commands (must be scanned, not trusted)
  fx_write "$p/team-gh" '#!/bin/bash
git push origin main'
  fx_write "$FX/tmpbin/team-gh" '#!/bin/bash
git push origin main'
  chmod +x "$p/scripts/"*.sh "$p/team-gh" "$FX/tmpbin/team-gh"
  fx_repo "$p" feat/3-thing "git@github.com:someone/project.git" || return 1

  # plain: not a git repo
  fx_write "$FX/plain/file.txt" "fixture"
  fx_write "$FX/plain/.claude/settings.json" "{}"
  fx_write "$FX/plain/.mcp.json" "{}"
  fx_write "$FX/plain/run.sh" '#!/bin/bash
echo hi'
  chmod +x "$FX/plain/run.sh"
  return 0
}
