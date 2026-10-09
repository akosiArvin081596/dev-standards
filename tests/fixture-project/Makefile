# Fixture project for dev-standards' ci.yml self-test (GNU Make 3.81 compatible).
# Stack-neutral on purpose: every target ci.yml calls succeeds with plain shell.

ARTIFACT_DIR := .team/artifact
# Inside CI the reusable workflow sets TEAM_STANDARDS_DIR; locally the fixture lives in dev-standards.
ANONYMIZE_LINT := $(if $(TEAM_STANDARDS_DIR),$(TEAM_STANDARDS_DIR),../..)/scripts/ci/anonymize-lint.sh

.PHONY: setup dev lint test e2e build audit migrate db-pull anonymize-check hooks

setup:
	@echo "setup: nothing to install"

lint:
	@sh -n tests/smoke_test.sh
	@test -f src/index.html && test -f src/health
	@echo "lint: ok"

test:
	@sh tests/smoke_test.sh

build:
	@d='$(ARTIFACT_DIR)'; rm -rf "$${d:?}" && mkdir -p "$$d" && cp -R src/. "$$d"/
	@echo "build: release files in $(ARTIFACT_DIR)"

audit:
	@echo "audit: no dependencies to audit"

anonymize-check:
	@bash $(ANONYMIZE_LINT) ops/anonymize

dev e2e migrate db-pull hooks:
	@echo "not configured: fill in for your stack" >&2; exit 3
