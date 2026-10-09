# fixture-app

<!-- Test fixture for dev-standards' ci.yml. Lean on purpose. -->

A stack-neutral fixture: a static page and a health file, built by plain shell.

- Timezone: Asia/Manila. Store and log times in UTC.

## Repo map
- `src/` — the page and the health file; `make build` copies them to the release.
- `db/migrations/` — SQL migrations (expand/contract only).
- `ops/project.conf`, `ops/anonymize` — server settings and anonymization rules.
- `tests/smoke_test.sh` — the only test.
- `docs/flags.md` — feature flag registry; `docs/decisions/` — decision records.

## Commands
- `make setup lint test build audit anonymize-check`
