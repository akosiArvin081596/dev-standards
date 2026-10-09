# shellcheck shell=bash disable=SC2329,SC2317,SC2016  # groups run as "t_$g"; issue bodies hold literal backticks
# Test groups for run.sh (sourced): bootstrap verify sync conflict worktree storetoken merge shellcheck.
# Uses the helpers, routes and variables defined in helpers.sh and run.sh.

# ------------------------------------------------------------------------------ team-bootstrap-repo
t_bootstrap() {
  section "team-bootstrap-repo"
  local R="$T/bs-proj" plan1 plan2 lbl
  make_repo "$R" "git@github.com:octo-owner/sample-app.git" octo-owner Asia/Manila
  bs() { in_dir "$R" cmd team-bootstrap-repo "$@"; }
  bs_out() { in_dir "$T/home" cmd team-bootstrap-repo "$@"; }   # outside any project
  printf '%s' "$KEYCHAIN_TOKEN" >"$SEC_STUB_DIR/item"

  # --- plan, project profile, empty repo
  stub_reset
  routes_empty_repo
  expect_rc "plan (project, empty repo) exits 0" 0 bs "$S"
  expect_out "plan: acts as the owner" "acting as octo-owner"
  expect_out "plan: merge settings update" "[update]   merge settings: allow_merge_commit true→false"
  expect_out "plan: branch ruleset create" '[create]   ruleset "main": default branch: PR required (0 approvals, squash only)'
  expect_out "plan: required checks bound to the Actions app" "ci / ci [GitHub Actions app 15368], gates / guarded-paths [GitHub Actions app 15368], gates / pr-title [GitHub Actions app 15368], ai-review [any source], ai-security [any source], ai-qa [any source]"
  expect_out "plan: tag ruleset create" '[create]   ruleset "release-tags": refs/tags/v*'
  expect_out "plan: secret scanning already on" "[ok]       secret scanning + push protection"
  expect_out "plan: Dependabot alerts" "[update]   Dependabot alerts: off→on"
  expect_out "plan: Dependabot security updates" "[update]   Dependabot security updates: off→on"
  expect_out "plan: CodeQL when a language is detected" "[create]   CodeQL default setup (detected: actions)"
  expect_out "plan: immutable releases" "[update]   immutable releases: off→on"
  expect_out "plan: SHA pinning" "sha_pinning_required false→true"
  expect_out "plan: fork PR approval" "approval_policy first_time_contributors→all_external_contributors"
  expect_out "plan: workflow token" "default_workflow_permissions write→read, can_approve_pull_request_reviews true→false"
  expect_out "plan: existing label bug updated" "[update]   label bug: description"
  expect_out "plan: missing label created" "[create]   label owner-approved (#0e8a16)"
  expect_out "plan: environment staging" "[create]   environment staging: deploys from main only"
  expect_out "plan: environment production reviewer" "[create]   environment production: deploys from main only, octo-owner must approve (self-review allowed)"
  expect_out "plan: OWNER_LOGIN variable" "[create]   variable OWNER_LOGIN=octo-owner"
  expect_out "plan: PROJECT_TIMEZONE from ops/project.conf" "[create]   variable PROJECT_TIMEZONE=Asia/Manila"
  expect_out "plan: release token from the keychain" "[create]   secret RELEASE_PLEASE_TOKEN from keychain item team-release-please-token (piped, never printed)"
  expect_out "plan: lists missing provision secrets" "[missing]  repo secret PRODUCTION_HEALTH_URL"
  expect_out "plan: no agent account" "[skip]     no agent account"
  expect_out "plan: footer" "Nothing changed. Re-run with --apply"
  ok "plan: no GitHub writes" not any_write
  ok "plan: keychain not touched" [ ! -s "$SEC_STUB_DIR/security.log" ]
  plan1="$OUT"
  run_cmd bs "$S"
  plan2="$OUT"
  ok "plan: same output when run twice" [ "$plan1" = "$plan2" ]

  # --- apply, project profile, empty repo, with an agent account
  write_config agent
  stub_reset
  routes_empty_repo
  route "api GET repos/$S/collaborators/octo-agent" '{"message":"Not Found"}' 1 404
  expect_rc "apply (project) exits 0" 0 bs "$S" --apply
  expect_json "apply: branch ruleset body is research §2(a) exactly" "$(nth_body "api POST repos/$S/rulesets" 1)" "$(cat "$FIX/ruleset-main-project.json")"
  expect_json "apply: tag ruleset body is research §2(b) exactly" "$(nth_body "api POST repos/$S/rulesets" 2)" "$(cat "$FIX/ruleset-tags.json")"
  expect_json "apply: merge settings body" "$(body_for "api PATCH repos/$S")" \
    '{"allow_squash_merge":true,"allow_merge_commit":false,"allow_rebase_merge":false,"squash_merge_commit_title":"PR_TITLE","squash_merge_commit_message":"BLANK","delete_branch_on_merge":true,"allow_auto_merge":true,"is_template":false}'
  ok "apply: Dependabot alerts PUT" called "api PUT repos/$S/vulnerability-alerts"
  ok "apply: security updates PUT" called "api PUT repos/$S/automated-security-fixes"
  expect_json "apply: CodeQL default setup body" "$(body_for "api PATCH repos/$S/code-scanning/default-setup")" '{"state":"configured","query_suite":"default"}'
  ok "apply: immutable releases PUT" called "api PUT repos/$S/immutable-releases"
  expect_json "apply: actions permissions body" "$(body_for "api PUT repos/$S/actions/permissions")" '{"enabled":true,"allowed_actions":"all","sha_pinning_required":true}'
  expect_json "apply: fork approval body" "$(body_for "api PUT repos/$S/actions/permissions/fork-pr-contributor-approval")" '{"approval_policy":"all_external_contributors"}'
  expect_json "apply: workflow token body" "$(body_for "api PUT repos/$S/actions/permissions/workflow")" '{"default_workflow_permissions":"read","can_approve_pull_request_reviews":false}'
  ok "apply: 11 labels created" [ "$(count_calls "api POST repos/$S/labels")" = 11 ]
  expect_json "apply: label bug updated" "$(body_for "api PATCH repos/$S/labels/bug")" '{"new_name":"bug","color":"d73a4a","description":"Something is broken"}'
  lbl=$(nth_body "api POST repos/$S/labels" 5)
  expect_json "apply: label owner-approved body" "$lbl" "$(jq -c '.[] | select(.name == "owner-approved")' "$FIX/standards/config/labels.json")"
  expect_json "apply: staging environment body" "$(body_for "api PUT repos/$S/environments/staging")" \
    '{"wait_timer":0,"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}'
  expect_json "apply: production environment body (owner id, self-review allowed)" "$(body_for "api PUT repos/$S/environments/production")" \
    '{"wait_timer":0,"prevent_self_review":false,"reviewers":[{"type":"User","id":4242}],"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}'
  ok "apply: branch policy main for both environments" [ "$(count_calls "api POST repos/$S/environments/*/deployment-branch-policies")" = 2 ]
  expect_json "apply: branch policy body" "$(body_for "api POST repos/$S/environments/production/deployment-branch-policies")" '{"name":"main","type":"branch"}'
  expect_json "apply: OWNER_LOGIN variable body" "$(nth_body "api POST repos/$S/actions/variables" 1)" '{"name":"OWNER_LOGIN","value":"octo-owner"}'
  expect_json "apply: PROJECT_TIMEZONE variable body" "$(nth_body "api POST repos/$S/actions/variables" 2)" '{"name":"PROJECT_TIMEZONE","value":"Asia/Manila"}'
  ok "apply: release token piped into gh secret set (stdin)" [ "$(body_for "secret set RELEASE_PLEASE_TOKEN --repo $S")" = "$KEYCHAIN_TOKEN" ]
  ok "apply: secret set as the owner" [ "$(acting_for "secret set RELEASE_PLEASE_TOKEN*")" = octo-owner ]
  ok "apply: token never in a gh argv" not grep -q "$KEYCHAIN_TOKEN" "$GH_STUB_DIR/log"
  ok "apply: token never in a security argv" not grep -q "$KEYCHAIN_TOKEN" "$SEC_STUB_DIR/security.log"
  ok "apply: agent invited as collaborator" called "api PUT repos/$S/collaborators/octo-agent"
  ok "apply: every write acts as the owner, never the agent" not grep -q '|octo-agent|' "$GH_STUB_DIR/log"
  ok "apply: secret scanning not touched (already on)" not grep -q 'security_and_analysis' "$GH_STUB_DIR"/body.* 2>/dev/null
  write_config noagent

  # --- apply without the keychain item: everything else applied, then wait for the owner
  rm -f "$SEC_STUB_DIR/item"
  stub_reset
  routes_empty_repo
  expect_rc "apply without the keychain item exits 6 (waiting for the owner)" 6 bs "$S" --apply
  expect_out "apply: tells the owner to run team-store-token" "run team-store-token in a normal terminal"
  ok "apply: no secret set without the item" not called "secret set*"
  ok "apply: the rest was applied" called "api POST repos/$S/rulesets"
  printf '%s' "$KEYCHAIN_TOKEN" >"$SEC_STUB_DIR/item"

  # --- profiles standards and template
  stub_reset
  routes_empty_repo
  expect_rc "plan (standards) exits 0" 0 bs_out "$S" --profile standards
  expect_out "standards: self-test is required" "self-test [GitHub Actions app 15368], ci / ci"
  expect_out "standards: no environments" "[skip]     environments: only project repos deploy (profile standards)"
  expect_out "standards: release token needed" "[create]   secret RELEASE_PLEASE_TOKEN"
  expect_out "standards: no timezone needed" "[skip]     PROJECT_TIMEZONE: not needed for profile standards"
  expect_no_out "standards: no ai-qa" "ai-qa"
  stub_reset
  routes_empty_repo
  expect_rc "apply (standards) exits 0" 0 bs_out "$S" --profile standards --apply
  expect_json "standards: ruleset body" "$(nth_body "api POST repos/$S/rulesets" 1)" "$(cat "$FIX/ruleset-main-standards.json")"
  ok "standards: no environment created" not called "api PUT repos/$S/environments/*"
  stub_reset
  routes_empty_repo
  expect_rc "plan (template) exits 0" 0 bs_out "$S" --profile template
  expect_out "template: is_template turned on" "is_template false→true"
  expect_out "template: template-ci required" "template-ci [GitHub Actions app 15368]"
  expect_out "template: no release token" "[skip]     secret RELEASE_PLEASE_TOKEN: the template repo never releases"
  stub_reset
  routes_empty_repo
  expect_rc "apply (template) exits 0" 0 bs_out "$S" --profile template --apply --timezone Asia/Manila
  expect_json "template: ruleset body" "$(nth_body "api POST repos/$S/rulesets" 1)" "$(cat "$FIX/ruleset-main-template.json")"
  ok "template: is_template=true sent" [ "$(body_for "api PATCH repos/$S" | jq -r .is_template)" = true ]
  ok "template: --timezone sets PROJECT_TIMEZONE" [ "$(nth_body "api POST repos/$S/actions/variables" 2 | jq -r .value)" = "Asia/Manila" ]
  ok "template: no secret set" not called "secret set*"

  # --- already configured: all ok, nothing to change
  write_config agent
  stub_reset
  routes_configured_repo project
  expect_rc "configured repo: plan exits 0" 0 bs "$S"
  expect_out "configured repo: nothing to change" "0 to change, 0 failed"
  expect_no_out "configured repo: no create lines" "[create]"
  expect_no_out "configured repo: no update lines" "[update]"
  ok "configured repo: no writes" not any_write
  stub_reset
  routes_configured_repo project
  expect_rc "configured repo: --apply is a no-op" 0 bs "$S" --apply
  ok "configured repo: --apply wrote nothing" not any_write
  write_config noagent

  # --- drift: one ruleset rule changed, a label recolored, an extra branch policy
  stub_reset
  route "api GET repos/$S/rulesets/101" "$(jq -c '(.rules[] | select(.type == "required_status_checks") | .parameters.strict_required_status_checks_policy) = true | . + {id: 101}' "$FIX/ruleset-main-project.json")"
  route "api GET repos/$S/environments/staging/deployment-branch-policies?per_page=100" '{"branch_policies":[{"id":7,"name":"main","type":"branch"},{"id":8,"name":"release/*","type":"branch"}]}'
  routes_configured_repo project
  expect_rc "drift: plan exits 0" 0 bs "$S"
  expect_out "drift: ruleset update shown" '[update]   ruleset "main" (differs:'
  expect_out "drift: extra branch policy removed" "[delete]   environment staging: remove branch policy release/* (branch)"
  stub_reset
  route "api GET repos/$S/rulesets/101" "$(jq -c '(.rules[] | select(.type == "required_status_checks") | .parameters.strict_required_status_checks_policy) = true | . + {id: 101}' "$FIX/ruleset-main-project.json")"
  routes_configured_repo project
  expect_rc "drift: apply exits 0" 0 bs "$S" --apply
  expect_json "drift: PUT sends the designed ruleset" "$(body_for "api PUT repos/$S/rulesets/101")" "$(cat "$FIX/ruleset-main-project.json")"

  # --- read failure
  stub_reset
  route_err "api GET repos/$S/actions/permissions" 500
  routes_configured_repo project
  expect_rc "a failed read makes the plan fail" 1 bs "$S"
  expect_out "failed read is shown" "[fail]     Actions allowed, pinned to full commit SHAs: could not read (HTTP 500)"

  # --- private repo on GitHub Free
  stub_reset
  routes_empty_repo "$S" true
  expect_rc "private on Free: apply exits 6 (switch to the private fallback)" 6 bs "$S" --apply
  expect_out "private on Free: says what GitHub won't allow" "GitHub won't allow here: rulesets"
  expect_out "private on Free: rulesets skipped" '[skip]     rulesets "main" and "release-tags": not enforced on private repos on GitHub Free'
  expect_out "private on Free: environments skipped" "[skip]     environments staging/production: not available for private repos on GitHub Free"
  expect_out "private on Free: tells to switch" "[action]   set VISIBILITY=private in ops/project.conf"
  ok "private on Free: no ruleset sent" not called "api POST repos/$S/rulesets"
  ok "private on Free: no environment sent" not called "api PUT repos/$S/environments/*"
  ok "private on Free: no fork policy sent" not called "api PUT repos/$S/actions/permissions/fork-pr-contributor-approval"
  ok "private on Free: no CodeQL setup" not called "api PATCH repos/$S/code-scanning/default-setup"
  ok "private on Free: auto-merge left out of the settings" [ "$(body_for "api PATCH repos/$S" | jq 'has("allow_auto_merge")')" = false ]
  ok "private on Free: the rest applied (labels, Dependabot, token)" called "api POST repos/$S/labels"

  # --- missing repo and --create
  stub_reset
  route "api GET repos/octo-owner/new-app" '{"message":"Not Found"}' 1 404
  expect_rc "missing repo without --create: exit 1" 1 bs_out octo-owner/new-app
  expect_out "missing repo: suggests --create" "add --create"
  stub_reset
  route "api GET repos/octo-owner/new-app" '{"message":"Not Found"}' 1 404
  route "api GET users/octo-owner" '{"login":"octo-owner","id":4242}'
  expect_rc "--create plan exits 0" 0 bs_out octo-owner/new-app --create --timezone America/New_York
  expect_out "--create plan: repository from the template" "[create]   repository octo-owner/new-app (public) from template akosiArvin081596/project-starter"
  expect_out "--create plan: then the settings" '[create]   ruleset "main"'
  expect_out "--create plan: timezone" "[create]   variable PROJECT_TIMEZONE=America/New_York"
  ok "--create plan: nothing generated" not called "api POST repos/akosiArvin081596/project-starter/generate"
  stub_reset
  route "api GET repos/octo-owner/new-app" '{"message":"Not Found"}' '1!' 404
  route "api GET repos/octo-owner/new-app/branches/main" '{"message":"Branch not found"}' '1!' 404
  route "api GET repos/octo-owner/new-app/branches/main" '{"name":"main"}'
  routes_empty_repo octo-owner/new-app
  expect_rc "--create --apply exits 0" 0 bs_out octo-owner/new-app --create --apply --timezone Asia/Manila
  expect_json "--create: generate request" "$(body_for "api POST repos/akosiArvin081596/project-starter/generate")" \
    '{"owner":"octo-owner","name":"new-app","private":false,"include_all_branches":false}'
  ok "--create: generated as the owner" [ "$(acting_for "api POST repos/akosiArvin081596/project-starter/generate")" = octo-owner ]
  ok "--create: polled until the default branch existed" [ "$(count_calls "api GET repos/octo-owner/new-app/branches/main")" = 2 ]
  expect_out "--create: default branch ready" "default branch main is ready"
  ok "--create: settings applied after creation" called "api POST repos/octo-owner/new-app/rulesets"
  stub_reset
  route "api GET repos/octo-owner/new-app" '{"message":"Not Found"}' '1!' 404
  routes_empty_repo octo-owner/new-app
  route "api GET repos/octo-owner/new-app/branches/main" '{"message":"Branch not found"}' 1 404
  OUT=$(cd "$T/home" && TEAM_BOOTSTRAP_POLL_TRIES=3 /bin/bash "$BIN/team-bootstrap-repo" octo-owner/new-app --create --apply 2>&1); RC=$?
  if [ "$RC" = 1 ] && has "isn't ready yet"; then pass "--create: gives up after bounded polling"; else fail "--create: gives up after bounded polling (exit $RC)" "$OUT"; fi
  ok "--create: polled exactly 3 times" [ "$(count_calls "api GET repos/octo-owner/new-app/branches/main")" = 3 ]
  ok "--create: no settings applied when not ready" not called "api POST repos/octo-owner/new-app/rulesets"
  stub_reset
  route "api GET repos/octo-owner/new-app" '{"message":"Not Found"}' 1 404
  expect_rc "--create --visibility private plan on Free" 0 bs_out octo-owner/new-app --create --visibility private
  expect_out "--create private: generate private" "[create]   repository octo-owner/new-app (private)"
  expect_out "--create private: fallback note" "GitHub won't allow here"

  # --- prerequisites and conflicts
  stub_reset
  expect_rc "owner not in accounts.conf: exit 5" 5 bs_out stranger/repo
  touch "$GH_STUB_DIR/noauth-octo-owner"
  expect_rc "gh not logged in as the owner: exit 5" 5 bs_out "$S"
  rm -f "$GH_STUB_DIR/noauth-octo-owner"
  routes_configured_repo project
  expect_rc "--timezone conflicting with ops/project.conf: usage" 2 bs "$S" --timezone America/New_York
  expect_rc "--timezone equal to ops/project.conf is fine" 0 bs "$S" --timezone Asia/Manila
}

# ------------------------------------------------------------------------------ team-verify-repo
t_verify() {
  section "team-verify-repo"
  local R="$T/vr-proj"
  make_repo "$R" "git@github.com:octo-owner/sample-app.git" octo-owner Asia/Manila
  vr() { in_dir "$R" cmd team-verify-repo "$@"; }

  write_config agent
  stub_reset
  routes_configured_repo project
  expect_rc "configured repo: exit 0" 0 vr "$S"
  expect_out "table header" "STATE  ITEM"
  expect_out "ruleset main passes" "PASS   ruleset main"
  expect_out "ruleset release-tags passes" "PASS   ruleset release-tags"
  expect_out "required check row" "PASS   required check ci / ci"
  ok "status check row (any source)" grep -Eq '^PASS +required check ai-qa +any source$' <<<"$OUT"
  expect_out "label row" "PASS   label owner-approved"
  expect_out "production reviewer row" "PASS   environment production reviewer"
  expect_out "OWNER_LOGIN row" "PASS   variable OWNER_LOGIN"
  expect_out "timezone row" "PASS   variable PROJECT_TIMEZONE"
  expect_out "secret name row" "PASS   secret RELEASE_PLEASE_TOKEN"
  expect_out "environment secret row" "PASS   staging secret BASIC_AUTH_PASSWORD"
  expect_out "agent collaborator row" "PASS   agent octo-agent collaborator"
  expect_out "workflows row" "PASS   workflows enabled"
  expect_out "summary" "0 failed"
  expect_no_out "no FAIL rows" "FAIL "
  ok "verify made no writes" not any_write
  write_config noagent

  stub_reset
  routes_empty_repo
  expect_rc "empty repo: exit 1" 1 vr "$S"
  expect_out "empty: ruleset missing" "FAIL   ruleset main"
  expect_out "empty: label missing" "FAIL   label feature"
  ok "empty: setting differs" grep -Eq '^FAIL +setting allow_merge_commit +expected false, got true$' <<<"$OUT"
  expect_out "empty: environment missing" "FAIL   environment staging"
  expect_out "empty: OWNER_LOGIN missing" "FAIL   variable OWNER_LOGIN"
  expect_out "empty: timezone missing" "FAIL   variable PROJECT_TIMEZONE"
  expect_out "empty: release token missing" "FAIL   secret RELEASE_PLEASE_TOKEN"
  expect_out "empty: Dependabot alerts off" "FAIL   Dependabot alerts"

  stub_reset
  route "api GET repos/$S/actions/workflows?per_page=100" '{"workflows":[{"id":1,"name":"uptime","path":".github/workflows/uptime.yml","state":"disabled_inactivity"},{"id":2,"name":"ci","path":".github/workflows/ci.yml","state":"active"}]}'
  routes_configured_repo project
  expect_rc "disabled scheduled workflow: still exit 0" 0 vr "$S"
  expect_out "disabled scheduled workflow: warning" "WARN   workflow uptime"
  expect_out "disabled scheduled workflow: says why" "disabled after 60 days without activity"

  stub_reset
  route "api GET repos/$S/rulesets/101" "$(jq -c '(.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[0].integration_id) = 999 | . + {id: 101}' "$FIX/ruleset-main-project.json")"
  routes_configured_repo project
  expect_rc "check bound to another app: exit 1" 1 vr "$S"
  expect_out "check bound to another app: row" "FAIL   required check ci / ci"
  expect_out "check bound to another app: detail" "bound to 999"

  stub_reset
  route "api GET repos/$S/environments/staging/secrets?per_page=100" '{"secrets":[{"name":"DEPLOY_USER"}]}'
  route "api GET repos/$S/actions/variables/STAGING_READY" '{"message":"Not Found"}' 1 404
  routes_configured_repo project
  expect_rc "staging secrets missing before provisioning: exit 0" 0 vr "$S"
  expect_out "staging secrets missing before provisioning: WARN" "WARN   staging secret DEPLOY_HOST"
  stub_reset
  route "api GET repos/$S/environments/staging/secrets?per_page=100" '{"secrets":[{"name":"DEPLOY_USER"}]}'
  routes_configured_repo project
  expect_rc "staging secrets missing although STAGING_READY: exit 1" 1 vr "$S"
  expect_out "staging secrets missing although STAGING_READY: FAIL" "FAIL   staging secret DEPLOY_HOST"

  stub_reset
  route "api GET repos/$S/actions/variables/OWNER_LOGIN" '{"name":"OWNER_LOGIN","value":"someone-else"}'
  routes_configured_repo project
  expect_rc "OWNER_LOGIN differs: exit 1" 1 vr "$S"
  expect_out "OWNER_LOGIN differs: row" "FAIL   variable OWNER_LOGIN"

  write_config agent
  stub_reset
  route "api GET repos/$S/collaborators/octo-agent" '{"message":"Not Found"}' 1 404
  route "api GET repos/$S/invitations?per_page=100" '[{"id":1,"invitee":{"login":"octo-agent"}}]'
  routes_configured_repo project
  expect_rc "agent invitation pending: exit 0" 0 vr "$S"
  expect_out "agent invitation pending: WARN" "WARN   agent octo-agent collaborator"
  write_config noagent

  stub_reset
  routes_configured_repo template
  expect_rc "template profile on a configured template: exit 0" 0 in_dir "$T/home" cmd team-verify-repo "$S" --profile template
  expect_out "template: environments N/A" "N/A    environments staging, production"
  expect_out "template: release token N/A" "N/A    secret RELEASE_PLEASE_TOKEN"
  expect_out "template: template-ci required" "PASS   required check template-ci"

  stub_reset
  routes_empty_repo "$S" true
  expect_rc "private on Free: exit 1 (settings still differ)" 1 vr "$S"
  expect_out "private on Free: rulesets N/A" "N/A    ruleset main"
  expect_out "private on Free: fallback warning" "WARN   private repo on GitHub Free"

  stub_reset
  route_err "api GET repos/$S" 404
  expect_rc "unreadable repo: exit 1" 1 vr "$S"
}

# ------------------------------------------------------------------------------ team-sync
# make_release <tag> <variant full|slim|evil> : prints the tarball path
make_release() {
  local tag="$1" v="$2" d="$T/rel-$1-$2" top
  top="$d/akosiArvin081596-dev-standards-c0ffee${tag//./}"
  mkdir -p "$top/managed/.claude/rules/team" "$top/managed/.claude/hooks" "$top/managed/.github/ISSUE_TEMPLATE" "$top/plugins/team"
  printf '<!-- managed by dev-standards: never edit in a project -->\n# Team rules (%s)\n' "$tag" >"$top/managed/.claude/rules/team/team.md"
  printf '{\n  "autoMemoryEnabled": false\n}\n' >"$top/managed/.claude/settings.json"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$top/managed/.claude/hooks/plugin-check"
  chmod 0755 "$top/managed/.claude/hooks/plugin-check"
  printf '## Report: #<issue> <title>\n' >"$top/managed/.github/pull_request_template.md"
  [ "$v" = slim ] || printf 'name: Bug\n' >"$top/managed/.github/ISSUE_TEMPLATE/bug.yml"
  [ "$v" = evil ] && ln -s /etc/hosts "$top/managed/.claude/evil-link"
  printf 'not managed\n' >"$top/README.md"
  tar -czf "$d.tar.gz" -C "$d" "$(basename "$top")"
  printf '%s' "$d.tar.gz"
}

t_sync() {
  section "team-sync"
  local P="$T/sync-proj" P2="$T/sync-proj2" P3="$T/sync-proj3" rel110 rel120 rel200 relevil h_before h_after lock
  rel110=$(make_release v1.1.0 full)
  rel120=$(make_release v1.2.0 slim)
  rel200=$(make_release v2.0.0 full)
  relevil=$(make_release v1.3.0 evil)
  make_repo "$P" "git@github.com:octo-owner/sample-app.git" octo-owner Asia/Manila
  mkdir -p "$P/.github/workflows" "$P/src"
  cat >"$P/.github/workflows/ci.yml" <<'EOF'
name: ci
on: [pull_request]
jobs:
  ci:
    uses: akosiArvin081596/dev-standards/.github/workflows/ci.yml@v1
    secrets: inherit
  gates:
    uses: akosiArvin081596/dev-standards/.github/workflows/pr-gates.yml@v1 # pinned by team-sync
EOF
  printf 'name: template-ci\n' >"$P/.github/workflows/template-ci.yml"
  printf 'project code\n' >"$P/src/app.txt"
  printf '# sample-app\n' >"$P/CLAUDE.md"
  git -C "$P" add -A && git -C "$P" commit -q -m "chore: template files"
  sync_in() {  # sync_in <dir> <tarball or ""> args...
    local d="$1" tb="$2"
    shift 2
    if [ -n "$tb" ]; then (cd "$d" && TEAM_STANDARDS_TARBALL="$tb" /bin/bash "$BIN/team-sync" "$@")
    else (cd "$d" && /bin/bash "$BIN/team-sync" "$@"); fi
  }
  owned_hash() { (cd "$P" && cat src/app.txt CLAUDE.md ops/project.conf README.md) | cksum; }

  stub_reset
  h_before=$(owned_hash)
  expect_rc "--init --to v1.1.0 from a local tarball" 0 sync_in "$P" "$rel110" --init --to v1.1.0
  lock="$P/.claude/team-standards.lock"
  ok "managed rule copied" [ -f "$P/.claude/rules/team/team.md" ]
  ok "managed hook copied and executable" [ -x "$P/.claude/hooks/plugin-check" ]
  ok "managed issue template copied" [ -f "$P/.github/ISSUE_TEMPLATE/bug.yml" ]
  ok "non-managed release files not copied" [ ! -e "$P/plugins" ]
  ok "--init deleted template-ci.yml" [ ! -e "$P/.github/workflows/template-ci.yml" ]
  ok "lock names the release" [ "$(jq -r .release "$lock")" = v1.1.0 ]
  ok "lock names the standards repo" [ "$(jq -r .standards_repo "$lock")" = akosiArvin081596/dev-standards ]
  ok "lock lists exactly the managed files" [ "$(jq -r '.files | keys | join(" ")' "$lock")" = ".claude/hooks/plugin-check .claude/rules/team/team.md .claude/settings.json .github/ISSUE_TEMPLATE/bug.yml .github/pull_request_template.md" ]
  ok "lock keys are sorted (jq -S stable)" [ "$(jq -S . "$lock")" = "$(cat "$lock")" ]
  ok "lock hashes match the files" [ "$(jq -r '.files[".claude/rules/team/team.md"]' "$lock")" = "sha256:$( (shasum -a 256 "$P/.claude/rules/team/team.md" 2>/dev/null || sha256sum "$P/.claude/rules/team/team.md") | awk '{print $1}')" ]
  h_after=$(owned_hash)
  ok "project-owned files untouched" [ "$h_before" = "$h_after" ]
  ok "workflow pins already @v1 stay" grep -q 'workflows/ci.yml@v1$' "$P/.github/workflows/ci.yml"
  ok "no GitHub call with --to and a local tarball" [ "$(count_calls '*')" = 0 ]

  expect_rc "--check right after a sync: up to date" 0 sync_in "$P" "$rel110" --check --to v1.1.0
  expect_out "--check says up to date" "up to date with v1.1.0"
  run_cmd sync_in "$P" "$rel110" --to v1.1.0
  expect_out "second sync is a no-op" "already up to date with v1.1.0"

  printf 'local edit\n' >>"$P/.claude/rules/team/team.md"
  cp "$P/.claude/rules/team/team.md" "$T/edited.md"
  expect_rc "--check with an edited managed file: exit 1" 1 sync_in "$P" "$rel110" --check --to v1.1.0
  expect_out "--check names the drifted file" ".claude/rules/team/team.md"
  ok "--check changed nothing" cmp -s "$T/edited.md" "$P/.claude/rules/team/team.md"
  expect_rc "sync restores the managed file" 0 sync_in "$P" "$rel110" --to v1.1.0
  ok "managed file restored" not grep -q 'local edit' "$P/.claude/rules/team/team.md"

  # newest release of the lock's major, numeric order, drafts and pre-releases skipped
  stub_reset
  route "api GET repos/akosiArvin081596/dev-standards/releases?per_page=100" \
    '[{"tag_name":"v1.2.0","draft":false,"prerelease":false},{"tag_name":"v1.10.0","draft":false,"prerelease":false},{"tag_name":"v1.9.0","draft":false,"prerelease":false},{"tag_name":"v1.11.0","draft":true,"prerelease":false},{"tag_name":"v1.12.0","draft":false,"prerelease":true},{"tag_name":"v2.0.0","draft":false,"prerelease":false}]'
  expect_rc "no --to: picks the newest v1.x.y release" 0 sync_in "$P" "$rel120"
  ok "lock moved to v1.10.0 (numeric, not v1.9.0; not the draft v1.11.0 or v2)" [ "$(jq -r .release "$lock")" = v1.10.0 ]
  ok "releases were read as the project account" [ "$(acting_for 'api GET repos/akosiArvin081596/dev-standards/releases*')" = octo-owner ]
  expect_out "a managed file the new release dropped is deleted" "[delete]  .github/ISSUE_TEMPLATE/bug.yml"
  ok "dropped managed file removed" [ ! -e "$P/.github/ISSUE_TEMPLATE/bug.yml" ]
  ok "dropped file left the lock" [ "$(jq -r '.files | has(".github/ISSUE_TEMPLATE/bug.yml")' "$lock")" = false ]

  # major upgrade rewrites the reusable-workflow pins
  stub_reset
  expect_rc "--to v2.0.0 (major upgrade)" 0 sync_in "$P" "$rel200" --to v2.0.0
  expect_out "major upgrade is announced" "major upgrade: v1 → v2"
  ok "ci.yml pin moved to @v2" grep -q 'dev-standards/.github/workflows/ci.yml@v2$' "$P/.github/workflows/ci.yml"
  ok "pr-gates.yml pin moved to @v2, comment kept" grep -q 'pr-gates.yml@v2 # pinned by team-sync$' "$P/.github/workflows/ci.yml"
  ok "the rest of ci.yml unchanged" grep -q '    secrets: inherit' "$P/.github/workflows/ci.yml"

  # download path (no local tarball) and "latest" when there is no lock
  make_repo "$P2" "git@github.com:octo-owner/other-app.git" octo-owner
  stub_reset
  route "api GET repos/akosiArvin081596/dev-standards/releases/latest" '{"tag_name":"v1.1.0"}'
  route "api GET repos/akosiArvin081596/dev-standards/tarball/v1.1.0" "@$rel110"
  expect_rc "no lock, no --to: latest release, downloaded" 0 sync_in "$P2" ""
  ok "tarball downloaded with gh api (a read)" called "api GET repos/akosiArvin081596/dev-standards/tarball/v1.1.0"
  ok "lock written for the latest release" [ "$(jq -r .release "$P2/.claude/team-standards.lock")" = v1.1.0 ]
  stub_reset
  route_err "api GET repos/akosiArvin081596/dev-standards/tarball/v9.9.9" 404
  expect_rc "missing release: exit 1" 1 sync_in "$P2" "" --to v9.9.9

  # refusals and unsafe input
  local D="$T/sync-std" TP="$T/sync-tpl"
  make_repo "$D" "git@github.com:akosiArvin081596/dev-standards.git" akosiArvin081596
  expect_rc "refused inside dev-standards itself" 4 sync_in "$D" "$rel110" --to v1.1.0
  make_repo "$TP" "git@github.com:akosiArvin081596/project-starter.git" akosiArvin081596
  expect_rc "--init refused in the template repo" 4 sync_in "$TP" "$rel110" --init --to v1.1.0
  expect_rc "release with a symlink in managed/: refused" 1 sync_in "$P2" "$relevil" --to v1.3.0
  ok "nothing from the bad release was written" [ "$(jq -r .release "$P2/.claude/team-standards.lock")" = v1.1.0 ]
  make_repo "$P3" "git@github.com:octo-owner/third-app.git" octo-owner
  mkdir -p "$T/outside"
  ln -s "$T/outside" "$P3/.github"
  expect_rc "symlinked folder pointing outside the checkout: refused" 1 sync_in "$P3" "$rel110" --to v1.1.0
  ok "nothing written outside the checkout" [ -z "$(ls -A "$T/outside")" ]
  expect_rc "outside a git repo: exit 5" 5 sync_in "$T/home" "$rel110" --to v1.1.0
}

# ------------------------------------------------------------------------------ team-conflict-check
t_conflict() {
  section "team-conflict-check"
  local R="$T/cc-proj" j
  make_repo "$R" "git@github.com:octo-owner/sample-app.git" octo-owner
  cc() { in_dir "$R" cmd team-conflict-check "$@"; }
  issue() {  # issue <n> <author> <title> <body>
    route "issue view $1 -R $S --json number,title,body,author" \
      "$(jq -cn --argjson n "$1" --arg a "$2" --arg t "$3" --arg b "$4" '{number: $n, title: $t, author: {login: $a}, body: $b}')"
  }
  stub_reset
  issue 1 octo-owner "Login page" "$(printf '## What\nA login page.\n\n## Likely files\n- `src/auth/login.ts`\n- src/auth/session.ts (session cookie)\n\n## Other\n- not/a/file.txt\n')"
  issue 2 octo-owner "Users API" "$(printf '### Likely files\n\n- src/api/users.ts\n- docs/api.md\n')"
  issue 3 octo-owner "Auth hardening" "$(printf '**Likely files**\n* `src/auth/**`\n')"
  issue 4 octo-owner "Invoices" "$(printf 'Likely files: src/billing/invoice.ts, src/billing/tax.ts\n')"
  issue 5 octo-owner "Vague request" "$(printf 'Please make it faster.\n')"
  issue 6 a-stranger "$(printf 'API \033[31mcleanup')" "$(printf '### Likely files\n\n- src/api/\n')"
  issue 7 octo-owner "Form issue" "$(printf '### Likely files\n\n_No response_\n')"

  expect_rc "four issues: exit 0" 0 cc 1 2 3 4
  expect_out "parallel group" "Parallel (no shared files): #2 #4"
  expect_out "chain for overlapping issues" "Chain (one after another): #1 → #3"
  expect_out "names the shared paths" "#1 and #3 share: src/auth/login.ts ~ src/auth/**, src/auth/session.ts ~ src/auth/**"
  expect_out "wave 1" "wave 1: #2 #4 #1"
  expect_out "wave 2" "wave 2: #3"
  expect_out "list bullets and backticks parsed" "files: src/auth/login.ts src/auth/session.ts"
  expect_no_out "paths outside the section ignored" "not/a/file.txt"
  expect_out "inline Likely files: line parsed" "files: src/billing/invoice.ts src/billing/tax.ts"
  ok "only reads: no writes" not any_write

  expect_rc "folder vs file: exit 0" 0 cc 2 "#6"
  expect_out "folder contains file: chain" "Chain (one after another): #2 → #6"
  expect_out "foreign author flagged" "opened by a-stranger, not the owner: ask the owner first"
  ok "control characters stripped from titles" not grep -q "$(printf '\033')" <<<"$OUT"

  expect_rc "no Likely files: exit 0" 0 cc 4 5 7
  expect_out "issue without files runs alone" "(no Likely files section: runs alone)"
  expect_out "unknown files chain with everything" "Chain (one after another): #4 → #5 → #7"

  run_cmd cc 1 2 3 4 6 --json
  j="$OUT"
  if [ "$RC" = 0 ] && jq -e . >/dev/null 2>&1 <<<"$j"; then pass "--json is valid JSON"; else fail "--json is valid JSON (exit $RC)" "$j"; fi
  ok "--json parallel" [ "$(jq -c .parallel <<<"$j")" = '[4]' ]
  ok "--json chains" [ "$(jq -c .chains <<<"$j")" = '[[1,3],[2,6]]' ]
  ok "--json waves" [ "$(jq -c .waves <<<"$j")" = '[[4,1,2],[3,6]]' ]
  ok "--json files" [ "$(jq -c '.issues[0].files' <<<"$j")" = '["src/auth/login.ts","src/auth/session.ts"]' ]
  ok "--json trusted author" [ "$(jq -c '[.issues[] | .trusted_author]' <<<"$j")" = '[true,true,true,true,false]' ]
  ok "--json overlaps" [ "$(jq -c '[.overlaps[] | [.a, .b]]' <<<"$j")" = '[[1,3],[2,6]]' ]

  stub_reset
  route_err "issue view 9 -R $S*" 404
  expect_rc "unreadable issue: exit 1" 1 cc 9
  expect_rc "bad issue number: usage" 2 cc abc
}

# ------------------------------------------------------------------------------ team-worktree-report
t_worktree() {
  section "team-worktree-report"
  local root="$T/wt-root" A B C wrap refs_before refs_after
  A="$root/octo/app-a"; B="$root/other/app-b"; C="$root/misc/app-c"
  make_repo "$A" "git@github.com:octo-owner/app-a.git" octo-owner
  make_repo "$B" "git@github.com-other:someorg/app-b.git" octo-other
  make_repo "$C" "https://gitlab.example/x/app-c.git" octo-owner
  git -C "$A" worktree add -q -b feat/1-a "$A/.claude/worktrees/1-a" 2>/dev/null
  git -C "$A" worktree add -q -b fix/2-b "$root/sibling-2-b" 2>/dev/null
  (cd "$root/sibling-2-b" && GIT_COMMITTER_DATE="2020-01-01T00:00:00Z" GIT_AUTHOR_DATE="2020-01-01T00:00:00Z" git commit -q --allow-empty -m "fix: old")
  git -C "$A" worktree add -q -b chore/3-c "$A/.claude/worktrees/3-c" 2>/dev/null
  rm -rf "${A:?}/.claude/worktrees/3-c"
  git -C "$B" worktree add -q -b feat/5-e "$B/.claude/worktrees/5-e" 2>/dev/null
  git -C "$C" worktree add -q -b feat/9-z "$C/.claude/worktrees/9-z" 2>/dev/null
  refs_before=$(for r in "$A" "$B" "$C"; do git -C "$r" for-each-ref; git -C "$r" worktree list --porcelain; done)

  # a git wrapper that logs every git call the report makes
  wrap="$T/gitwrap"
  mkdir -p "$wrap"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/git.log"\nexec "%s" "$@"\n' "$T" "$REAL_GIT" >"$wrap/git"
  chmod +x "$wrap/git"
  : >"$T/git.log"

  stub_reset
  route "pr list -R octo-owner/app-a --head feat/1-a*" '[{"number":11,"state":"MERGED"}]'
  route "pr list -R octo-owner/app-a --head fix/2-b*" '[]'
  route "pr list -R octo-owner/app-a --head chore/3-c*" '[{"number":13,"state":"OPEN"}]'
  route "pr list -R someorg/app-b --head feat/5-e*" '[{"number":5,"state":"CLOSED"}]'
  OUT=$(PATH="$wrap:$PATH" /bin/bash "$BIN/team-worktree-report" --root "$root" 2>&1); RC=$?
  if [ "$RC" = 0 ]; then pass "report exits 0"; else fail "report exits 0 (exit $RC)" "$OUT"; fi
  ok "merged worktree marked" grep -Eq 'feat/1-a +merged #11 .* merged$' <<<"$OUT"
  ok "stale worktree marked" grep -Eq 'fix/2-b +no PR +2020-01-01 .*stale$' <<<"$OUT"
  ok "sibling-folder worktree listed" grep -q 'sibling-2-b' <<<"$OUT"
  ok "missing worktree marked" grep -Eq 'chore/3-c +open #13 .*missing$' <<<"$OUT"
  ok "SSH alias maps to its account" grep -Eq 'feat/5-e +closed #5' <<<"$OUT"
  ok "PR state for the alias repo read as octo-other" [ "$(acting_for 'pr list -R someorg/app-b*')" = octo-other ]
  ok "PR state for app-a read as octo-owner" [ "$(acting_for 'pr list -R octo-owner/app-a*')" = octo-owner ]
  ok "non-GitHub remote: unknown, no gh call" grep -Eq 'feat/9-z +unknown' <<<"$OUT"
  ok "no gh call for the non-GitHub repo" not called "*app-c*"
  ok "main checkouts not listed as worktrees" not grep -Eq '^app-a +~?[^ ]*/octo/app-a +main ' <<<"$OUT"
  expect_out "summary" "5 linked worktree(s): 1 merged, 1 stale (> 30 days), 1 missing. Nothing was changed."
  ok "never fetched, pulled, pruned or removed" not grep -Eq '^(fetch|pull|remote|gc|prune|worktree (prune|remove|add|move|lock|unlock)|checkout|reset|commit|push|config [^-])' "$T/git.log"
  ok "git was really wrapped (calls logged)" grep -q 'worktree list --porcelain' "$T/git.log"
  refs_after=$(for r in "$A" "$B" "$C"; do git -C "$r" for-each-ref; git -C "$r" worktree list --porcelain; done)
  ok "refs and worktrees unchanged" [ "$refs_before" = "$refs_after" ]
  ok "no FETCH_HEAD created" [ ! -e "$A/.git/FETCH_HEAD" ]

  stub_clear_log
  run_cmd cmd team-worktree-report --root "$root" --offline
  ok "--offline: no gh calls" [ "$(count_calls '*')" = 0 ]
  ok "--offline: PR state unknown" grep -Eq 'feat/1-a +unknown' <<<"$OUT"
  expect_rc "missing root: exit 5" 5 cmd team-worktree-report --root "$T/nope"
}

# ------------------------------------------------------------------------------ team-store-token
t_storetoken() {
  section "team-store-token"
  rm -f "$SEC_STUB_DIR/item" "$SEC_STUB_DIR/security.log"
  stub_reset
  OUT=$(printf '%s\n' "$KEYCHAIN_TOKEN" | CLAUDECODE=1 TEAM_STANDARDS_REPO=octo-owner/dev-standards /bin/bash "$BIN/team-store-token" 2>&1); RC=$?
  if [ "$RC" = 4 ]; then pass "refused inside Claude Code (CLAUDECODE=1): exit 4"; else fail "refused inside Claude Code (exit $RC)" "$OUT"; fi
  ok "refusal: keychain not touched" [ ! -s "$SEC_STUB_DIR/security.log" ]
  ok "refusal: GitHub not touched" [ "$(count_calls '*')" = 0 ]

  OUT=$(printf '%s\n' "$KEYCHAIN_TOKEN" | TEAM_STANDARDS_REPO=octo-owner/dev-standards /bin/bash "$BIN/team-store-token" 2>&1); RC=$?
  if [ "$RC" = 0 ]; then pass "normal terminal: stored and set (exit 0)"; else fail "normal terminal: stored and set (exit $RC)" "$OUT"; fi
  ok "token never printed" not grep -q "$KEYCHAIN_TOKEN" <<<"$OUT"
  ok "keychain asked with -w last (hidden prompt, token not in argv)" grep -Eq '^add-generic-password -U -s team-release-please-token -a [^ ]+ -l team release-please token -w$' "$SEC_STUB_DIR/security.log"
  ok "token not in any security argv" not grep -q "$KEYCHAIN_TOKEN" "$SEC_STUB_DIR/security.log"
  ok "keychain item holds the token" [ "$(cat "$SEC_STUB_DIR/item")" = "$KEYCHAIN_TOKEN" ]
  ok "secret set on dev-standards" called "secret set RELEASE_PLEASE_TOKEN --repo octo-owner/dev-standards"
  ok "secret value arrived on stdin, without a newline" [ "$(body_for 'secret set RELEASE_PLEASE_TOKEN*')" = "$KEYCHAIN_TOKEN" ]
  ok "secret set as the dev-standards owner" [ "$(acting_for 'secret set RELEASE_PLEASE_TOKEN*')" = octo-owner ]
  ok "token not in any gh argv" not grep -q "$KEYCHAIN_TOKEN" "$GH_STUB_DIR/log"
  OUT=$(printf '%s\n' "$KEYCHAIN_TOKEN" | TEAM_STANDARDS_REPO=stranger/dev-standards /bin/bash "$BIN/team-store-token" 2>&1); RC=$?
  if [ "$RC" = 5 ]; then pass "standards owner not in accounts.conf: exit 5"; else fail "standards owner not in accounts.conf (exit $RC)" "$OUT"; fi
  printf '%s' "$KEYCHAIN_TOKEN" >"$SEC_STUB_DIR/item"
}

# ------------------------------------------------------------------------------ team-merge-if-green
t_merge() {
  section "team-merge-if-green"
  local R="$T/mg-proj" OLD="2026-10-09T01:00:00Z" NEW="2026-10-09T02:00:00Z"
  make_repo "$R" "git@github.com:octo-owner/sample-app.git" octo-owner
  mg() { in_dir "$R" cmd team-merge-if-green "$@"; }
  pr_json() {  # pr_json [labels-json] [head] [draft]
    jq -cn --argjson l "${1:-[]}" --arg h "${2:-feat/21-x}" --argjson d "${3:-false}" --arg sha "$SHA_A" \
      '{number: 21, title: "feat: add x", state: "OPEN", isDraft: $d, headRefName: $h, headRefOid: $sha, labels: $l}'
  }
  run_ok() { jq -cn --arg n "$1" --arg c "${2:-success}" --arg t "${3:-$OLD}" --argjson app "${4:-15368}" --argjson id "${5:-1}" \
    '{id: $id, name: $n, status: "completed", conclusion: $c, started_at: $t, app: {id: $app}}'; }
  base_routes() {
    route "pr view 21 -R $S --json*" "$(pr_json)"
    route "api GET repos/$S/commits/$SHA_A/check-runs?per_page=100" \
      "{\"check_runs\":[$(run_ok 'ci / ci'),$(run_ok 'gates / guarded-paths' success "$OLD" 15368 2),$(run_ok 'gates / pr-title' success "$OLD" 15368 3)]}"
    route "api GET repos/$S/commits/$SHA_A/status?per_page=100" \
      '{"state":"success","statuses":[{"context":"ai-review","state":"success"},{"context":"ai-security","state":"success"},{"context":"ai-qa","state":"success"}]}'
    route "api GET repos/$S/issues?labels=main-red&state=open&per_page=100" '[]'
  }
  merged() { called "api PUT repos/$S/pulls/21/merge"; }

  stub_reset; base_routes
  expect_rc "all green: merged" 0 mg 21
  expect_out "prints each check" "[pass] ci / ci: success"
  expect_out "prints statuses" "[pass] ai-qa: success"
  expect_json "squash-merges exactly the checked commit" "$(body_for "api PUT repos/$S/pulls/21/merge")" \
    "{\"merge_method\":\"squash\",\"sha\":\"$SHA_A\",\"commit_title\":\"feat: add x (#21)\",\"commit_message\":\"\"}"
  ok "branch deleted" called "api DELETE repos/$S/git/refs/heads/feat/21-x"
  stub_reset; base_routes
  expect_rc "--dry-run: all green, exit 0" 0 mg 21 --dry-run
  ok "--dry-run: no merge" not merged

  stub_reset
  route "api GET repos/$S/commits/$SHA_A/status?per_page=100" '{"statuses":[{"context":"ai-review","state":"success"},{"context":"ai-security","state":"success"},{"context":"ai-qa","state":"pending"}]}'
  base_routes
  expect_rc "ai-qa pending: not merged (exit 1)" 1 mg 21
  expect_out "ai-qa pending shown" "[fail] ai-qa: pending"
  ok "ai-qa pending: no merge" not merged

  stub_reset
  route "api GET repos/$S/commits/$SHA_A/check-runs?per_page=100" \
    "{\"check_runs\":[$(run_ok 'ci / ci' success "$OLD" 999),$(run_ok 'gates / guarded-paths' success "$OLD" 15368 2),$(run_ok 'gates / pr-title' success "$OLD" 15368 3)]}"
  base_routes
  expect_rc "ci / ci from another app: not merged" 1 mg 21
  expect_out "another app is not the Actions app" "[fail] ci / ci: no run from the GitHub Actions app"

  stub_reset
  route "api GET repos/$S/commits/$SHA_A/check-runs?per_page=100" \
    "{\"check_runs\":[$(run_ok 'ci / ci' success "$OLD" 15368 1),$(run_ok 'ci / ci' failure "$NEW" 15368 9),$(run_ok 'gates / guarded-paths' success "$OLD" 15368 2),$(run_ok 'gates / pr-title' success "$OLD" 15368 3)]}"
  base_routes
  expect_rc "latest ci / ci run failed: not merged" 1 mg 21
  expect_out "latest run counts" "[fail] ci / ci: failure"

  stub_reset
  route "api GET repos/$S/issues?labels=main-red&state=open&per_page=100" '[{"number":40,"title":"main is red"}]'
  base_routes
  expect_rc "main-red open: not merged" 1 mg 21
  expect_out "main-red shown" "[fail] main is red (#40)"
  stub_reset
  route "pr view 21 -R $S --json*" "$(pr_json '[{"name":"fixes-main"}]')"
  route "api GET repos/$S/issues?labels=main-red&state=open&per_page=100" '[{"number":40,"title":"main is red"}]'
  base_routes
  expect_rc "main-red open but PR labelled fixes-main: merged" 0 mg 21

  stub_reset
  route "pr view 21 -R $S --json*" "$(pr_json '[{"name":"guarded"},{"name":"owner-approved"}]')"
  route "api GET repos/$S/issues/21/events?per_page=100" '[{"event":"labeled","actor":{"login":"octo-owner"},"label":{"name":"owner-approved"}}]'
  base_routes
  expect_rc "guarded + owner-approved by the owner: merged" 0 mg 21
  expect_out "guarded check shown" "[pass] guarded: owner-approved added by octo-owner"
  stub_reset
  route "pr view 21 -R $S --json*" "$(pr_json '[{"name":"guarded"},{"name":"owner-approved"}]')"
  route "api GET repos/$S/issues/21/events?per_page=100" '[{"event":"labeled","actor":{"login":"octo-owner"},"label":{"name":"owner-approved"}},{"event":"unlabeled","actor":{"login":"octo-owner"},"label":{"name":"owner-approved"}},{"event":"labeled","actor":{"login":"octo-agent"},"label":{"name":"owner-approved"}}]'
  base_routes
  expect_rc "guarded + owner-approved last added by the agent: not merged" 1 mg 21
  expect_out "agent label does not count" "was last labeled by octo-agent, not by the owner octo-owner"
  stub_reset
  route "pr view 21 -R $S --json*" "$(pr_json '[{"name":"guarded"},{"name":"owner-approved"}]')"
  route "api GET repos/$S/actions/variables/OWNER_LOGIN" '{"name":"OWNER_LOGIN","value":"the-boss"}'
  route "api GET repos/$S/issues/21/events?per_page=100" '[{"event":"labeled","actor":{"login":"the-boss"},"label":{"name":"owner-approved"}}]'
  base_routes
  expect_rc "repo variable OWNER_LOGIN decides the owner" 0 mg 21
  stub_reset
  route "pr view 21 -R $S --json*" "$(pr_json '[{"name":"guarded"}]')"
  base_routes
  expect_rc "guarded without owner-approved: not merged" 1 mg 21
  expect_out "missing owner-approved shown" "[fail] guarded: owner-approved is missing"

  stub_reset
  route "pr view 21 -R $S --json*" "$(pr_json '[]' 'release-please--branches--main')"
  base_routes
  expect_rc "release PR: refused (exit 4)" 4 mg 21
  ok "release PR: no merge" not merged
  stub_reset
  route "pr view 21 -R $S --json*" "$(pr_json '[{"name":"autorelease: pending"}]')"
  base_routes
  expect_rc "PR labelled autorelease: pending: refused" 4 mg 21
  stub_reset
  route "pr view 21 -R $S --json*" "$(pr_json '[]' feat/21-x true)"
  base_routes
  expect_rc "draft PR: exit 1" 1 mg 21
  stub_reset; base_routes
  expect_rc "standards profile needs self-test: not merged" 1 mg 21 --profile standards
  expect_out "missing self-test shown" "[fail] self-test: no run from the GitHub Actions app"
  stub_reset; base_routes
  route_err "api PUT repos/$S/pulls/21/merge" 405
  expect_rc "GitHub refuses the merge: exit 1" 1 mg 21
}

# ------------------------------------------------------------------------------ shellcheck
t_shellcheck() {
  section "shellcheck"
  if ! command -v shellcheck >/dev/null 2>&1; then
    printf 'SKIP  shellcheck is not installed\n'
    return 0
  fi
  local f
  for f in $MY_CMDS; do
    if shellcheck -x "$BIN/$f" >/dev/null 2>&1; then pass "shellcheck $f"; else fail "shellcheck $f" "$(shellcheck -x "$BIN/$f" 2>&1)"; fi
  done
  for f in "$REPO/plugins/team/lib/team-github.sh" "$HERE/run.sh" "$HERE/run-groups.sh" "$HERE/helpers.sh" "$HERE/stubs/gh" "$HERE/stubs/security"; do
    if (cd "$HERE" && shellcheck -x "$f") >/dev/null 2>&1; then pass "shellcheck ${f#"$REPO"/}"; else fail "shellcheck ${f#"$REPO"/}" "$(cd "$HERE" && shellcheck -x "$f" 2>&1)"; fi
  done
}
