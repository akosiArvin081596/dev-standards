---
paths:
  - ".github/workflows/**"
  - "scripts/ci/**"
  - "config/**"
  - "tests/ci/**"
  - "tests/fixture-project/**"
---
# Workflows, CI scripts and gate config

- Reusable workflows are called `@v1` by every project: a breaking input or job-name change needs a new major.
- Check names must stay exactly as in `config/required-checks.json` (`ci / ci`, `gates / guarded-paths`, `gates / pr-title`, `self-test`, `template-ci`). Required workflows never use `paths:` filters, and the caller job ids are `ci` and `gates`.
- Pin third-party actions to a full commit SHA with the version in a comment; run on `ubuntu-24.04`; default `permissions` read-only, raised per job.
- No `pull_request_target`, no secrets in PR workflows. Read PR titles and bodies from env vars, never `${{ }}` inside a script.
- Never cancel a running deploy: deploy jobs use their own concurrency group with `cancel-in-progress: false`.
- `scripts/ci/` must also run on the Mac (bash 3.2). Run `/bin/bash tests/ci/run.sh`, `actionlint` and `shellcheck`.
- Gate changes (workflows, `scripts/ci/`, `config/`) keep `ai-security` pending until the owner's `owner-approved` is on the PR.
