---
paths:
  - "plugins/team/server/**"
  - "tests/server/**"
---
# Server scripts

- They run on a shared VPS with other live sites: never edit another site's vhost, user, database or files, never change the server timezone, never add a firewall. Refuse to reuse an OS user, database or nginx file the pack didn't create (records in `/etc/team/projects/`).
- Plan by default, change only with `--apply`; safe to re-run; `rm -rf "${DIR:?}"/…` guards on every removal.
- Store times in UTC; schedule at the project's low-traffic hour in its own timezone.
- Production data leaves the server only as a sanitized snapshot that passed the PII check.
- Test only in throwaway containers named `team-srvtest-*` (`/bin/bash tests/server/run.sh`); never connect to the real VPS from tests.
- The only allowed TODO is the off-server backup target (`TODO(offsite-backup)`).
