#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2329,SC2317  # test groups and helpers are called indirectly ("t_$g", from run-groups.sh)
# Tests for the GitHub team-* commands (plugins/team/bin, docs/rules.md §10, §13).
# Run: /bin/bash tests/commands/github/run.sh [group...]
# Groups: help lib gh postcheck bootstrap verify sync conflict worktree storetoken merge shellcheck
# Never talks to GitHub or the keychain: stub gh and security come first on PATH, and
# TEAM_CONFIG_DIR / HOME point into a mktemp -d sandbox that is removed at the end.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=helpers.sh
. "$HERE/helpers.sh"

GROUPS_WANTED="${*:-help lib gh postcheck bootstrap verify sync conflict worktree storetoken merge shellcheck}"
want() { case " $GROUPS_WANTED " in *" $1 "*) return 0 ;; esac; return 1; }

setup_sandbox
trap cleanup EXIT
trap 'exit 130' INT TERM

S="octo-owner/sample-app"
SHA_A="0123456789abcdef0123456789abcdef01234567"
KEYCHAIN_TOKEN="relTOKENsecret42"
TOKEN_RE="$TOKEN_RE|$KEYCHAIN_TOKEN"

# github_style <fixture> <id> : a ruleset as GitHub returns it (extra fields, other order)
github_style() {
  jq -c --argjson id "$2" '. + {id: $id, source_type: "Repository", source: "octo-owner/sample-app",
      node_id: "RRS_fake", created_at: "2026-10-09T00:00:00Z", current_user_can_bypass: "pull_requests_only", _links: {}}
    | .rules |= (reverse | map(
        if .type == "pull_request" then .parameters += {automatic_copilot_code_review_enabled: false, required_reviewers: []}
        elif .type == "required_status_checks" then .parameters.required_status_checks |= reverse
        else . end))' "$1"
}

# repo_json <slug> <configured 0|1> [private] [is_template]
repo_json() {
  jq -cn --arg s "$1" --argjson c "$2" --argjson p "${3:-false}" --argjson t "${4:-false}" '
    {full_name: $s, name: ($s | split("/")[1]), private: $p, visibility: (if $p then "private" else "public" end),
     archived: false, default_branch: "main", owner: {login: ($s | split("/")[0]), type: "User"},
     permissions: {admin: true},
     security_and_analysis: {secret_scanning: {status: "enabled"}, secret_scanning_push_protection: {status: "enabled"}}}
    + (if $c == 1 then
        {allow_squash_merge: true, allow_merge_commit: false, allow_rebase_merge: false,
         squash_merge_commit_title: "PR_TITLE", squash_merge_commit_message: "BLANK",
         delete_branch_on_merge: true, allow_auto_merge: true, is_template: $t}
       else
        {allow_squash_merge: true, allow_merge_commit: true, allow_rebase_merge: true,
         squash_merge_commit_title: "COMMIT_OR_PR_TITLE", squash_merge_commit_message: "COMMIT_MESSAGES",
         delete_branch_on_merge: false, allow_auto_merge: false, is_template: false}
       end)'
}

# routes_empty_repo [slug] [private] : a repo that exists with GitHub's defaults
routes_empty_repo() {
  local s="${1:-$S}" p="${2:-false}"
  route "api GET repos/$s" "$(repo_json "$s" 0 "$p")"
  route "api GET repos/$s/vulnerability-alerts" '{"message":"Vulnerability alerts are disabled."}' 1 404
  route "api GET repos/$s/automated-security-fixes" '{"enabled":false,"paused":false}'
  route "api GET repos/$s/code-scanning/default-setup" '{"state":"not-configured","languages":["actions"]}'
  route "api GET repos/$s/immutable-releases" '{"enabled":false,"enforced_by_owner":false}'
  route "api GET repos/$s/actions/permissions" '{"enabled":true,"allowed_actions":"all","sha_pinning_required":false}'
  route "api GET repos/$s/actions/permissions/fork-pr-contributor-approval" '{"approval_policy":"first_time_contributors"}'
  route "api GET repos/$s/actions/permissions/workflow" '{"default_workflow_permissions":"write","can_approve_pull_request_reviews":true}'
  route "api GET repos/$s/rulesets?includes_parents=false&per_page=100" '[]'
  route "api GET repos/$s/labels?per_page=100" '[{"name":"bug","color":"d73a4a","description":"Something is not working"},{"name":"enhancement","color":"a2eeef","description":"New feature or request"}]'
  route "api GET users/octo-owner" '{"login":"octo-owner","id":4242}'
  route "api GET user" '{"login":"octo-owner","id":4242,"plan":{"name":"free"}}'
  route "api GET repos/$s/actions/secrets?per_page=100" '{"total_count":0,"secrets":[]}'
  route "api GET repos/$s/invitations?per_page=100" '[]'
  route "api GET repos/$s/actions/workflows?per_page=100" '{"total_count":0,"workflows":[]}'
}

# routes_configured_repo [profile] [slug] : a repo exactly as team-bootstrap-repo leaves it
routes_configured_repo() {
  local prof="${1:-project}" s="${2:-$S}" tmpl=false
  [ "$prof" = template ] && tmpl=true
  route "api GET repos/$s" "$(repo_json "$s" 1 false "$tmpl")"
  route "api GET repos/$s/vulnerability-alerts" -
  route "api GET repos/$s/automated-security-fixes" '{"enabled":true,"paused":false}'
  route "api GET repos/$s/code-scanning/default-setup" '{"state":"configured","languages":["actions"],"query_suite":"default"}'
  route "api GET repos/$s/immutable-releases" '{"enabled":true,"enforced_by_owner":false}'
  route "api GET repos/$s/actions/permissions" '{"enabled":true,"allowed_actions":"all","sha_pinning_required":true}'
  route "api GET repos/$s/actions/permissions/fork-pr-contributor-approval" '{"approval_policy":"all_external_contributors"}'
  route "api GET repos/$s/actions/permissions/workflow" '{"default_workflow_permissions":"read","can_approve_pull_request_reviews":false}'
  route "api GET repos/$s/rulesets?includes_parents=false&per_page=100" \
    '[{"id":101,"name":"main","target":"branch","source_type":"Repository"},{"id":102,"name":"release-tags","target":"tag","source_type":"Repository"}]'
  route "api GET repos/$s/rulesets/101" "$(github_style "$FIX/ruleset-main-$prof.json" 101)"
  route "api GET repos/$s/rulesets/102" "$(github_style "$FIX/ruleset-tags.json" 102)"
  route "api GET repos/$s/labels?per_page=100" "$(jq -c '. + [{"name":"enhancement","color":"a2eeef","description":"x"}]' "$FIX/standards/config/labels.json")"
  route "api GET users/octo-owner" '{"login":"octo-owner","id":4242}'
  route "api GET repos/$s/environments/staging" '{"name":"staging","protection_rules":[{"id":1,"type":"branch_policy"}],"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}'
  route "api GET repos/$s/environments/production" '{"name":"production","protection_rules":[{"id":2,"type":"required_reviewers","prevent_self_review":false,"reviewers":[{"type":"User","reviewer":{"login":"octo-owner","id":4242}}]},{"id":3,"type":"branch_policy"}],"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}'
  route "api GET repos/$s/environments/*/deployment-branch-policies?per_page=100" '{"total_count":1,"branch_policies":[{"id":7,"name":"main","type":"branch"}]}'
  route "api GET repos/$s/environments/staging/secrets?per_page=100" '{"secrets":[{"name":"DEPLOY_HOST"},{"name":"DEPLOY_USER"},{"name":"DEPLOY_PORT"},{"name":"DEPLOY_SSH_KEY"},{"name":"DEPLOY_KNOWN_HOSTS"},{"name":"APP_URL"},{"name":"HEALTH_URL"},{"name":"BASIC_AUTH_USER"},{"name":"BASIC_AUTH_PASSWORD"}]}'
  route "api GET repos/$s/environments/production/secrets?per_page=100" '{"secrets":[{"name":"DEPLOY_HOST"},{"name":"DEPLOY_USER"},{"name":"DEPLOY_PORT"},{"name":"DEPLOY_SSH_KEY"},{"name":"DEPLOY_KNOWN_HOSTS"},{"name":"APP_URL"},{"name":"HEALTH_URL"}]}'
  route "api GET repos/$s/actions/variables/PROJECT_TIMEZONE" '{"name":"PROJECT_TIMEZONE","value":"Asia/Manila"}'
  route "api GET repos/$s/actions/variables/OWNER_LOGIN" '{"name":"OWNER_LOGIN","value":"octo-owner"}'
  route "api GET repos/$s/actions/variables/STAGING_READY" '{"name":"STAGING_READY","value":"true"}'
  route "api GET repos/$s/actions/variables/PRODUCTION_READY" '{"name":"PRODUCTION_READY","value":"true"}'
  route "api GET repos/$s/actions/secrets?per_page=100" '{"total_count":2,"secrets":[{"name":"RELEASE_PLEASE_TOKEN"},{"name":"PRODUCTION_HEALTH_URL"}]}'
  route "api GET repos/$s/collaborators/octo-agent" -
  route "api GET repos/$s/actions/workflows?per_page=100" '{"total_count":1,"workflows":[{"id":1,"name":"uptime","path":".github/workflows/uptime.yml","state":"active"}]}'
}

# nth_body <glob> <k> : stdin of the k-th call (1-based) whose key matches
nth_body() {
  local line key k=0 n
  while IFS= read -r line; do
    key="${line#*|}"; key="${key#*|}"
    # shellcheck disable=SC2254
    case "$key" in
      $1) k=$((k + 1)); if [ "$k" = "$2" ]; then n="${line%%|*}"; cat "$GH_STUB_DIR/body.$n" 2>/dev/null; return 0; fi ;;
    esac
  done <"$GH_STUB_DIR/log"
  return 1
}

# ------------------------------------------------------------------------------ help
t_help() {
  section "--help and usage errors"
  local c
  for c in $MY_CMDS; do
    run_cmd cmd "$c" --help
    if [ "$RC" = 0 ] && has "Usage: $c"; then pass "$c --help"; else fail "$c --help (exit $RC)" "$OUT"; fi
  done
  expect_rc "team-gh with no arguments: usage" 2 cmd team-gh
  expect_rc "team-post-check with no arguments: usage" 2 cmd team-post-check
  expect_rc "team-bootstrap-repo with no repo: usage" 2 cmd team-bootstrap-repo
  expect_rc "team-bootstrap-repo bad profile: usage" 2 cmd team-bootstrap-repo "$S" --profile nope
  expect_rc "team-bootstrap-repo --visibility without --create: usage" 2 cmd team-bootstrap-repo "$S" --visibility private
  expect_rc "team-bootstrap-repo --create with profile standards: usage" 2 cmd team-bootstrap-repo "$S" --create --profile standards
  expect_rc "team-bootstrap-repo bad timezone: usage" 2 cmd team-bootstrap-repo "$S" --timezone 'Asia/Manila;x'
  expect_rc "team-verify-repo with no repo: usage" 2 cmd team-verify-repo
  expect_rc "team-sync unknown flag: usage" 2 cmd team-sync --bogus
  expect_rc "team-sync --to without a semver tag: usage" 2 cmd team-sync --to v1
  expect_rc "team-merge-if-green without a PR: usage" 2 cmd team-merge-if-green
  expect_rc "team-conflict-check without issues: usage" 2 cmd team-conflict-check
  expect_rc "team-worktree-report bad depth: usage" 2 cmd team-worktree-report --depth x
}

# ------------------------------------------------------------------------------ lib
libcall() {
  OUT=$(/bin/bash -c "set -euo pipefail
    . '$REPO/plugins/team/lib/team-common.sh'; . '$REPO/plugins/team/lib/team-github.sh'
    tg_tmp_init
    $1" 2>&1)
  RC=$?
}

t_lib() {
  section "lib/team-github.sh"
  local f="$T/alt"
  mkdir -p "$f/a/config" "$f/b/config" "$f/c/config" "$f/d/config"
  printf '%s\n' '{"project":["ci / ci","ai-review"]}' >"$f/a/config/required-checks.json"
  printf '%s\n' '{"profiles":{"project":{"required_status_checks":[{"context":"ci / ci","integration_id":15368},{"context":"ai-qa"}]}}}' >"$f/b/config/required-checks.json"
  printf '%s\n' '{"github_actions_app_id":777,"project":[{"name":"ci / ci","source":"actions"},{"name":"ai-review","source":"status"}]}' >"$f/c/config/required-checks.json"
  printf '%s\n' '{"labels":{"bug":{"color":"#D73A4A","description":"b"},"health":"C5DEF5"}}' >"$f/d/config/labels.json"

  libcall "TEAM_STANDARDS_DIR='$f/a' tg_required_checks_json project"
  expect_json "checks: bare list of names" "$OUT" '[{"context":"ci / ci","integration_id":15368},{"context":"ai-review","integration_id":null}]'
  libcall "TEAM_STANDARDS_DIR='$f/b' tg_required_checks_json project"
  expect_json "checks: required_status_checks shape" "$OUT" '[{"context":"ci / ci","integration_id":15368},{"context":"ai-qa","integration_id":null}]'
  libcall "TEAM_STANDARDS_DIR='$f/c' tg_required_checks_json project"
  expect_json "checks: objects with a source, custom app id" "$OUT" '[{"context":"ci / ci","integration_id":777},{"context":"ai-review","integration_id":null}]'
  libcall "TEAM_STANDARDS_DIR='$f/a' tg_required_checks_json standards"
  if [ "$RC" = 5 ]; then pass "checks: unknown profile exits 5"; else fail "checks: unknown profile exits 5 (exit $RC)" "$OUT"; fi
  libcall "TEAM_STANDARDS_DIR='$f/d' tg_labels_json"
  expect_json "labels: object map, colors normalized" "$OUT" '[{"name":"bug","color":"d73a4a","description":"b"},{"name":"health","color":"c5def5","description":""}]'
  libcall "TEAM_STANDARDS_DIR='$f/a' tg_labels_json"
  if [ "$RC" = 5 ] && has "labels.json is missing"; then pass "TEAM_STANDARDS_DIR without the file: exit 5"; else fail "TEAM_STANDARDS_DIR without the file: exit 5 (exit $RC)" "$OUT"; fi

  if [ -r "$REPO/config/required-checks.json" ]; then
    libcall "unset TEAM_STANDARDS_DIR; tg_branch_ruleset_json \"\$(tg_required_checks_json project)\""
    expect_json "repo config/: project ruleset equals research §2(a)" "$OUT" "$(cat "$FIX/ruleset-main-project.json")"
  fi
  libcall "tg_tag_ruleset_json"
  expect_json "tag ruleset equals research §2(b)" "$OUT" "$(cat "$FIX/ruleset-tags.json")"

  libcall "tg_ruleset_matches \"\$(cat '$FIX/ruleset-main-project.json')\" '$(github_style "$FIX/ruleset-main-project.json" 9)' && echo same"
  expect_out "ruleset compare ignores GitHub's extra fields and order" "same"
  libcall "tg_ruleset_matches \"\$(cat '$FIX/ruleset-main-project.json')\" '$(jq -c '(.rules[] | select(.type == "required_status_checks") | .parameters.strict_required_status_checks_policy) = true' "$FIX/ruleset-main-project.json")' || echo differs"
  expect_out "ruleset compare sees a changed rule" "differs"
  libcall "tg_ruleset_matches \"\$(cat '$FIX/ruleset-main-project.json')\" '$(jq -c '(.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[0].integration_id) = 999' "$FIX/ruleset-main-project.json")' || echo differs"
  expect_out "ruleset compare sees a check bound to another app" "differs"

  libcall "tg_remote_parts git@github.com-other:Org/app.git; echo; tg_remote_parts https://github.com/o/r.git; echo; tg_remote_parts ssh://git@github.com-agent:22/o/r"
  expect_out "remote parts: scp-like alias" "github.com-other|Org/app"
  expect_out "remote parts: https" "github.com|o/r"
  expect_out "remote parts: ssh:// with port" "github.com-agent|o/r"
  libcall "echo \"[\$(tg_account_for_remote git@github.com-other:someorg/app.git)]\"; echo \"[\$(tg_account_for_remote https://github.com/octo-owner/x)]\"; echo \"[\$(tg_account_for_remote git@gitlab.example:octo-owner/x.git)]\"; echo \"[\$(tg_account_for_remote git@github.com:someorg/x.git)]\""
  expect_out "account from SSH alias" "[octo-other]"
  expect_out "account from owner login" "[octo-owner]"
  expect_out "unknown host: no account" "[]"
  libcall "tg_same_repo Octo-Owner/Sample-App github.com/octo-owner/sample-app && echo same; tg_same_repo a/b a/c || echo diff"
  expect_out "same repo ignores case and host" "same"
  expect_out "different repos differ" "diff"
  libcall "tg_valid_tz Asia/Manila && echo t1; tg_valid_tz America/Argentina/Buenos_Aires && echo t2; tg_valid_tz UTC && echo t3; tg_valid_tz 'Asia/Manila;rm' || echo f1; tg_valid_tz Mars/Base || echo f2"
  if has t1 && has t2 && has t3 && has f1; then pass "IANA timezone validation"; else fail "IANA timezone validation" "$OUT"; fi
  if [ -d /usr/share/zoneinfo ]; then
    if has f2; then pass "unknown zone rejected (zoneinfo present)"; else fail "unknown zone rejected (zoneinfo present)" "$OUT"; fi
  fi
  libcall "tg_in_list bug \"\$TG_AGENT_LABELS\" && echo in; tg_in_list 'bug feature' \"\$TG_AGENT_LABELS\" || echo spaced"
  if has in && has spaced; then pass "label list membership rejects words with spaces"; else fail "label list membership" "$OUT"; fi

  # Download fallback: a plugin copy that is not inside a dev-standards clone.
  local pc="$T/plugcopy/plugins/team"
  mkdir -p "$pc/bin" "$pc/lib"
  cp "$REPO/plugins/team/lib/team-common.sh" "$REPO/plugins/team/lib/team-github.sh" "$pc/lib/"
  stub_reset
  route "api GET repos/akosiArvin081596/dev-standards/contents/config/required-checks.json?ref=v1" "@$FIX/standards/config/required-checks.json"
  OUT=$(unset TEAM_STANDARDS_DIR; /bin/bash -c "set -euo pipefail; . '$pc/lib/team-common.sh'; . '$pc/lib/team-github.sh'; tg_tmp_init; TG_LOGIN=octo-owner; tg_required_checks_json template" 2>&1)
  RC=$?
  expect_json "config downloaded from GitHub when there is no local copy" "$OUT" \
    '[{"context":"template-ci","integration_id":15368},{"context":"gates / guarded-paths","integration_id":15368},{"context":"gates / pr-title","integration_id":15368},{"context":"ai-review","integration_id":null},{"context":"ai-security","integration_id":null}]'
  ok "download used the contents API as octo-owner" [ "$(acting_for 'api GET repos/akosiArvin081596/dev-standards/contents/config/required-checks.json*')" = octo-owner ]
}

# ------------------------------------------------------------------------------ team-gh
t_gh() {
  section "team-gh"
  local R="$T/gh-proj"
  make_repo "$R" "git@github.com:octo-owner/sample-app.git" octo-owner
  tg() { in_dir "$R" cmd team-gh "$@"; }
  gh_routes() {
    route "pr view 12 --json headRefName,labels*" '{"headRefName":"feat/12-login","labels":[{"name":"bug"}]}'
    route "pr view 77 --json headRefName,labels*" '{"headRefName":"release-please--branches--main","labels":[]}'
    route "pr view 78 --json headRefName,labels*" '{"headRefName":"feat/78-x","labels":[{"name":"autorelease: pending"}]}'
    route "pr view --json headRefName,labels*" '{"headRefName":"feat/12-login","labels":[]}'
    route "pr view https://github.com/octo-owner/sample-app/pull/12 --json*" '{"headRefName":"feat/12-login","labels":[]}'
    route "api GET repos/$S/issues/5" '{"number":5,"title":"x"}'
    route "api GET repos/$S/issues/12" '{"number":12,"pull_request":{"url":"x"}}'
    route "api GET repos/$S/pulls/12" '{"number":12,"head":{"ref":"feat/12-login"},"labels":[]}'
    route "api GET repos/$S/issues/77" '{"number":77,"pull_request":{"url":"x"}}'
    route "api GET repos/$S/pulls/77" '{"number":77,"head":{"ref":"release-please--branches--main"},"labels":[{"name":"autorelease: pending"}]}'
    route "pr list*" '[]'
    route "issue view 5*" '{"number":5}'
    route "api GET repos/$S/pulls" '[]'
    route "api GET search/issues" '{"items":[]}'
    route "api GET repos/$S/actions/variables/OWNER_LOGIN" '{"name":"OWNER_LOGIN","value":"octo-owner"}'
    route "api GET repos/$S/issues/12/events" '[{"event":"labeled","actor":{"login":"octo-owner"},"label":{"name":"owner-approved"}}]'
  }
  stub_reset
  gh_routes

  allowed() {  # allowed <name> <glob that must reach gh> <cmd...>
    local name="$1" glob="$2"
    shift 2
    stub_clear_log
    run_cmd "$@"
    if [ "$RC" = 0 ] && called "$glob"; then pass "allowed: $name"; else fail "allowed: $name (exit $RC)" "$OUT"; fi
  }
  refused() {  # refused <name> <glob that must NOT reach gh> <cmd...>
    local name="$1" glob="$2"
    shift 2
    stub_clear_log
    run_cmd "$@"
    if [ "$RC" = 4 ] && ! called "$glob"; then pass "refused: $name"
    else fail "refused: $name (exit $RC$(called "$glob" && printf ', and gh ran it'))" "$OUT"
    fi
  }

  # reads pass through
  allowed "pr list" "pr list" tg pr list
  ok "reads act as the project account" [ "$(acting_for 'pr list')" = octo-owner ]
  allowed "issue view" "issue view 5" tg issue view 5
  allowed "api GET" "api GET repos/$S/pulls" tg api "repos/$S/pulls"
  allowed "api -X GET with fields" "api GET search/issues" tg api -X GET search/issues -f q=is:open
  allowed "run list" "run list" tg run list
  allowed "subcommand help" "pr merge --help" tg pr merge --help
  # exact forms the skills use
  allowed "skills: api actions/variables/OWNER_LOGIN" "api GET repos/$S/actions/variables/OWNER_LOGIN" tg api "repos/$S/actions/variables/OWNER_LOGIN"
  allowed "skills: api issues/<n>/events --paginate --jq" "api GET repos/$S/issues/12/events" \
    tg api "repos/$S/issues/12/events" --paginate --jq '[.[] | select(.event == "labeled")] | last | .actor.login'
  allowed "skills: run view <id> --log-failed" "run view 123 --log-failed" tg run view 123 --log-failed
  allowed "skills: repo view" "repo view*" tg repo view --json nameWithOwner

  # each allowed write
  stub_clear_log
  run_in "Report body from stdin" tg pr create --title "feat: add login" --body-file -
  if [ "$RC" = 0 ] && [ "$(body_for 'pr create*')" = "Report body from stdin" ]; then pass "allowed: pr create --body-file - (stdin reaches gh)"; else fail "allowed: pr create --body-file -" "$OUT"; fi
  ok "pr create acts as the project account" [ "$(acting_for 'pr create*')" = octo-owner ]
  allowed "pr create with an agent label" "pr create -l bug*" tg pr create -l bug -t "fix: x" -b "y"
  allowed "skills: pr create --base main --title --body-file" "pr create --base main*" tg pr create --base main --title "feat: x" --body-file "$R/README.md"
  allowed "skills: pr edit <n> --body-file <f>" "pr edit 12 --body-file*" tg pr edit 12 --body-file "$R/README.md"
  allowed "pr edit title" "pr edit 12 --title*" tg pr edit 12 --title "feat: better"
  allowed "pr edit body file and base" "pr edit 12 --body-file*" tg pr edit 12 --body-file "$R/README.md" --base main
  allowed "pr edit --add-label needs-info" "pr edit 12 --add-label needs-info" tg pr edit 12 --add-label needs-info
  allowed "pr edit --add-label fixes-main,bug" "pr edit 12 --add-label fixes-main,bug" tg pr edit 12 --add-label fixes-main,bug
  allowed "pr edit --remove-label needs-info" "pr edit 12 --remove-label needs-info" tg pr edit 12 --remove-label needs-info
  allowed "pr edit on the current branch's PR" "pr edit --title*" tg pr edit --title "feat: y"
  allowed "pr comment" "pr comment 12 --body*" tg pr comment 12 --body "looks good"
  allowed "pr comment by URL of this repo" "pr comment https://github.com/octo-owner/sample-app/pull/12*" tg pr comment https://github.com/octo-owner/sample-app/pull/12 -b x
  allowed "pr review --comment" "pr review 12 --comment*" tg pr review 12 --comment --body-file "$R/README.md"
  allowed "pr merge --auto --squash --delete-branch" "pr merge 12 --auto --squash --delete-branch" tg pr merge 12 --auto --squash --delete-branch
  allowed "pr merge --auto -s --match-head-commit" "pr merge 12 --auto -s*" tg pr merge 12 --auto -s --match-head-commit "$SHA_A"
  stub_clear_log
  run_in "Health finding body" tg issue create --label health --title "Health: oversized files" --body-file -
  if [ "$RC" = 0 ] && [ "$(body_for 'issue create*')" = "Health finding body" ]; then pass "allowed: issue create --label health --body-file - (team-health form)"; else fail "allowed: issue create --label health" "$OUT"; fi
  allowed "issue create with labels bug,client-request" "issue create*" tg issue create -t "x" -b "y" -l bug,client-request
  allowed "issue comment" "issue comment 5*" tg issue comment 5 --body "repro steps"
  allowed "issue edit --add-label needs-info" "issue edit 5 --add-label needs-info" tg issue edit 5 --add-label needs-info
  allowed "-R naming this repo" "pr comment 12*" tg pr comment 12 -b x -R octo-owner/sample-app
  allowed "-R naming this repo, other case" "pr list*" tg pr list -R Octo-Owner/Sample-App

  # pr review / merge forms
  refused "pr review --approve" "pr review*" tg pr review 12 --approve
  refused "pr review -a" "pr review*" tg pr review 12 -a
  refused "pr review --request-changes" "pr review*" tg pr review 12 --request-changes -b no
  refused "pr review without --comment" "pr review*" tg pr review 12 -b hello
  refused "pr merge without --auto" "pr merge*" tg pr merge 12 --squash
  refused "pr merge without --squash" "pr merge*" tg pr merge 12 --auto
  refused "pr merge --admin" "pr merge*" tg pr merge 12 --auto --squash --admin
  refused "pr merge --merge" "pr merge*" tg pr merge 12 --auto --merge
  refused "pr merge --rebase" "pr merge*" tg pr merge 12 --auto --rebase
  refused "pr merge -r" "pr merge*" tg pr merge 12 --auto -s -r
  refused "pr merge --subject" "pr merge*" tg pr merge 12 --auto --squash --subject x
  refused "pr merge --disable-auto" "pr merge*" tg pr merge 12 --disable-auto
  refused "pr merge with --help swallowed as a value" "pr merge*" tg pr merge 12 --auto --squash --subject --help
  refused "pr merge --admin hidden before --help" "pr merge*" tg pr merge 12 --admin --help
  refused "combined short flags" "pr merge*" tg pr merge 12 --auto -sd

  # release PRs (checked online)
  refused "merge a release PR (head release-please--*)" "pr merge*" tg pr merge 77 --auto --squash
  refused "comment on a release PR" "pr comment*" tg pr comment 77 -b x
  refused "review a release PR" "pr review*" tg pr review 77 --comment -b x
  refused "edit a PR labelled autorelease: pending" "pr edit*" tg pr edit 78 --title x
  refused "issue comment on a release PR number" "issue comment*" tg issue comment 77 -b x
  refused "issue edit label on a release PR number" "issue edit*" tg issue edit 77 --add-label bug
  refused "PR that can't be read (fails closed)" "pr comment*" tg pr comment 99 -b x
  git -C "$R" checkout -q -b release-please--branches--main
  refused "pr create from a release-please branch" "pr create*" tg pr create -t "chore: release" -b x
  git -C "$R" checkout -q main
  refused "pr create --head release-please--*" "pr create*" tg pr create -t x -b y --head release-please--branches--main

  # labels
  refused "owner-approved with -R (not the canonical form)" "pr edit*" tg pr edit 12 --add-label owner-approved -R "$S"
  refused "owner-approved with --add-label=" "pr edit*" tg pr edit 12 --add-label=owner-approved
  refused "owner-approved inside a list" "pr edit*" tg pr edit 12 --add-label bug,owner-approved
  refused "owner-approved in another case" "pr edit*" tg pr edit 12 --add-label Owner-Approved
  refused "owner-approved on #PR form" "pr edit*" tg pr edit "#12" --add-label owner-approved
  refused "owner-approved through issue edit" "issue edit*" tg issue edit 12 --add-label owner-approved
  refused "owner-approved at pr create" "pr create*" tg pr create -t x -b y -l owner-approved
  refused "remove guarded" "pr edit*" tg pr edit 12 --remove-label guarded
  refused "remove high-risk" "pr edit*" tg pr edit 12 --remove-label high-risk
  refused "remove tests-changed" "pr edit*" tg pr edit 12 --remove-label tests-changed
  refused "remove owner-approved" "pr edit*" tg pr edit 12 --remove-label owner-approved
  refused "add guarded" "pr edit*" tg pr edit 12 --add-label guarded
  refused "issue create --label incident" "issue create*" tg issue create -t x -b y --label incident
  refused "issue create --label main-red" "issue create*" tg issue create -t x -b y -l main-red
  refused "issue create with a mixed label list" "issue create*" tg issue create -t x -b y -l health,high-risk
  refused "issue edit --remove-label" "issue edit*" tg issue edit 5 --remove-label needs-info
  refused "issue edit two issues" "issue edit*" tg issue edit 5 6 --add-label bug
  refused "pr edit --add-reviewer" "pr edit*" tg pr edit 12 --add-reviewer someone
  refused "pr comment --delete-last" "pr comment*" tg pr comment 12 --delete-last

  # repo targeting
  refused "-R another repo" "pr comment*" tg pr comment 12 -b x -R someone/else
  refused "--repo=another repo" "pr list*" tg pr list --repo=someone/else
  refused "-Ranother repo (attached)" "pr list*" tg pr list -Rsomeone/else
  refused "-R on a read too" "pr list*" tg pr list -R someone/else
  refused "PR URL of another repo" "pr comment*" tg pr comment https://github.com/someone/else/pull/1 -b x
  stub_clear_log
  OUT=$(cd "$R" && GH_REPO=someone/else /bin/bash "$BIN/team-gh" pr list 2>&1); RC=$?
  if [ "$RC" = 4 ] && ! called "pr list*"; then pass "refused: GH_REPO naming another repo"; else fail "refused: GH_REPO naming another repo (exit $RC)" "$OUT"; fi
  stub_clear_log
  OUT=$(cd "$T/home" && /bin/bash "$BIN/team-gh" pr list -R "$S" 2>&1); RC=$?
  if [ "$RC" = 4 ]; then pass "refused: -R outside a checkout"; else fail "refused: -R outside a checkout (exit $RC)" "$OUT"; fi

  # gh api writes
  refused "api -X POST" "api POST*" tg api -X POST "repos/$S/issues"
  refused "api --method PATCH" "api PATCH*" tg api --method PATCH "repos/$S"
  refused "api --method=put" "api PUT*" tg api --method=put "repos/$S/topics"
  refused "api -XDELETE" "api DELETE*" tg api -XDELETE "repos/$S/labels/bug"
  refused "api -f without -X GET" "api POST*" tg api "repos/$S/issues" -f title=x
  refused "api -F" "api POST*" tg api "repos/$S/statuses/$SHA_A" -F state=success
  refused "api --field" "api POST*" tg api "repos/$S/issues" --field title=x
  refused "api --raw-field" "api POST*" tg api "repos/$S/issues" --raw-field title=x
  refused "api --input" "api POST*" tg api "repos/$S/rulesets" --input "$R/README.md"
  refused "api graphql query (POST)" "api POST*" tg api graphql -f 'query={ viewer { login } }'
  refused "api graphql mutation even with -X GET" "api *graphql*" tg api -X GET graphql -f 'query=mutation { addStar(input:{}) { clientMutationId } }'
  refused "api --verbose" "api *" tg api --verbose "repos/$S"
  refused "api --hostname elsewhere" "api *" tg api --hostname evil.example "repos/$S"
  refused "api method-override header" "api *" tg api -H "X-HTTP-Method-Override: DELETE" "repos/$S"

  # everything else
  refused "release create" "release*" tg release create v1.0.0
  refused "release delete" "release*" tg release delete v1.0.0
  refused "secret set" "secret*" tg secret set X
  refused "variable set" "variable*" tg variable set X --body y
  refused "workflow run" "workflow*" tg workflow run ci.yml
  refused "workflow disable" "workflow*" tg workflow disable ci.yml
  refused "label create" "label*" tg label create x
  refused "repo edit" "repo*" tg repo edit --visibility private
  refused "repo delete" "repo*" tg repo delete "$S" --yes
  refused "auth token" "auth*" tg auth token
  refused "auth status" "auth*" tg auth status -t
  refused "auth switch" "auth*" tg auth switch
  refused "alias set" "alias*" tg alias set co "pr checkout"
  refused "extension install" "extension*" tg extension install x/y
  refused "pr close" "pr close*" tg pr close 12
  refused "pr ready" "pr ready*" tg pr ready 12
  refused "pr checkout" "pr checkout*" tg pr checkout 12
  refused "issue close" "issue close*" tg issue close 5
  refused "run rerun" "run rerun*" tg run rerun 1
  refused "ruleset (no writes exist, but nothing besides reads)" "ruleset delete*" tg ruleset delete 1
  refused "flags before the command" "*" tg --jq . pr list

  # accounts: agent account and the owner's canonical owner-approved form
  write_config agent
  stub_clear_log
  run_cmd tg pr comment 12 -b x
  ok "with an agent line, writes act as the agent" [ "$(acting_for 'pr comment 12*')" = octo-agent ]
  stub_clear_log
  run_cmd tg pr list
  ok "with an agent line, reads act as the agent" [ "$(acting_for 'pr list')" = octo-agent ]
  stub_clear_log
  run_cmd tg pr edit 12 --add-label owner-approved
  if [ "$RC" = 0 ] && [ "$(acting_for 'pr edit 12 --add-label owner-approved')" = octo-owner ]; then
    pass "owner-approved canonical form runs as the OWNER even with an agent account"
  else
    fail "owner-approved canonical form runs as the OWNER (exit $RC, acting $(acting_for 'pr edit*'))" "$OUT"
  fi
  ok "owner-approved: the release check also ran as the owner" [ "$(acting_for 'pr view 12 --json*')" = octo-owner ]
  refused "owner-approved canonical form on a release PR" "pr edit*" tg pr edit 77 --add-label owner-approved
  write_config noagent
  stub_clear_log
  run_cmd tg pr edit 12 --add-label owner-approved
  ok "owner-approved canonical form without an agent: owner" [ "$(acting_for 'pr edit 12 --add-label owner-approved')" = octo-owner ]

  touch "$GH_STUB_DIR/noauth-octo-owner"
  expect_rc "gh not logged in as the project account: exit 5" 5 tg pr comment 12 -b x
  rm -f "$GH_STUB_DIR/noauth-octo-owner"
  if grep -Eq "$TOKEN_RE" "$GH_STUB_DIR/log"; then fail "token appeared in a gh argv"; else pass "token never appears in gh arguments (only GH_TOKEN)"; fi
}

# ------------------------------------------------------------------------------ team-post-check
t_postcheck() {
  section "team-post-check"
  local R="$T/pc-proj" d140 d141
  make_repo "$R" "git@github.com:octo-owner/sample-app.git" octo-owner
  pc() { in_dir "$R" cmd team-post-check "$@"; }
  d140=$(printf 'x%.0s' $(seq 1 140))
  d141="${d140}y"
  stub_reset
  expect_rc "short sha: usage" 2 pc abc1234 ai-review success ok
  expect_rc "unknown context: usage" 2 pc "$SHA_A" ai-other success ok
  expect_rc "unknown state: usage" 2 pc "$SHA_A" ai-review approved ok
  expect_rc "141-character description: usage" 2 pc "$SHA_A" ai-review success "$d141"
  expect_rc "two-line description: usage" 2 pc "$SHA_A" ai-review success "$(printf 'a\nb')"
  expect_rc "http:// target URL: usage" 2 pc "$SHA_A" ai-review success ok --target-url http://example.com/x
  expect_rc "missing description: usage" 2 pc "$SHA_A" ai-review success
  ok "validation never reached GitHub" [ "$(count_calls '*')" = 0 ]

  route "api GET repos/$S/commits/$SHA_A/pulls" '[{"number":77,"head":{"ref":"release-please--branches--main"},"labels":[]}]'
  expect_rc "commit of a release PR: refused" 4 pc "$SHA_A" ai-review success ok
  ok "release PR: no status posted" not called "api POST*"

  stub_reset
  route "api GET repos/$S/commits/$SHA_A/pulls" '[{"number":12,"head":{"ref":"feat/12-login"},"labels":[]}]'
  expect_rc "posts a status (140-char description, target URL)" 0 pc "$SHA_A" ai-review success "$d140" --target-url "https://github.com/$S/pull/12#review"
  expect_json "status request body" "$(body_for "api POST repos/$S/statuses/$SHA_A")" \
    "{\"state\":\"success\",\"context\":\"ai-review\",\"description\":\"$d140\",\"target_url\":\"https://github.com/$S/pull/12#review\"}"
  ok "status posted as the project account" [ "$(acting_for "api POST repos/$S/statuses/$SHA_A")" = octo-owner ]
  stub_clear_log
  expect_rc "upper-case sha accepted" 0 pc "$(printf '%s' "$SHA_A" | tr 'abcdef' 'ABCDEF')" ai-qa pending "QA running"
  ok "upper-case sha posted lower-cased" called "api POST repos/$S/statuses/$SHA_A"
  expect_json "pending body without target_url" "$(body_for "api POST repos/$S/statuses/$SHA_A")" '{"state":"pending","context":"ai-qa","description":"QA running"}'
  write_config agent
  stub_clear_log
  run_cmd pc "$SHA_A" ai-security failure "SQL injection in search"
  ok "with an agent line, the status is posted as the agent" [ "$(acting_for "api POST repos/$S/statuses/$SHA_A")" = octo-agent ]
  write_config noagent
  stub_reset
  route_err "api GET repos/$S/commits/$SHA_A/pulls" 500
  expect_rc "can't list the commit's PRs: fail, no post" 1 pc "$SHA_A" ai-review success ok
  ok "no post after a failed release check" not called "api POST*"
  stub_reset
  route "api GET repos/$S/commits/$SHA_A/pulls" '[]'
  route_err "api POST repos/$S/statuses/$SHA_A" 422
  expect_rc "GitHub rejects the status: exit 1" 1 pc "$SHA_A" ai-review success ok
}

# shellcheck source=run-groups.sh
. "$HERE/run-groups.sh"

for g in help lib gh postcheck bootstrap verify sync conflict worktree storetoken merge shellcheck; do
  if want "$g"; then "t_$g"; fi
done

net_guard_final
printf '\n%d passed, %d failed\n' "$N_PASS" "$N_FAIL"
if [ "$N_FAIL" -gt 0 ]; then printf 'RESULT: FAIL\n'; exit 1; fi
printf 'RESULT: PASS\n'
exit 0
