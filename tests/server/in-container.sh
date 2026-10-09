#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# The server-script test suite. Runs INSIDE a throwaway team-srvtest-* container (Ubuntu 24.04, root),
# started by tests/server/run.sh. Prints PASS/FAIL per check; exits 1 if anything failed.
# Never run this on a real server: it creates users, databases and nginx sites.
#
# What a container can't show, and how it is covered instead:
#   - systemd as PID 1 (enabling units, timers firing, reload-or-restart through sudo): unit and timer
#     files are checked with `systemd-analyze verify`, OnCalendar values with `systemd-analyze calendar`;
#     deploy-receive's reload is a no-op only when /run/systemd/system is absent; a python stand-in
#     serves the app; the narrow sudo rule itself is exercised for real (backup --pre-deploy).
#   - certbot against Let's Encrypt: a certbot test double performs an HTTP-01 style fetch through
#     nginx and writes a self-signed certificate; the TLS vhost then serves HTTPS.
#   - sshd forced commands: deploy-receive / serve-snapshot get SSH_ORIGINAL_COMMAND exactly as sshd
#     would set it and run as the env user (runuser); authorized_keys lines and modes are checked.
# shellcheck disable=SC2016,SC2034,SC2329,SC2012  # ok_if conditions are single-quoted on purpose: they are eval'd at check time
set -uo pipefail
export LC_ALL=C
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=helpers.sh
. "$HERE/helpers.sh"
started=$(date +%s)
[[ -f /.dockerenv || ${TEAM_SRVTEST_FORCE:-} == 1 ]] || { echo "refusing: this suite only runs inside a test container" >&2; exit 4; }
# Network guard (tests/lib/net-guard.sh, copied in by run.sh): fake ssh/scp/sftp/rsync first on PATH,
# logging and refusing, and a fake TEAM_CONFIG_DIR. Nothing here may reach a server.
if [[ -r /src/tests-lib/net-guard.sh ]]; then
  # shellcheck source=../lib/net-guard.sh
  . /src/tests-lib/net-guard.sh
  mkdir -p "$T/fake-team-config"
  export TEAM_CONFIG_DIR=$T/fake-team-config
  net_guard_install "$T/net-guard"
  if net_guard_assert; then pass "net-guard: fake ssh/scp/sftp/rsync first on PATH, refusing and logging"
  else echo "net-guard is not in place; refusing to run any test" >&2; exit 1; fi
else
  echo "net-guard missing (run this suite through tests/server/run.sh)" >&2; exit 1
fi
printf 'base: %s · sudo: %s · php %s · %s\n' "$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release | tr -d '"')" "$(sudo --version 2>/dev/null | head -n 1)" "$PHPV" "$(date --version | head -n 1)"
ubuntu_before=$(getent passwd ubuntu || true)
tz_before=$(readlink /etc/localtime || true)

# ============================================================================ 0. services
section "0. services (no systemd here: started with service … start)"
for s in postgresql mariadb nginx "php$PHPV-fpm"; do service "$s" start > /dev/null 2>&1; done
check "postgres answers" pgq -d postgres -c 'SELECT 1'
check "mariadb answers" myq -e 'SELECT 1'
check "nginx config is valid before the pack touches it" nginx -t

# ============================================================================ 1. syntax + discover
section "1. syntax and discover (read-only)"
for f in discover provision deploy-receive snapshot serve-snapshot refresh-staging backup flag lib.sh; do check "bash -n $f" bash -n "$SERVER/$f"; done
touch "$T/marker"; sleep 1
check "discover runs as root" "$SERVER/discover"
cp "$LOG" "$T/discover.out"
ok_if "discover reports OS, web servers, databases, runtimes, users, ports, firewall, cron" \
  'grep -q "^OS: Ubuntu" $T/discover.out && grep -q "^NGINX: " $T/discover.out && grep -q "^POSTGRES: " $T/discover.out && grep -q "^MARIADB: [0-9]" $T/discover.out && grep -q "^PYTHON3: " $T/discover.out && grep -q "^USER: ubuntu" $T/discover.out && grep -q "^LISTEN: " $T/discover.out && grep -q "^UFW: " $T/discover.out && grep -q "^CRON: " $T/discover.out'
if [[ $SUDO_IMPL == sudo-rs ]]; then
  ok_if "discover names the sudo implementation (sudo-rs) and coreutils" 'grep -q "^SUDO: sudo-rs [0-9]" $T/discover.out && grep -q "^COREUTILS: " $T/discover.out && grep -q "^SUDOERS_CHECK: " $T/discover.out'
else
  ok_if "discover names the sudo implementation (classic sudo) and coreutils" 'grep -q "^SUDO: sudo [0-9].*(classic)" $T/discover.out && grep -q "^COREUTILS: " $T/discover.out && grep -q "^SUDOERS_CHECK: " $T/discover.out'
fi
check "discover runs as an unprivileged user" runuser -u ubuntu -- "$SERVER/discover"
changed=$(find /etc /srv /usr/local /var/www /var/lib/team /var/log/team -newer "$T/marker" 2>/dev/null | head -n 5)
ok_if "discover changed nothing on disk" '[[ -z $changed ]]'
expect_rc 0 "discover --help" "$SERVER/discover" --help

# ============================================================================ 2. provision
section "2. provision"
make_bundle pgapp staging "$T/b-pg-s"
make_bundle pgapp production "$T/b-pg-p"
make_bundle myapp staging "$T/b-my-s"
make_bundle myapp production "$T/b-my-p"
make_bundle stapp staging "$T/b-st-s"
make_bundle stapp production "$T/b-st-p"

expect_rc 0 "provision --help" provision_run "$T/b-pg-s" --help
expect_rc 2 "provision without --bundle is a usage error" bash "$SERVER/provision"
make_bundle pgapp staging "$T/b-bad" 'HOST=Not A Host'
expect_rc 2 "provision rejects a bad HOST (usage error)" provision_run "$T/b-bad"
ok_if "a usage error still ends with TEAM-RESULT fail" '[[ $(tail -n 1 $LOG) == "TEAM-RESULT fail"* ]]'

# TEAM-HOSTKEY: one line with the server's SSH host key just before TEAM-RESULT, so team-provision
# pins it from the same connection: ed25519, else ecdsa, else rsa; never the comment (hostname).
hostkey_lines() { grep -c '^TEAM-HOSTKEY ' "$1" || true; }
hostkey_of() { cut -d' ' -f1,2 "/etc/ssh/ssh_host_$1_key.pub"; }
ok_if "the test image starts without SSH host keys (openssh-client only)" '[[ -z $(ls /etc/ssh/ssh_host_* 2> /dev/null) ]]'
provision_run "$T/b-pg-s" > "$LOG" 2>&1
ok_if "no host key on the server → no TEAM-HOSTKEY line; TEAM-RESULT still last" '[[ $(hostkey_lines $LOG) == 0 && $(tail -n 1 $LOG) == "TEAM-RESULT ok" ]]'
mkdir -p /etc/ssh
ssh-keygen -q -t rsa -b 2048 -N '' -C root@srvtest-hostname -f /etc/ssh/ssh_host_rsa_key
provision_run "$T/b-pg-s" > "$LOG" 2>&1
ok_if "only an rsa host key → TEAM-HOSTKEY ssh-rsa <base64>" '[[ $(hostkey_lines $LOG) == 1 && $(grep "^TEAM-HOSTKEY " $LOG) == "TEAM-HOSTKEY $(hostkey_of rsa)" ]]'
ssh-keygen -q -t ecdsa -N '' -C root@srvtest-hostname -f /etc/ssh/ssh_host_ecdsa_key
provision_run "$T/b-pg-s" > "$LOG" 2>&1
ok_if "ecdsa is preferred over rsa" '[[ $(hostkey_lines $LOG) == 1 && $(grep "^TEAM-HOSTKEY " $LOG) == "TEAM-HOSTKEY $(hostkey_of ecdsa)" ]]'
ssh-keygen -q -t ed25519 -N '' -C root@srvtest-hostname -f /etc/ssh/ssh_host_ed25519_key
provision_run "$T/b-pg-s" > "$LOG" 2>&1
ok_if "ed25519 is preferred: exactly one TEAM-HOSTKEY line, right before TEAM-RESULT" \
  '[[ $(hostkey_lines $LOG) == 1 && $(tail -n 2 $LOG | head -n 1) == "TEAM-HOSTKEY $(hostkey_of ed25519)" && $(tail -n 1 $LOG) == "TEAM-RESULT ok" ]]'
ok_if "  … type and base64 only: the key comment (hostname) is never printed" '! grep -q srvtest-hostname $LOG'
provision_run "$T/b-bad" > "$LOG" 2>&1
ok_if "  … also printed when provision fails (before TEAM-RESULT fail)" '[[ $(tail -n 2 $LOG | head -n 1) == "TEAM-HOSTKEY $(hostkey_of ed25519)" && $(tail -n 1 $LOG) == "TEAM-RESULT fail"* ]]'

expect_rc 0 "plan (no --apply) for pgapp staging" provision_run "$T/b-pg-s"
cp "$LOG" "$T/plan.out"
ok_if "plan lists the user, database, env file, vhost, units, keys and sudo rule" \
  'grep -q "^\[create\] OS user pgapp-staging" $T/plan.out && grep -q "^\[create\] database pgapp_staging" $T/plan.out && grep -q "^\[create\] env file" $T/plan.out && grep -q "^\[create\] nginx vhost" $T/plan.out && grep -q "^\[create\] systemd unit team-pgapp-staging-web.service" $T/plan.out && grep -q "^\[create\] authorized_keys" $T/plan.out && grep -q "^\[create\] sudo rule" $T/plan.out'
ok_if "plan ends with TEAM-RESULT ok" '[[ $(tail -n 1 $T/plan.out) == "TEAM-RESULT ok" ]]'
ok_if "plan changed nothing (no user, no /etc/team, no database, no vhost)" \
  '! getent passwd pgapp-staging >/dev/null && [[ ! -e /etc/team && ! -e /etc/nginx/sites-available/team-pgapp-staging.conf ]] && [[ -z $(pgq -d postgres -c "SELECT 1 FROM pg_database WHERE datname = '"'"'pgapp_staging'"'"'") ]]'

for b in pg-s pg-p my-s my-p st-s st-p; do
  expect_rc 0 "provision --apply ($b)" provision_run "$T/b-$b" --apply
  cp "$LOG" "$T/apply-$b.log"
  ok_if "  … ends with TEAM-RESULT ok ($b)" '[[ $(tail -n 1 $LOG) == "TEAM-RESULT ok" ]]'
done
check "nginx -t passes with all six vhosts" nginx -t
ok_if "server timezone unchanged" '[[ $(readlink /etc/localtime || true) == "$tz_before" ]]'

h1=$(managed_hash)
for b in pg-s pg-p my-s my-p st-s st-p; do
  provision_run "$T/b-$b" --apply > "$LOG" 2>&1
  ok_if "re-running --apply is a no-op ($b)" '[[ $(changes_in $LOG) == 0 ]] && grep -q "No changes" $LOG'
done
ok_if "re-running changed no managed file (hash of every pack file)" '[[ $(managed_hash) == "$h1" ]]'

ok_if "server scripts installed root:root 0755 in /usr/local/lib/team" \
  '[[ $(stat -c "%U:%G %a" $LIB/provision $LIB/deploy-receive $LIB/snapshot $LIB/lib.sh | sort -u) == "root:root 755" ]]'
ok_if "project record root:<user> 640; salt, dbpass and ledger root 600" \
  '[[ $(stat -c "%U:%G %a" /etc/team/projects/pgapp-staging.conf) == "root:pgapp-staging 640" && $(stat -c "%U:%G %a" /etc/team/projects/pgapp.salt /etc/team/projects/pgapp-staging.dbpass /etc/team/projects/pgapp-staging.resources | sort -u) == "root:root 600" ]]'
ok_if "env file 600, owned by the env user, all placeholders filled" \
  '[[ $(stat -c "%U %a" /srv/team/pgapp/staging/shared/.env) == "pgapp-staging 600" ]] && ! grep -q "{{" /srv/team/pgapp/staging/shared/.env'
SEC1=$(env_get /srv/team/pgapp/staging/shared/.env APP_SECRET)
ok_if "secrets are fresh 32-byte hex, one per placeholder" \
  '[[ $SEC1 =~ ^[0-9a-f]{64}$ && $SEC1 != $(env_get /srv/team/pgapp/staging/shared/.env SESSION_SECRET) && $SEC1 != $(env_get /srv/team/pgapp/production/shared/.env APP_SECRET) ]]'
ports=$(for f in /etc/team/projects/*.conf; do conf_get "$f" PORT; done | sort)
ok_if "each environment got its own port in 9100-9899" '[[ $(sort -u <<< "$ports" | wc -l) == 6 && $(head -n 1 <<< "$ports") -ge 9100 && $(tail -n 1 <<< "$ports") -le 9899 ]]'
ok_if "env user: system uid, /bin/bash, key-only (password *), home = app dir" \
  '[[ $(getent passwd pgapp-staging | cut -d: -f3) -lt 1000 && $(getent passwd pgapp-staging | cut -d: -f6,7) == "/srv/team/pgapp/staging:/bin/bash" && $(getent shadow pgapp-staging | cut -d: -f2) == "*" ]]'
ok_if "authorized_keys root-owned 644 with the forced commands (deploy; production also db-pull)" \
  '[[ $(stat -c "%U %a" /srv/team/pgapp/production/.ssh/authorized_keys) == "root 644" ]] && grep -q "^command=\"/usr/local/lib/team/deploy-receive pgapp staging\",restrict ssh-ed25519 " /srv/team/pgapp/staging/.ssh/authorized_keys && grep -q "^command=\"/usr/local/lib/team/serve-snapshot pgapp\",restrict ssh-ed25519 .* team-dbpull-pgapp$" /srv/team/pgapp/production/.ssh/authorized_keys && ! grep -q serve-snapshot /srv/team/pgapp/staging/.ssh/authorized_keys'
ok_if "staging vhost: basic auth + X-Robots-Tag noindex; production vhost: neither" \
  'grep -q "auth_basic_user_file /etc/nginx/team/pgapp-staging.htpasswd" /etc/nginx/sites-available/team-pgapp-staging.conf && grep -q "add_header X-Robots-Tag \"noindex, nofollow\" always;" /etc/nginx/sites-available/team-pgapp-staging.conf && ! grep -q "auth_basic \"" /etc/nginx/sites-available/team-pgapp-production.conf && ! grep -q X-Robots-Tag /etc/nginx/sites-available/team-pgapp-production.conf'
ok_if "htpasswd is apr1, root:www-data 640" '[[ $(cut -d: -f2 /etc/nginx/team/pgapp-staging.htpasswd) == \$apr1\$* && $(stat -c "%U:%G %a" /etc/nginx/team/pgapp-staging.htpasswd) == "root:www-data 640" ]]'
ok_if "unit ExecStart escapes \$ and quotes for systemd" \
  'grep -Fxq "ExecStart=/bin/bash -c \"python3 -m http.server \$\$PORT --bind 127.0.0.1\"" /etc/systemd/system/team-pgapp-staging-web.service && grep -Fxq "ExecStart=/bin/bash -c \"python3 -c \\\"import time; time.sleep(3600)\\\"\"" /etc/systemd/system/team-pgapp-staging-worker.service'
ok_if "units: User=, WorkingDirectory=…/current, EnvironmentFile=…/shared/.env, Restart=always" \
  'grep -q "^User=pgapp-staging$" /etc/systemd/system/team-pgapp-staging-web.service && grep -q "^WorkingDirectory=/srv/team/pgapp/staging/current$" /etc/systemd/system/team-pgapp-staging-web.service && grep -q "^EnvironmentFile=/srv/team/pgapp/staging/shared/.env$" /etc/systemd/system/team-pgapp-staging-web.service && grep -q "^Restart=always$" /etc/systemd/system/team-pgapp-staging-web.service'
check "systemd-analyze verify accepts the generated units and timers" \
  systemd-analyze verify /etc/systemd/system/team-pgapp-staging-web.service /etc/systemd/system/team-pgapp-staging-worker.service /etc/systemd/system/team-myapp-production-queue.service /etc/systemd/system/team-pgapp-snapshot.service /etc/systemd/system/team-pgapp-snapshot.timer /etc/systemd/system/team-myapp-backup-verify.timer
for f in /etc/sudoers.d/team-*; do check "visudo -cf $(basename "$f")" visudo -cf "$f"; done
# The whole configuration (with every drop-in), checked through a 0440 copy of /etc/sudoers: sudo-rs
# ships it 0644, which its visudo -c reports even though sudo-rs itself accepts it.
cp /etc/sudoers "$T/sudoers.copy" && chmod 440 "$T/sudoers.copy"
check "visudo: the whole sudoers configuration, with every pack drop-in, parses ($SUDO_IMPL)" visudo -cf "$T/sudoers.copy"
check "sudo -l -U lists the exact deploy commands for the production user ($SUDO_IMPL)" sudo_lists pgapp-production "/usr/bin/systemctl reload-or-restart team-pgapp-production-web.service" "/usr/local/lib/team/backup pgapp --pre-deploy"
ok_if "sudo rule lists only exact commands (production adds backup --pre-deploy; php-fpm adds its reload)" \
  'grep -q "/usr/local/lib/team/backup pgapp --pre-deploy" /etc/sudoers.d/team-pgapp-production && ! grep -q backup /etc/sudoers.d/team-pgapp-staging && grep -q "reload php$PHPV-fpm.service" /etc/sudoers.d/team-myapp-staging && ! grep -qE "ALL$|\*" /etc/sudoers.d/team-pgapp-production'
ok_if "static staging with no services gets no sudo rule" '[[ ! -e /etc/sudoers.d/team-stapp-staging ]]'
for f in /etc/logrotate.d/team-*; do check "logrotate -d $(basename "$f")" logrotate -d "$f"; done
ok_if "php-fpm pools run as the env users" 'grep -q "^user = myapp-staging$" /etc/php/$PHPV/fpm/pool.d/team-myapp-staging.conf && [[ -S /run/php/team-myapp-staging.sock ]]'

# env template changes: new keys are appended, existing values never overwritten
cp -R "$T/b-pg-s" "$T/b-pg-s2"
printf '%s\n' 'NEW_SIGNING_KEY={{RANDOM_SECRET}}' 'FEATURE_PANEL=on' >> "$T/b-pg-s2/ops/env/staging.env.tmpl"
provision_run "$T/b-pg-s2" --apply > "$LOG" 2>&1
ok_if "a new template key is appended ([update] env file …)" 'grep -q "^\[update\] env file .*NEW_SIGNING_KEY FEATURE_PANEL" $LOG && [[ $(changes_in $LOG) == 1 ]]'
ok_if "existing env values kept; the new secret is fresh hex" \
  '[[ $(env_get /srv/team/pgapp/staging/shared/.env APP_SECRET) == "$SEC1" && $(env_get /srv/team/pgapp/staging/shared/.env NEW_SIGNING_KEY) =~ ^[0-9a-f]{64}$ && $(env_get /srv/team/pgapp/staging/shared/.env FEATURE_PANEL) == on ]]'
provision_run "$T/b-pg-s2" --apply > "$LOG" 2>&1
ok_if "… and the next run is a no-op again" '[[ $(changes_in $LOG) == 0 ]]'

# database isolation
PW_PS=$(env_get /srv/team/pgapp/staging/shared/.env DB_PASSWORD)
PW_PP=$(env_get /srv/team/pgapp/production/shared/.env DB_PASSWORD)
check "postgres: staging user connects to its own database" env PGPASSWORD="$PW_PS" psql -X -h 127.0.0.1 -U pgapp_staging -d pgapp_staging -Atc 'SELECT 1'
check_not "postgres: staging user cannot connect to production's database" env PGPASSWORD="$PW_PS" psql -X -h 127.0.0.1 -U pgapp_staging -d pgapp_production -Atc 'SELECT 1'
check_not "postgres: production user cannot connect to staging's database" env PGPASSWORD="$PW_PP" psql -X -h 127.0.0.1 -U pgapp_production -d pgapp_staging -Atc 'SELECT 1'
check_not "postgres: app user cannot create databases" env PGPASSWORD="$PW_PS" psql -X -h 127.0.0.1 -U pgapp_staging -d pgapp_staging -Atc 'CREATE DATABASE team_should_fail'
ok_if "postgres: app role defaults to timezone UTC" '[[ $(env PGPASSWORD="$PW_PS" psql -X -h 127.0.0.1 -U pgapp_staging -d pgapp_staging -Atc "SHOW timezone") == UTC ]]'
PW_MS=$(env_get /srv/team/myapp/staging/shared/.env DB_PASSWORD)
check "mariadb: staging user connects to its own database" env MYSQL_PWD="$PW_MS" "$MYSQL_BIN" -h 127.0.0.1 -u myapp_staging myapp_staging -e 'SELECT 1'
check_not "mariadb: staging user cannot use production's database" env MYSQL_PWD="$PW_MS" "$MYSQL_BIN" -h 127.0.0.1 -u myapp_staging myapp_production -e 'SELECT 1'
myq -e 'CREATE DATABASE myappXstaging' 2>/dev/null
check_not "mariadb: the grant is escaped (no _ wildcard match on myappXstaging)" env MYSQL_PWD="$PW_MS" "$MYSQL_BIN" -h 127.0.0.1 -u myapp_staging myappXstaging -e 'SELECT 1'
myq -e 'DROP DATABASE IF EXISTS myappXstaging'

# refusals: never reuse something the pack did not create
useradd -M -s /bin/bash clash-staging
clash_before=$(getent passwd clash-staging)
FIXTURE=pgapp make_bundle clash staging "$T/b-clash"
expect_rc 4 "refuses a pre-existing foreign OS user (clash-staging) with exit 4" provision_run "$T/b-clash" --apply
ok_if "  … and created nothing (no record, database or vhost; user untouched)" \
  '[[ ! -e /etc/team/projects/clash-staging.conf && ! -e /etc/nginx/sites-available/team-clash-staging.conf && $(getent passwd clash-staging) == "$clash_before" ]] && [[ -z $(pgq -d postgres -c "SELECT 1 FROM pg_database WHERE datname = '"'"'clash_staging'"'"'") ]]'
expect_rc 4 "plan mode refuses the same way" provision_run "$T/b-clash"
pg -d postgres -c 'CREATE DATABASE dbclash_staging' > /dev/null
FIXTURE=pgapp make_bundle dbclash staging "$T/b-dbclash"
expect_rc 4 "refuses a pre-existing foreign postgres database" provision_run "$T/b-dbclash" --apply
ok_if "  … before creating its OS user" '! getent passwd dbclash-staging > /dev/null'
myq -e "CREATE USER 'myclash_staging'@'localhost' IDENTIFIED BY 'x'"
FIXTURE=myapp make_bundle myclash staging "$T/b-myclash"
expect_rc 4 "refuses a pre-existing foreign mariadb user" provision_run "$T/b-myclash" --apply
printf 'server { listen 80; server_name ngclash-staging.example.test; }\n' > /etc/nginx/sites-available/team-ngclash-staging.conf
FIXTURE=stapp make_bundle ngclash staging "$T/b-ngclash"
expect_rc 4 "refuses a pre-existing foreign nginx file with the pack's name" provision_run "$T/b-ngclash" --apply
rm -f /etc/nginx/sites-available/team-ngclash-staging.conf
printf 'server { listen 80; server_name taken.example.test; }\n' > /etc/nginx/sites-enabled/someone-elses-site
FIXTURE=stapp make_bundle hostclash staging "$T/b-hostclash" 'HOST=taken.example.test'
expect_rc 4 "refuses a host another nginx site already serves" provision_run "$T/b-hostclash" --apply
rm -f /etc/nginx/sites-enabled/someone-elses-site

# nginx -t failure restores the previous vhost
cat > /usr/local/sbin/nginx <<'EOF'
#!/bin/bash
# test double: nginx -t fails while any vhost names broken-host.example.test
if [[ ${1:-} == -t ]] && grep -qs broken-host.example.test /etc/nginx/sites-available/*.conf; then echo "nginx: [emerg] simulated failure" >&2; exit 1; fi
exec /usr/sbin/nginx "$@"
EOF
chmod 755 /usr/local/sbin/nginx
vh_before=$(sha256sum /etc/nginx/sites-available/team-stapp-staging.conf)
make_bundle stapp staging "$T/b-st-broken" 'HOST=broken-host.example.test'
expect_rc 1 "a vhost that fails nginx -t fails provision" provision_run "$T/b-st-broken" --apply
ok_if "  … with TEAM-RESULT fail, and the previous vhost restored" \
  '[[ $(tail -n 1 $LOG) == "TEAM-RESULT fail nginx -t failed"* && $(sha256sum /etc/nginx/sites-available/team-stapp-staging.conf) == "$vh_before" ]]'
rm -f /usr/local/sbin/nginx
expect_rc 0 "re-running the good bundle repairs the record" provision_run "$T/b-st-s" --apply
check "nginx -t passes again" nginx -t

# The sudo rule gate, both ways. A test double stands in for `visudo -c` (whole configuration):
#   default  checks a 0440 copy of /etc/sudoers (a server whose whole-config check passes)
#   marker -mailer  fails once the new rule mentions "mailer"   → strict path: roll back
#   marker -always  fails before and after                     → fallback: visudo -cf + sudo -l
cat > /usr/local/sbin/visudo <<'EOF'
#!/bin/bash
if [[ $# == 1 && $1 == -c ]]; then
  [[ -e /tmp/team-srvtest-visudo-always ]] && { echo "visudo: simulated problem elsewhere in sudoers" >&2; exit 1; }
  if [[ -e /tmp/team-srvtest-visudo-mailer ]] && grep -qs mailer /etc/sudoers.d/team-pgapp-staging; then
    echo "visudo: simulated parse error" >&2; exit 1
  fi
  cp /etc/sudoers /tmp/team-srvtest-sudoers.copy && chmod 440 /tmp/team-srvtest-sudoers.copy
  exec /usr/sbin/visudo -cf /tmp/team-srvtest-sudoers.copy
fi
exec /usr/sbin/visudo "$@"
EOF
chmod 755 /usr/local/sbin/visudo
cp -R "$T/b-pg-s" "$T/b-pg-s-extra"
printf 'mailer|worker|python3 -m http.server 9999\n' >> "$T/b-pg-s-extra/ops/services.conf"
su_before=$(sha256sum /etc/sudoers.d/team-pgapp-staging)
touch /tmp/team-srvtest-visudo-mailer
expect_rc 1 "a sudo rule that breaks visudo -c fails provision" provision_run "$T/b-pg-s-extra" --apply
ok_if "  … and the previous sudo rule is back, byte for byte" '[[ $(sha256sum /etc/sudoers.d/team-pgapp-staging) == "$su_before" ]] && grep -q "TEAM-RESULT fail sudoers did not validate" $LOG'
rm -f /tmp/team-srvtest-visudo-mailer
expect_rc 0 "re-running the good bundle removes the extra unit again" provision_run "$T/b-pg-s" --apply
ok_if "  … ([remove] the stale unit)" 'grep -q "^\[remove\] systemd unit team-pgapp-staging-mailer.service" $LOG && [[ ! -e /etc/systemd/system/team-pgapp-staging-mailer.service ]]'
touch /tmp/team-srvtest-visudo-always
expect_rc 0 "when visudo -c already fails for other reasons (as on stock sudo-rs), provision still updates the rule" provision_run "$T/b-pg-s-extra" --apply
ok_if "  … says why, and checks the rule with visudo -cf and sudo -l instead" 'grep -q "^\[warn\] visudo -c already fails before this change" $LOG && [[ $(changes_in $LOG) -ge 2 ]]'
check "  … sudo really grants the new commands" sudo_lists pgapp-staging "/usr/bin/systemctl reload-or-restart team-pgapp-staging-mailer.service"
rm -f /usr/local/sbin/visudo /tmp/team-srvtest-visudo-always /tmp/team-srvtest-sudoers.copy
expect_rc 0 "back to the good bundle" provision_run "$T/b-pg-s" --apply
ok_if "  … the mailer commands are gone from the rule" '! grep -q mailer /etc/sudoers.d/team-pgapp-staging && [[ ! -e /etc/systemd/system/team-pgapp-staging-mailer.service ]]'
if [[ $SUDO_IMPL == sudo-rs && $(stat -c %a /etc/sudoers) == 644 ]]; then
  ok_if "stock sudo-rs (/etc/sudoers 0644): the first apply took the visudo -cf + sudo -l path" 'grep -q "^\[warn\] visudo -c already fails before this change" $T/apply-pg-s.log'
fi

# a web server the pack can't drive: the config is printed for a manual install, exit 6
cp /etc/nginx/nginx.conf "$T/nginx.conf.orig"
sed -i '/include \/etc\/nginx\/sites-enabled\//d' /etc/nginx/nginx.conf
FIXTURE=stapp make_bundle manualapp staging "$T/b-manual"
expect_rc 6 "nginx without sites-enabled: provision prints the vhost and exits 6 (manual step)" provision_run "$T/b-manual" --apply
ok_if "  … with the config printed, no vhost file written, and TEAM-RESULT fail" \
  'grep -q "^    | server {" $LOG && grep -q "^    |     server_name manualapp-staging.example.test;" $LOG && [[ ! -e /etc/nginx/sites-available/team-manualapp-staging.conf && $(tail -n 1 $LOG) == "TEAM-RESULT fail nginx does not include"* ]]'
cp "$T/nginx.conf.orig" /etc/nginx/nginx.conf
check "nginx.conf restored; nginx -t passes" nginx -t

# TLS vhost (certificate already present, as after certbot; certbot itself can't run here)
mkdir -p /etc/letsencrypt/live/team-tlsapp-staging
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=tlsapp-staging.example.test \
  -keyout /etc/letsencrypt/live/team-tlsapp-staging/privkey.pem -out /etc/letsencrypt/live/team-tlsapp-staging/fullchain.pem > /dev/null 2>&1
FIXTURE=stapp make_bundle tlsapp staging "$T/b-tls" 'TLS=on'
expect_rc 0 "provision with TLS=on and an existing certificate" provision_run "$T/b-tls" --apply
ok_if "TLS vhost: 443 ssl server + HTTP→HTTPS redirect (ACME path stays on HTTP)" \
  'grep -q "listen 443 ssl;" /etc/nginx/sites-available/team-tlsapp-staging.conf && grep -q "return 301 https://\$host\$request_uri;" /etc/nginx/sites-available/team-tlsapp-staging.conf && grep -q "APP_URL=https://tlsapp-staging.example.test" /srv/team/tlsapp/staging/shared/.env'
check "nginx -t passes with the TLS vhost" nginx -t
check "HTTP redirects to HTTPS" wait_http 301 -H "Host: tlsapp-staging.example.test" http://127.0.0.1/
check "HTTPS serves the staging site behind basic auth" wait_http 401 -k --resolve tlsapp-staging.example.test:443:127.0.0.1 https://tlsapp-staging.example.test/

# TLS from scratch: certbot test double does an HTTP-01 style fetch through nginx, then writes a
# self-signed certificate where certbot would (the real CA can't be reached from a test container)
cat > /usr/local/bin/certbot <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> /tmp/team-srvtest-certbot.args
webroot="" domain="" name=""
while (($#)); do case $1 in -w) webroot=$2; shift 2 ;; -d) domain=$2; shift 2 ;; --cert-name) name=$2; shift 2 ;; *) shift ;; esac; done
tok=$(openssl rand -hex 16)
mkdir -p "$webroot/.well-known/acme-challenge" && printf '%s' "$tok" > "$webroot/.well-known/acme-challenge/$tok"
got=$(curl -fsS -H "Host: $domain" "http://127.0.0.1/.well-known/acme-challenge/$tok") || { echo "challenge not served" >&2; exit 1; }
rm -f "$webroot/.well-known/acme-challenge/$tok"
[[ $got == "$tok" ]] || exit 1
mkdir -p "/etc/letsencrypt/live/$name"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=$domain" -keyout "/etc/letsencrypt/live/$name/privkey.pem" \
  -out "/etc/letsencrypt/live/$name/fullchain.pem" > /dev/null 2>&1
EOF
chmod 755 /usr/local/bin/certbot
rm -f /tmp/team-srvtest-certbot.args
FIXTURE=stapp make_bundle acmeapp staging "$T/b-acme" 'TLS=on'
expect_rc 0 "TLS=on without a certificate: provision gets one with certbot (webroot)" provision_run "$T/b-acme" --apply
ok_if "  … certbot ran non-interactive, webroot, own cert name, no email → --register-unsafely-without-email" \
  'grep -q -- "certonly --webroot -w /var/www/team-acme -d acmeapp-staging.example.test --cert-name team-acmeapp-staging --non-interactive --agree-tos" /tmp/team-srvtest-certbot.args && grep -q -- "--register-unsafely-without-email" /tmp/team-srvtest-certbot.args && grep -q -- "--deploy-hook systemctl reload nginx" /tmp/team-srvtest-certbot.args'
ok_if "  … then switched the vhost to HTTPS" 'grep -q "listen 443 ssl;" /etc/nginx/sites-available/team-acmeapp-staging.conf'
check "  … HTTPS answers (basic auth on staging)" wait_http 401 -k --resolve acmeapp-staging.example.test:443:127.0.0.1 https://acmeapp-staging.example.test/
check "  … the ACME path stays on plain HTTP for renewals (404 for a missing token, not a redirect)" wait_http 404 -H "Host: acmeapp-staging.example.test" http://127.0.0.1/.well-known/acme-challenge/missing
provision_run "$T/b-acme" --apply > "$LOG" 2>&1
ok_if "  … re-running is a no-op and doesn't call certbot again" '[[ $(changes_in $LOG) == 0 && $(wc -l < /tmp/team-srvtest-certbot.args) == 1 ]]'
FIXTURE=stapp make_bundle acme2app production "$T/b-acme2" 'TLS=on' 'ACME_EMAIL=ops@example.test'
expect_rc 0 "TLS=on with ACME_EMAIL" provision_run "$T/b-acme2" --apply
ok_if "  … registers with that email" 'tail -n 1 /tmp/team-srvtest-certbot.args | grep -q -- "-m ops@example.test" && ! tail -n 1 /tmp/team-srvtest-certbot.args | grep -q -- "--register-unsafely"'
rm -f /usr/local/bin/certbot
check "nginx -t passes with every vhost" nginx -t

# ============================================================================ 3. deploy-receive
section "3. deploy-receive"
P_PS=$(conf_get /etc/team/projects/pgapp-staging.conf PORT)
P_PP=$(conf_get /etc/team/projects/pgapp-production.conf PORT)
make_release "$T/rA" "$T/A.tgz" yes pgapp
make_release "$T/rB" "$T/B.tgz" no pgapp
make_release "$T/rC" "$T/C.tgz" yes pgapp
WEB1=$(stand_in_web pgapp-staging "$P_PS" /srv/team/pgapp/staging/current)
WEB2=$(stand_in_web pgapp-production "$P_PP" /srv/team/pgapp/production/current)
wait_port "$P_PS"; wait_port "$P_PP"
D=/srv/team/pgapp/staging
expect_rc 0 "deploy release A (healthy)" deploy_as pgapp-staging pgapp staging "deploy a1a1a1a" "$T/A.tgz"
ok_if "current → releases/a1a1a1a (symlink)" '[[ $(readlink $D/current) == $D/releases/a1a1a1a ]]'
ok_if ".env and SHARED_PATHS linked to shared/, shared/storage seeded from the first release" \
  '[[ $(readlink $D/current/.env) == $D/shared/.env && $(readlink $D/current/storage) == $D/shared/storage && -f $D/shared/storage/logs/seed.log ]]'
ok_if "MIGRATE_CMD ran in the release with the env loaded and TZ=UTC" '[[ $(cat $D/current/migrated.txt) == "pgapp_staging UTC" ]]'
ok_if "health check passes through nginx without a login on staging" '[[ $(curl -s -o /dev/null -w "%{http_code}" -H "Host: pgapp-staging.example.test" http://127.0.0.1/health) == 200 ]]'
ok_if "staging pages need the login (401), and work with it" \
  '[[ $(curl -s -o /dev/null -w "%{http_code}" -H "Host: pgapp-staging.example.test" http://127.0.0.1/) == 401 && $(curl -s -o /dev/null -w "%{http_code}" -u client:staging-pass-pgapp -H "Host: pgapp-staging.example.test" http://127.0.0.1/) == 200 ]]'
robots() { curl -s -D- -o /dev/null "$@" | tr -d '\r' | grep -qi '^X-Robots-Tag: noindex, nofollow$'; }
check "staging: X-Robots-Tag noindex on pages (logged in)" robots -u client:staging-pass-pgapp -H "Host: pgapp-staging.example.test" http://127.0.0.1/
check "staging: X-Robots-Tag noindex on HEALTH_PATH (no login)" robots -H "Host: pgapp-staging.example.test" http://127.0.0.1/health
check "staging: X-Robots-Tag noindex on the 401 login challenge" robots -H "Host: pgapp-staging.example.test" http://127.0.0.1/
check "staging: X-Robots-Tag noindex on a 404" robots -u client:staging-pass-pgapp -H "Host: pgapp-staging.example.test" http://127.0.0.1/no-such-page
check "staging (TLS): X-Robots-Tag noindex on the HTTP→HTTPS redirect" robots -H "Host: acmeapp-staging.example.test" http://127.0.0.1/
check "staging (TLS): X-Robots-Tag noindex on HEALTH_PATH over HTTPS" robots -k --resolve acmeapp-staging.example.test:443:127.0.0.1 https://acmeapp-staging.example.test/health
expect_rc 1 "deploy release B (health check fails) exits 1" deploy_as pgapp-staging pgapp staging "deploy b2b2b2b" "$T/B.tgz"
ok_if "  … and switched back to A automatically; B removed" '[[ $(readlink $D/current) == $D/releases/a1a1a1a && ! -e $D/releases/b2b2b2b ]] && grep -q "switched back to a1a1a1a" $LOG'
expect_rc 0 "deploy release C (healthy)" deploy_as pgapp-staging pgapp staging "deploy c3c3c3c" "$T/C.tgz"
expect_rc 0 "rollback <sha of A>" deploy_as pgapp-staging pgapp staging "rollback a1a1a1a"
ok_if "  … current → A" '[[ $(readlink $D/current) == $D/releases/a1a1a1a ]]'
expect_rc 0 "rollback by unique sha prefix (c3c3c3c → c3c3c3c…)" deploy_as pgapp-staging pgapp staging "rollback c3c3c3c"
expect_rc 7 "rollback to a sha the server doesn't have → exit 7" deploy_as pgapp-staging pgapp staging "rollback 9999999"
expect_rc 0 "health" deploy_as pgapp-staging pgapp staging "health"
ok_if "  … prints healthy and the current sha" 'grep -q "^healthy: current=c3c3c3c" $LOG'
expect_rc 0 "re-deploying the current sha is a no-op" deploy_as pgapp-staging pgapp staging "deploy c3c3c3c" "$T/C.tgz"
for bad in "rm -rf /" "deploy ../../etc" "deploy abc12" "deploy ABCDEF1" "health; id" "deploy a1a1a1a extra" "" "scp -t /tmp" "rollback"; do
  expect_rc 4 "forbidden command refused with exit 4: '${bad}'" deploy_as pgapp-staging pgapp staging "$bad"
done
expect_rc 4 "deploy-receive refuses to run as another user (root)" env SSH_ORIGINAL_COMMAND=health "$LIB/deploy-receive" pgapp staging
printf 'not a tarball' > "$T/junk.tgz"
expect_rc 1 "a corrupt tarball fails and changes nothing" deploy_as pgapp-staging pgapp staging "deploy deadbee" "$T/junk.tgz"
ok_if "  … current unchanged, no release or temp folder left" '[[ $(readlink $D/current) == $D/releases/c3c3c3c && ! -e $D/releases/deadbee && -z $(find $D/releases -maxdepth 1 -name ".incoming-*") ]]'
# the pipeline sends the full 40-character GITHUB_SHA
FULL=0123456789abcdef0123456789abcdef01234567
make_release "$T/rF" "$T/F.tgz" yes pgapp
expect_rc 0 "deploy with a full 40-character sha (as the pipeline sends GITHUB_SHA)" deploy_as pgapp-staging pgapp staging "deploy $FULL" "$T/F.tgz"
ok_if "  … the release is keyed by the full sha" '[[ $(readlink $D/current) == $D/releases/$FULL ]] && grep -q " deploy $FULL ok$" $D/deploys.log'
expect_rc 0 "rollback <7-char sha> back to c3c3c3c" deploy_as pgapp-staging pgapp staging "rollback c3c3c3c"
expect_rc 0 "rollback <full 40-char sha>" deploy_as pgapp-staging pgapp staging "rollback $FULL"
ok_if "  … current → the full-sha release" '[[ $(readlink $D/current) == $D/releases/$FULL ]]'
expect_rc 0 "rollback by a 7-char prefix of the full sha" deploy_as pgapp-staging pgapp staging "rollback ${FULL:0:7}"
expect_rc 4 "a 41-character sha is refused" deploy_as pgapp-staging pgapp staging "deploy ${FULL}8" "$T/F.tgz"
expect_rc 0 "back to c3c3c3c" deploy_as pgapp-staging pgapp staging "rollback c3c3c3c"

# hostile tarballs: path traversal, absolute paths, writing through a symlink, symlinked parent dirs
python3 - "$T/evil.tgz" "$T/sneaky.tgz" "$D" <<'PY'
import io, sys, tarfile
evil, sneaky, appdir = sys.argv[1:4]
def add(t, name, data=b"ok\n"):
    i = tarfile.TarInfo(name); i.size = len(data); t.addfile(i, io.BytesIO(data))
def link(t, name, target):
    i = tarfile.TarInfo(name); i.type = tarfile.SYMTYPE; i.linkname = target; t.addfile(i)
with tarfile.open(evil, "w:gz") as t:
    add(t, "health"); add(t, "../../escaped-dotdot"); add(t, "/tmp/escaped-abs")
    link(t, "storage", appdir + "/shared"); add(t, "storage/planted")
with tarfile.open(sneaky, "w:gz") as t:
    add(t, "health"); link(t, "uploads", appdir + "/shared")
PY
expect_rc 1 "a tarball with ../, absolute paths or writes through a symlink is rejected" deploy_as pgapp-staging pgapp staging "deploy e0e0e0e" "$T/evil.tgz"
ok_if "  … nothing escaped and nothing was left behind" \
  '[[ ! -e /srv/team/pgapp/escaped-dotdot && ! -e /srv/team/escaped-dotdot && ! -e /tmp/escaped-abs && ! -e $D/shared/planted && ! -e $D/releases/e0e0e0e && $(readlink $D/current) == $D/releases/c3c3c3c ]]'
mkdir -p "$D/shared/public" && printf 'keep\n' > "$D/shared/public/keep.txt" && chown -R pgapp-staging: "$D/shared/public"
expect_rc 0 "a symlinked parent of a SHARED_PATHS entry (uploads → shared/) is neutralized" deploy_as pgapp-staging pgapp staging "deploy 5eaa5eaa" "$T/sneaky.tgz"
ok_if "  … shared data outside the path is untouched; uploads/ is a real folder linking uploads/public" \
  '[[ -f $D/shared/public/keep.txt && -d $D/current/uploads && ! -L $D/current/uploads && $(readlink $D/current/uploads/public) == $D/shared/uploads/public ]]'
for i in 1 2 3 4 5 6; do make_release "$T/rd$i" "$T/d$i.tgz" yes pgapp; deploy_as pgapp-staging pgapp staging "deploy d00000$i" "$T/d$i.tgz" > /dev/null 2>&1; sleep 1; done
ok_if "keeps the last 5 releases" '[[ $(find $D/releases -mindepth 1 -maxdepth 1 -type d | wc -l) == 5 && $(readlink $D/current) == $D/releases/d000006 ]]'
ok_if "deploys are logged with UTC timestamps" 'grep -Eq "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z deploy b2b2b2b health-failed$" $D/deploys.log'
expect_rc 1 "first deploy that fails health (static, no previous release) exits 1" \
  deploy_as stapp-staging stapp staging "deploy 0badbad" "$T/B.tgz"
ok_if "  … leaves no current link and no release" '[[ ! -e /srv/team/stapp/staging/current && ! -e /srv/team/stapp/staging/releases/0badbad ]]'

# production: pre-deploy backup through the narrow sudo rule, then the release that snapshot reads
{ echo 'SET ROLE pgapp_production;'; cat "$FIX/seed-postgres.sql"; } | pg -d pgapp_production > /dev/null
my myapp_production < "$FIX/seed-mariadb.sql"
make_release "$T/rP" "$T/P.tgz" yes pgapp
expect_rc 0 "production deploy (postgres)" deploy_as pgapp-production pgapp production "deploy feedf00d" "$T/P.tgz"
ok_if "  … made a pre-deploy backup first (sudo -n backup pgapp --pre-deploy)" \
  'grep -q "\[ok\] backup /var/lib/team/pgapp/backups/backup-.*-pre-deploy.sql.gz" $LOG && ls /var/lib/team/pgapp/backups/backup-*-pre-deploy.sql.gz > /dev/null'
check_not "sudo rule is narrow: no plain backup for the production user" runuser -u pgapp-production -- sudo -n /usr/local/lib/team/backup pgapp
check_not "sudo rule is narrow: no other project's backup" runuser -u pgapp-production -- sudo -n /usr/local/lib/team/backup myapp --pre-deploy
check_not "sudo rule is narrow: staging can't run the backup" runuser -u pgapp-staging -- sudo -n /usr/local/lib/team/backup pgapp --pre-deploy
check_not "sudo rule is narrow: no shell" runuser -u pgapp-production -- sudo -n /bin/bash -c id

mkdir -p "$T/rM/public"
cat > "$T/rM/public/index.php" <<'EOF'
<?php
if ($_SERVER['REQUEST_URI'] === '/health') { echo "ok"; return; }
echo "hello from php as " . get_current_user();
EOF
cp -R "$FIX/myapp/ops" "$T/rM/ops"
tar -czf "$T/M.tgz" -C "$T/rM" .
expect_rc 0 "php-fpm staging deploy (health through nginx + php-fpm, no login)" deploy_as myapp-staging myapp staging "deploy abcdef12" "$T/M.tgz"
check "php-fpm staging: X-Robots-Tag noindex on HEALTH_PATH (front controller)" robots -H "Host: myapp-staging.example.test" http://127.0.0.1/health
ok_if "php-fpm staging: / needs the login, /health doesn't" \
  '[[ $(curl -s -o /dev/null -w "%{http_code}" -H "Host: myapp-staging.example.test" http://127.0.0.1/) == 401 && $(curl -s -H "Host: myapp-staging.example.test" http://127.0.0.1/health) == ok ]]'
expect_rc 0 "php-fpm production deploy (pre-deploy backup on mariadb)" deploy_as myapp-production myapp production "deploy abcdef12" "$T/M.tgz"
check_not "production: no X-Robots-Tag on HEALTH_PATH" robots -H "Host: pgapp.example.test" http://127.0.0.1/health
check_not "production: no X-Robots-Tag on pages" robots -H "Host: myapp.example.test" http://127.0.0.1/
ok_if "php-fpm production serves the app without a login" '[[ $(curl -s -o /dev/null -w "%{http_code}" -H "Host: myapp.example.test" http://127.0.0.1/) == 200 ]]'
expect_rc 0 "static production deploy (no database: pre-deploy backup skips)" deploy_as stapp-production stapp production "deploy 5ca1ab1e" "$T/A.tgz"
ok_if "static production serves current/public" '[[ $(curl -s -H "Host: stapp.example.test" http://127.0.0.1/health) == ok ]]'

# ============================================================================ 4. snapshot
section "4. snapshot → anonymize → check (postgres and mariadb)"
expect_rc 0 "snapshot --help" "$LIB/snapshot" --help
for eng in postgres mariadb; do
  if [[ $eng == postgres ]]; then P=pgapp; else P=myapp; fi
  SD=/var/lib/team/$P/snapshots
  expect_rc 0 "[$eng] snapshot $P" "$LIB/snapshot" "$P"
  latest=$(readlink "$SD/latest" 2>/dev/null)
  ok_if "[$eng] stored sanitized-<utc>.sql.gz, root:$P-production 640 in a 750 dir; latest → it" \
    '[[ $latest =~ ^sanitized-[0-9]{8}T[0-9]{6}Z\.sql\.gz$ && $(stat -c "%U:%G %a" $SD/$latest) == "root:$P-production 640" && $(stat -c "%U:%G %a" $SD) == "root:$P-production 750" ]]'
  zcat "$SD/$latest" > "$T/snap1-$eng.sql"
  ok_if "[$eng] the sanitized dump contains none of the original personal values" '! grep -F -f $FIX/original-values.txt $T/snap1-$eng.sql > $LOG'
  ok_if "[$eng] fake emails/phones/names are in place, plus the devlogin" \
    'grep -Eq "u[0-9a-f]{10}@example\.invalid" $T/snap1-$eng.sql && grep -Eq "\+1555[0-9]{7}" $T/snap1-$eng.sql && grep -q "dev@example.test" $T/snap1-$eng.sql && grep -q "knownDevLoginHashForLocalUseOnly00" $T/snap1-$eng.sql'
  if [[ $eng == postgres ]]; then
    ok_if "[postgres] restorable into an older local Postgres (no SET transaction_timeout line)" '! grep -q "^SET transaction_timeout" $T/snap1-postgres.sql'
  fi
  ok_if "[$eng] kept fields that are not personal (shipping city, totals)" 'grep -q "Baguio City" $T/snap1-$eng.sql && grep -q "15000.00" $T/snap1-$eng.sql'
  sleep 1
  expect_rc 0 "[$eng] second snapshot run" "$LIB/snapshot" "$P"
  zcat "$SD/$(readlink "$SD/latest")" > "$T/snap2-$eng.sql"
  ok_if "[$eng] deterministic: two runs give identical data" \
    'diff <(grep -vE "^\\\\(un)?restrict " $T/snap1-$eng.sql) <(grep -vE "^\\\\(un)?restrict " $T/snap2-$eng.sql) > $LOG'
  # restore into a scratch database to check keys and relations
  if [[ $eng == postgres ]]; then
    pg -d postgres -c 'DROP DATABASE IF EXISTS srvtest_restore' -c 'CREATE DATABASE srvtest_restore' > /dev/null
    pg -d srvtest_restore < "$T/snap1-$eng.sql" > /dev/null 2>&1
    q() { pgq -d srvtest_restore -c "$1"; }
  else
    myq -e 'DROP DATABASE IF EXISTS srvtest_restore; CREATE DATABASE srvtest_restore'
    my srvtest_restore < "$T/snap1-$eng.sql"
    q() { myq srvtest_restore -e "$1"; }
  fi
  ok_if "[$eng] the sanitized dump restores; unique emails stay unique" \
    '[[ $(q "SELECT count(*) FROM customers") == 8 && $(q "SELECT count(DISTINCT email) FROM customers") == 8 ]]'
  ok_if "[$eng] relations hold: orders still join customers on the faked email (6 rows)" \
    '[[ $(q "SELECT count(*) FROM orders o JOIN customers c ON c.email = o.customer_email") == 6 ]]'
  ok_if "[$eng] the same real email got the same fake in customers and users" \
    '[[ $(q "SELECT count(*) FROM users u JOIN customers c ON c.email = u.email") == 1 ]]'
  ok_if "[$eng] devlogin row has the known login" '[[ $(q "SELECT email FROM users WHERE id = 1") == dev@example.test ]]'
  ok_if "[$eng] nulled and redacted columns" '[[ $(q "SELECT count(*) FROM customers WHERE birth_date IS NOT NULL") == 0 && $(q "SELECT count(*) FROM users WHERE remember_token IS NOT NULL") == 0 ]]'
  if [[ $eng == mariadb ]]; then
    ok_if "[mariadb] trigger definitions are kept (without DEFINER)" 'grep -q "TRIGGER orders_total_bi" $T/snap1-mariadb.sql && ! grep -q "DEFINER=" $T/snap1-mariadb.sql'
    myq -e 'DROP DATABASE srvtest_restore'
  else
    pg -d postgres -c 'DROP DATABASE srvtest_restore' > /dev/null
  fi

  # refusals
  if [[ $eng == postgres ]]; then run() { pg -d pgapp_production -c "$1" > /dev/null; }; else run() { myq myapp_production -e "$1"; }; fi
  before=$(ls "$SD" | sort | tr '\n' ' ')
  run "ALTER TABLE customers ADD COLUMN notes text"
  run "UPDATE customers SET notes = 'call back via maria.alt.fixture@gmail.com' WHERE id = 2"
  expect_rc 4 "[$eng] REFUSES an unruled notes column holding an email (exit 4)" "$LIB/snapshot" "$P"
  ok_if "[$eng]   … reason names the table, not the value" 'grep -q "email-like value(s) outside the allowed fake domains (domains: gmail.com) in: .*customers" $LOG && ! grep -q "maria.alt.fixture" $LOG'
  run "ALTER TABLE customers DROP COLUMN notes"
  run "ALTER TABLE customers ADD COLUMN alt_phone text"
  run "UPDATE customers SET alt_phone = '+1 212 555 0100' WHERE id = 3"
  expect_rc 4 "[$eng] REFUSES an unruled phone column (alt_phone)" "$LIB/snapshot" "$P"
  ok_if "[$eng]   … because the column looks personal" 'grep -q "column customers.alt_phone looks personal" $LOG'
  run "ALTER TABLE customers DROP COLUMN alt_phone"
  run "ALTER TABLE orders ADD COLUMN remarks text"
  run "UPDATE orders SET remarks = 'rider: 0917 123 4567' WHERE id = 1"
  expect_rc 4 "[$eng] REFUSES a PH mobile number in an unruled column" "$LIB/snapshot" "$P"
  ok_if "[$eng]   … reported as a PH mobile number" 'grep -q "PH mobile number pattern found" $LOG'
  run "ALTER TABLE orders DROP COLUMN remarks"
  ok_if "[$eng] refusals stored nothing (snapshot folder unchanged)" '[[ $(ls $SD | sort | tr "\n" " ") == "$before" ]]'

  # A wildcard ignore may not name a personal-looking column (security finding H2): it would
  # silence check (a) for that column in every table, including tables added later.
  RULES_FILE=/srv/team/$P/production/current/ops/anonymize
  cp -p "$RULES_FILE" "$T/anonymize.orig"
  printf 'ignore|*|email|blanket ignore\n' >> "$RULES_FILE"
  before=$(ls "$SD" | sort | tr '\n' ' ')
  expect_rc 4 "[$eng] REFUSES ignore|*|email (wildcard ignore of a personal-looking column)" "$LIB/snapshot" "$P"
  ok_if "[$eng]   … names the line, and dumps, stores and creates nothing" \
    'grep -q "\[fail\] check: ops/anonymize line [0-9]*: ignore|\*|email would skip the personal-data check" $LOG && ! grep -q "dumped production" $LOG && [[ $(ls $SD | sort | tr "\n" " ") == "$before" && ! -s /var/lib/team/$P/tmp-databases ]]'
  cp -p "$T/anonymize.orig" "$RULES_FILE"
  printf 'ignore| * |Phone|case and spaces don\x27t help\n' >> "$RULES_FILE"
  expect_rc 4 "[$eng] REFUSES 'ignore| * |Phone' (case and spaces normalized)" "$LIB/snapshot" "$P"
  cp -p "$T/anonymize.orig" "$RULES_FILE"
  printf 'ignore|*|internal_code|not personal, fine in every table\n' >> "$RULES_FILE"
  expect_rc 0 "[$eng] a wildcard ignore of a column that doesn't look personal is still accepted" "$LIB/snapshot" "$P"
  cp -p "$T/anonymize.orig" "$RULES_FILE"
done
ok_if "temporary databases are always dropped (none left, registry empty)" \
  '[[ -z $(pgq -d postgres -c "SELECT datname FROM pg_database WHERE datname LIKE '"'"'team\_%'"'"'") && -z $(myq -e "SHOW DATABASES LIKE '"'"'team\\_%'"'"'") && ! -s /var/lib/team/pgapp/tmp-databases && ! -s /var/lib/team/myapp/tmp-databases ]]'
ok_if "no raw dumps or work folders left under /var/lib/team" '[[ -z $(find /var/lib/team -name ".snapshot-*" -o -name "raw.sql") ]]'
for i in 1 2 3 4 5 6; do "$LIB/snapshot" pgapp > /dev/null 2>&1; done
ok_if "snapshot retention keeps 7" '[[ $(find /var/lib/team/pgapp/snapshots -name "sanitized-*.sql.gz" | wc -l) == 7 ]]'
expect_rc 0 "snapshot of a project without a database skips" "$LIB/snapshot" stapp

# serve-snapshot
SD=/var/lib/team/pgapp/snapshots
serve() { runuser -u "$1" -- env SSH_ORIGINAL_COMMAND="$2" "$LIB/serve-snapshot" pgapp; }
expect_rc 0 "serve-snapshot latest-name (db-pull key, production user)" serve pgapp-production latest-name
ok_if "  … names the newest sanitized dump" '[[ $(cat $LOG) == $(readlink $SD/latest) ]]'
serve pgapp-production latest > "$T/pulled.sql.gz" 2> "$LOG"
ok_if "serve-snapshot latest streams exactly the newest sanitized dump" 'cmp -s $T/pulled.sql.gz $SD/$(readlink $SD/latest)'
for bad in "" "latest; id" "backup" "cat /etc/shadow" "latest ../backups"; do
  expect_rc 4 "serve-snapshot refuses '${bad}'" serve pgapp-production "$bad"
done
expect_rc 4 "serve-snapshot refuses other users (staging)" serve pgapp-staging latest
check_not "the staging user can't read the snapshots folder" runuser -u pgapp-staging -- ls "$SD"
check_not "the production user can't read backups" runuser -u pgapp-production -- ls /var/lib/team/pgapp/backups

# ============================================================================ 5. backup
section "5. backup and backup --verify (postgres and mariadb)"
expect_rc 0 "backup --help" "$LIB/backup" --help
for P in pgapp myapp; do
  expect_rc 0 "[$P] backup" "$LIB/backup" "$P"
  ok_if "[$P]   … says the off-server target isn't configured" 'grep -Fxq "[todo] off-server backup target not configured" $LOG'
  newest=$(find /var/lib/team/$P/backups -name 'backup-*Z.sql.gz' -printf '%f\n' | sort | tail -n 1)
  ok_if "[$P] backup-<utc>.sql.gz, root 600 in a root 700 folder, valid gzip" \
    '[[ $newest =~ ^backup-[0-9]{8}T[0-9]{6}Z\.sql\.gz$ && $(stat -c "%U %a" /var/lib/team/$P/backups/$newest) == "root 600" && $(stat -c "%U %a" /var/lib/team/$P/backups) == "root 700" ]] && gzip -t /var/lib/team/$P/backups/$newest'
  ok_if "[$P] the backup is faithful (holds the real rows; it never leaves the server)" 'zcat /var/lib/team/$P/backups/$newest | grep -q "jdc.fixture.0142@gmail.com"'
  expect_rc 0 "[$P] backup --verify" "$LIB/backup" "$P" --verify
  ok_if "[$P]   … restored the newest backup into a temp database with tables, then dropped it" 'grep -Eq "^\[ok\] verify: backup-.* \([1-9][0-9]* tables\)" $LOG'
done
ok_if "verify left no temporary database" \
  '[[ -z $(pgq -d postgres -c "SELECT datname FROM pg_database WHERE datname LIKE '"'"'team\_%'"'"'") && -z $(myq -e "SHOW DATABASES LIKE '"'"'team\\_%'"'"'") ]]'
printf 'THIS IS NOT SQL;\n' | gzip > /var/lib/team/pgapp/backups/backup-29991231T000000Z.sql.gz
expect_rc 1 "backup --verify fails on a broken newest backup" "$LIB/backup" pgapp --verify
rm -f /var/lib/team/pgapp/backups/backup-29991231T000000Z.sql.gz
for i in 1 2 3 4 5 6; do "$LIB/backup" pgapp --pre-deploy > /dev/null 2>&1; done
ok_if "pre-deploy retention keeps 5" '[[ $(find /var/lib/team/pgapp/backups -name "backup-*-pre-deploy.sql.gz" | wc -l) == 5 ]]'
cp /etc/team/backup.conf "$T/backup.conf.orig"
sed -i 's#^OFFSITE_BACKUP_TARGET=.*#OFFSITE_BACKUP_TARGET=s3://example-bucket/backups#' /etc/team/backup.conf
expect_rc 0 "with OFFSITE_BACKUP_TARGET set, backup still succeeds locally" "$LIB/backup" myapp
ok_if "  … and says the encrypted upload isn't built yet" 'grep -q "^\[todo\] OFFSITE_BACKUP_TARGET is set" $LOG'
cp "$T/backup.conf.orig" /etc/team/backup.conf
expect_rc 0 "backup of a project without a database skips" "$LIB/backup" stapp

# ============================================================================ 6. flag
section "6. flag"
{ echo 'SET ROLE pgapp_staging;'; cat "$FIX/seed-postgres.sql"; } | pg -d pgapp_staging > /dev/null
my myapp_staging < "$FIX/seed-mariadb.sql"
: > "$T/flag-before"
[[ -e /var/log/team/flags.log ]] && cp /var/log/team/flags.log "$T/flag-before"
expect_rc 0 "[postgres] flag pgapp staging new-checkout on --by tester" "$LIB/flag" pgapp staging new-checkout on --by tester
ok_if "[postgres]   … row inserted (enabled, by tester, updated_at within a minute of UTC now)" \
  '[[ $(pgq -d pgapp_staging -c "SELECT enabled, updated_by, abs(extract(epoch FROM (updated_at - (now() AT TIME ZONE '"'"'UTC'"'"')))) < 60 FROM feature_flags WHERE name = '"'"'new-checkout'"'"'") == "t|tester|t" ]]'
expect_rc 0 "[postgres] flag … off (upsert)" "$LIB/flag" pgapp staging new-checkout off --by tester
ok_if "[postgres]   … same row updated, not duplicated" '[[ $(pgq -d pgapp_staging -c "SELECT count(*), bool_or(enabled) FROM feature_flags WHERE name = '"'"'new-checkout'"'"'") == "1|f" ]]'
expect_rc 0 "[mariadb] flag myapp staging new-checkout on" "$LIB/flag" myapp staging new-checkout on --by tester
expect_rc 0 "[mariadb] flag myapp staging new-checkout off" "$LIB/flag" myapp staging new-checkout off --by tester
ok_if "[mariadb]   … one row, now off" '[[ $(myq myapp_staging -e "SELECT count(*), max(enabled) FROM feature_flags WHERE name = '"'"'new-checkout'"'"'" | tr "\t" "|") == "1|0" ]]'
SUDO_USER=owner "$LIB/flag" pgapp production new-checkout on > "$LOG" 2>&1
ok_if "--by defaults to the sudo user" 'grep -q " pgapp production new-checkout on owner$" /var/log/team/flags.log'
before_n=$(wc -l < "$T/flag-before")
tail -n +"$((before_n + 1))" /var/log/team/flags.log > "$T/flag-new"
ok_if "flags.log: one 'utc_ts project env name on|off by' line per change (root 640)" \
  '[[ $(wc -l < $T/flag-new) == 5 && $(stat -c "%U %a" /var/log/team/flags.log) == "root 640" ]] && ! grep -Evq "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z (pgapp|myapp) (staging|production) new-checkout (on|off) (tester|owner)$" $T/flag-new'
expect_rc 2 "flag rejects a bad name" "$LIB/flag" pgapp staging "Bad Name" on
expect_rc 3 "flag on a project without a database → not configured" "$LIB/flag" stapp staging x on

# ============================================================================ 7. timers
section "7. timers (production only, low-traffic hour in the project's timezone)"
ok_if "production timers exist; staging has none" \
  '[[ -e /etc/systemd/system/team-pgapp-snapshot.timer && -e /etc/systemd/system/team-pgapp-backup.timer && -e /etc/systemd/system/team-pgapp-backup-verify.timer && -z $(find /etc/systemd/system -name "team-*-staging*.timer") ]]'
ok_if "OnCalendar uses the project timezone (pgapp Asia/Manila 03:xx, myapp America/New_York 04:xx)" \
  'grep -Fxq "OnCalendar=*-*-* 03:20:00 Asia/Manila" /etc/systemd/system/team-pgapp-snapshot.timer && grep -Fxq "OnCalendar=Sun *-*-* 04:40:00 America/New_York" /etc/systemd/system/team-myapp-backup-verify.timer'
while IFS= read -r cal; do
  check "systemd-analyze calendar accepts '$cal'" systemd-analyze calendar "$cal"
done < <(sed -n 's/^OnCalendar=//p' /etc/systemd/system/team-*.timer | sort -u)
TEAM_TIMER_TZ_CONVERT=1 provision_run "$T/b-pg-p" > "$T/convert.out" 2>&1
ok_if "fallback without timezone support: converted to server time (Manila 03:00 → 19:00 UTC, Sun → Sat) with a DST note" \
  'grep -q "OnCalendar=\*-\*-\* 19:00:00)" $T/convert.out && grep -q "OnCalendar=Sat \*-\*-\* 19:40:00)" $T/convert.out && grep -q "^\[note\] .*daylight-saving" $T/convert.out'
while IFS= read -r cal; do
  check "systemd-analyze calendar accepts converted '$cal'" systemd-analyze calendar "$cal"
done < <(sed -n 's/.*(OnCalendar=\(.*\))$/\1/p' "$T/convert.out" | sort -u)
ok_if "the conversion plan changed nothing" 'grep -Fxq "OnCalendar=*-*-* 03:00:00 Asia/Manila" /etc/systemd/system/team-pgapp-backup.timer'

# ============================================================================ 8. refresh-staging
section "8. refresh-staging"
expect_rc 0 "refresh-staging plan" "$LIB/refresh-staging" pgapp
ok_if "  … plan changed nothing (staging still has its own rows)" '[[ $(pgq -d pgapp_staging -c "SELECT count(*) FROM customers WHERE email LIKE '"'"'%@gmail.com'"'"'") -gt 0 ]]'
mig_before=$(stat -c %Y /srv/team/pgapp/staging/current/migrated.txt)
sleep 1
expect_rc 0 "[postgres] refresh-staging --apply" "$LIB/refresh-staging" pgapp --apply
ok_if "[postgres]   … staging now holds the sanitized data, owned by the staging user" \
  '[[ $(pgq -d pgapp_staging -c "SELECT count(*) FROM customers WHERE email NOT LIKE '"'"'%@example.invalid'"'"'") == 0 && $(pgq -d pgapp_staging -c "SELECT tableowner FROM pg_tables WHERE tablename = '"'"'customers'"'"'") == pgapp_staging ]]'
ok_if "[postgres]   … and staging's migrations ran as the staging user" \
  '[[ $(stat -c %Y /srv/team/pgapp/staging/current/migrated.txt) -gt $mig_before && $(stat -c %U /srv/team/pgapp/staging/current/migrated.txt) == pgapp-staging ]]'
check_not "[postgres]   … production's user still can't connect to staging" env PGPASSWORD="$PW_PP" psql -X -h 127.0.0.1 -U pgapp_production -d pgapp_staging -Atc 'SELECT 1'
check "[postgres]   … staging's user still can" env PGPASSWORD="$PW_PS" psql -X -h 127.0.0.1 -U pgapp_staging -d pgapp_staging -Atc 'SELECT count(*) FROM customers'
expect_rc 0 "[mariadb] refresh-staging --apply" "$LIB/refresh-staging" myapp --apply
ok_if "[mariadb]   … staging now holds the sanitized data" '[[ $(myq myapp_staging -e "SELECT count(*) FROM customers WHERE email NOT LIKE '"'"'%@example.invalid'"'"'") == 0 ]]'
check "[mariadb]   … staging's user still connects" env MYSQL_PWD="$PW_MS" "$MYSQL_BIN" -h 127.0.0.1 -u myapp_staging myapp_staging -e 'SELECT count(*) FROM customers'
expect_rc 3 "refresh-staging without a database → not configured" "$LIB/refresh-staging" stapp

# ============================================================================ wrap-up
section "wrap-up"
ok_if "pre-existing user 'ubuntu' untouched" '[[ $(getent passwd ubuntu || true) == "$ubuntu_before" ]]'
ok_if "server timezone still unchanged" '[[ $(readlink /etc/localtime || true) == "$tz_before" ]]'
ok_if "no firewall was added" '! command -v ufw > /dev/null && ! command -v nft > /dev/null'
kill "$WEB1" "$WEB2" 2> /dev/null || true

printf '\n%s\n' "--------------------------------------------------------------------"
printf 'container suite: %d passed, %d failed (%ss)\n' "$PASS" "$FAIL" "$(( $(date +%s) - started ))"
if (( FAIL )); then printf 'failed: %s\n' "${FAILED[@]}"; exit 1; fi
exit 0
