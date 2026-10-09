#!/usr/bin/env bash
# deploy.sh <env> <artifact>: stream a release to the server's forced deploy command over ssh.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
CI_SELF_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=common.sh
. "$CI_SELF_DIR/common.sh"

usage() {
  cat <<'USAGE'
Usage: deploy.sh <staging|production> <release-<sha>.tar.gz> [--sha <sha>]
       deploy.sh <staging|production> --rollback <sha>
       deploy.sh <staging|production> --health

Talks to the server's forced command deploy-receive (docs/rules.md §11), which
accepts only `deploy <sha>` (tarball on stdin), `rollback <sha>` and `health`.
The sha comes from --sha, else the tarball name, else GITHUB_SHA (7-40 hex).
Env (environment secrets): DEPLOY_HOST, DEPLOY_USER, DEPLOY_PORT (default 22),
DEPLOY_SSH_KEY, DEPLOY_KNOWN_HOSTS. The key and known_hosts go to a private temp
folder (mode 600) that is removed afterwards; ssh runs with
StrictHostKeyChecking=yes against the pinned known_hosts, BatchMode and no ssh
config file. One attempt only (the server bans repeated failed logins).
Exit: the server's code (0 ok; 7 = that release is not on the server, rebuild
it), 1 on failure, 2 on usage error, 3 when a DEPLOY_* secret is missing.
USAGE
}

case "${1:-}" in -h|--help) usage; exit 0 ;; esac
[ "$#" -ge 2 ] || ci_usage_error "expected: deploy.sh <env> <artifact> | --rollback <sha> | --health"
env_name="$1"
shift
case "$env_name" in staging|production) ;; *) ci_usage_error "env must be staging or production" ;; esac

mode=deploy
artifact=""
sha=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --sha) [ "$#" -ge 2 ] || ci_usage_error "--sha needs a value"; sha="$2"; shift 2 ;;
    --rollback) [ "$#" -ge 2 ] || ci_usage_error "--rollback needs a sha"; mode=rollback; sha="$2"; shift 2 ;;
    --health) mode=health; shift ;;
    -*) ci_usage_error "unknown option: $1" ;;
    *) [ -z "$artifact" ] || ci_usage_error "unexpected argument: $1"; artifact="$1"; shift ;;
  esac
done

if [ "$mode" = deploy ]; then
  [ -n "$artifact" ] || ci_usage_error "missing the release tarball"
  [ -f "$artifact" ] || ci_die "$CI_EXIT_FAIL" "no such tarball: $artifact"
  if [ -z "$sha" ]; then
    base=$(basename "$artifact")
    case "$base" in release-*.tar.gz) sha="${base#release-}"; sha="${sha%.tar.gz}" ;; *) sha="${GITHUB_SHA:-}" ;; esac
  fi
else
  [ -z "$artifact" ] || ci_usage_error "--$mode takes no tarball"
fi
if [ "$mode" != health ]; then
  ci_is_sha "$sha" || ci_usage_error "bad commit sha: '$sha' (7-40 lower-case hex)"
fi

missing=""
for v in DEPLOY_HOST DEPLOY_USER DEPLOY_SSH_KEY DEPLOY_KNOWN_HOSTS; do
  eval "val=\${$v:-}"
  # shellcheck disable=SC2154  # val is set by the eval above
  [ -n "$val" ] || missing="$missing $v"
done
if [ -n "$missing" ]; then
  printf 'not configured: missing %s secret(s):%s (team-provision sets them)\n' "$env_name" "$missing" >&2
  exit "$CI_EXIT_NOT_CONFIGURED"
fi
host="$DEPLOY_HOST"
user="$DEPLOY_USER"
port="${DEPLOY_PORT:-22}"
case "$host" in -*|*[!A-Za-z0-9.:-]*) ci_die "$CI_EXIT_FAIL" "DEPLOY_HOST is not a plain host name" ;; esac
case "$user" in -*|''|*[!a-z0-9_-]*) ci_die "$CI_EXIT_FAIL" "DEPLOY_USER is not a plain user name" ;; esac
case "$port" in ''|*[!0-9]*) ci_die "$CI_EXIT_FAIL" "DEPLOY_PORT is not a number" ;; esac
ci_require_cmd ssh

dir=$(ci_mktemp_dir)
trap 'rm -rf "${dir:?}"' EXIT
( umask 077
  printf '%s\n' "$DEPLOY_SSH_KEY" > "$dir/key"
  printf '%s\n' "$DEPLOY_KNOWN_HOSTS" > "$dir/known_hosts" )
chmod 600 "$dir/key" "$dir/known_hosts"

opts=(-F /dev/null -i "$dir/key" -p "$port"
  -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes
  -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$dir/known_hosts" -o GlobalKnownHostsFile=/dev/null
  -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o LogLevel=ERROR)

set +e
case "$mode" in
  deploy)
    ci_info "deploying ${sha:0:12} to $env_name"
    # shellcheck disable=SC2029  # the forced command reads "deploy <sha>"; sha is validated hex
    ssh "${opts[@]}" "$user@$host" "deploy $sha" < "$artifact"
    rc=$? ;;
  rollback)
    ci_info "rolling $env_name back to ${sha:0:12}"
    # shellcheck disable=SC2029  # sha is validated hex
    ssh "${opts[@]}" "$user@$host" "rollback $sha" < /dev/null
    rc=$? ;;
  health)
    ssh "${opts[@]}" "$user@$host" health < /dev/null
    rc=$? ;;
esac
set -e

case "$rc" in
  0) ci_info "ok: $mode on $env_name" ;;
  7) ci_notice "release ${sha:0:12} is not on the $env_name server: it must be rebuilt and deployed" ;;
  255) ci_error "ssh to $env_name failed (connection, host key or login); check the DEPLOY_* secrets. No retry: the server bans repeated failures." ;;
  *) ci_error "$mode on $env_name failed (exit $rc); the server keeps the previous release" ;;
esac
exit "$rc"
