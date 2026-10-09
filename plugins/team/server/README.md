# Server scripts

The Linux side of the pack. `team-provision` (on the Mac) sends these scripts, the project's `ops/`
and an `inputs.conf` to the VPS in one SSH connection and runs `sudo bash <dir>/provision --bundle <dir>
[--apply]` (contract: `docs/rules.md` §11–§12). `provision --apply` installs every script root-owned
(`root:root 0755`) in `/usr/local/lib/team/`; the forced commands, sudo rule and timers point there.

Bash 5 on Ubuntu 24.04 or a newer LTS (others get a warning); tested on 24.04 and 26.04, so it works
with classic sudo or sudo-rs, GNU or Rust (uutils) coreutils, PostgreSQL 16–18, MariaDB 10.11–11.8 and
PHP 8.3–8.5. Every script has `--help`, uses the exit codes in `docs/rules.md` §4, runs with
`LC_ALL=C`, and stores and logs times in UTC.

| Script | Runs as | What it does |
|---|---|---|
| `discover` | anyone (more with sudo) | Read-only `KEY: value` inventory: OS, sudo implementation (`SUDO: sudo-rs …` or classic), coreutils, web servers, databases, runtimes, sites, users, disk, RAM, ports, firewall, timers, cron (cron commands are not printed). |
| `provision --bundle <dir> [--apply]` | root | Plan by default. Sets up `<project>-<env>`: OS user, `/srv/team/<project>/<env>/{releases,shared,current}`, `shared/.env` from the template, port 9100–9899, database + least-privilege user, nginx vhost (proxy / php-fpm / static; staging gets basic auth + `noindex`), TLS via certbot, systemd units + logrotate, deploy key, narrow sudo rule; production also gets the db-pull key and the snapshot / backup / verify timers. Ends with `TEAM-HOSTKEY <type> <base64>` (the server's SSH host key: ed25519, else ecdsa, else rsa; never the hostname comment) and then `TEAM-RESULT ok` or `TEAM-RESULT fail <reason>`. |
| `deploy-receive <project> <env>` | env user (deploy key) | `deploy <sha>` (tarball on stdin) → unpack, link `shared/`, pre-deploy backup (production), `MIGRATE_CMD`, atomic switch, reload, health check, switch back on failure; `rollback <sha>` (exit 7 if the release is gone); `health`. Keeps 5 releases. |
| `snapshot <project>` | root (nightly timer) | Dump production without locks → temp DB → `ops/anonymize` (salted, deterministic) → refuse to store if personal data remains → `sanitized-<utc>.sql.gz`, keep 7. |
| `serve-snapshot <project>` | production user (db-pull key) | `latest` streams the newest sanitized dump; `latest-name` prints its name. Nothing else. |
| `refresh-staging <project> [--apply]` | root | Latest sanitized dump → staging database (only staging's own) → staging migrations. |
| `backup <project> [--verify\|--pre-deploy]` | root (timers, sudo rule) | Compressed dumps in `/var/lib/team/<project>/backups/` (14 nightly, 5 pre-deploy); `--verify` restores the newest into a temp DB and checks it has tables. |
| `flag <project> <env> <name> on\|off [--by who]` | root | Upserts `feature_flags` (UTC `updated_at`) and logs to `/var/log/team/flags.log`. |
| `lib.sh` | — | Shared helpers, the PII column patterns (an exact copy of `config/pii-patterns.txt`; the tests fail if they drift). |

## What the pack owns on a server

Everything above lives under `team-` names or `/etc/team`, `/srv/team`, `/var/lib/team`,
`/var/log/team`, `/usr/local/lib/team`. Each environment's ledger,
`/etc/team/projects/<project>-<env>.resources` (root 600), lists every user, database, database user
and file the pack created; `provision` refuses (exit 4) to reuse any of those names that are not in
the ledger, so other sites' users, vhosts and databases are never touched. Other rules: never
changes the server timezone, never adds a firewall, `rm -rf "${VAR:?}"/…` guards on every removal,
temporary databases are recorded before creation and only those are dropped.

The sudo rule is checked with `visudo -cf`, with `visudo -c` on the whole configuration when that
passed before the change (sudo-rs ships `/etc/sudoers` 0644, which its `visudo -c` flags), and with
`sudo -l -U <user>`, which must list every command; a rule that fails is replaced by the previous one.

Root-only extras next to the ledger: `<project>.salt` (anonymization salt, created once) and
`<project>-<env>.dbpass` (the generated database password, so new env-template keys can be filled
later without resetting it). If MySQL/MariaDB root can't log in over the socket, put client options
in `/etc/team/mysql-admin.cnf` (root 600).

## Off-server backups (the one open item)

Backups stay on the server until a storage target is chosen. Set `OFFSITE_BACKUP_TARGET` in
`/etc/team/backup.conf`; while it is empty, `backup` prints `[todo] off-server backup target not
configured`. The encrypted (`age`) upload goes where `backup` carries the `offsite-backup` marker.

## Testing

`/bin/bash tests/server/run.sh` on the Mac: shellcheck and `bash -n` on every script, the one-open-item
rule, a scan for real IPs and host names, the PII-pattern drift check, then the full suite in one
throwaway container per base (`ubuntu:24.04` then `ubuntu:26.04`; pick with `--base`), named
`team-srvtest-*` and removed afterwards. It never connects to
a real server. What a container can't show (real systemd, certbot, sshd forced-command wiring) is
listed in `tests/server/in-container.sh` and the build report.
