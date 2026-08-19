.PHONY: test lint check ci contracts
test:
	bats tests/
lint:
	shellcheck -x -P SCRIPTDIR $$(find bin -type f 2>/dev/null) lib/*.sh tests/stubs/*
check: lint test
# Tier 1: exactly what CI runs per PR. Kept identical to `check` so a
# developer and a runner cannot diverge.
ci: check
# Tier 2: render every contract this repo owns without touching a cluster.
# --dry-run performs no real side effects (enforced by tests/components.bats)
# but exercises config validation, the template whitelist and every
# component's dispatch path.
contracts:
	@set -e; for env in tests/fixtures/*.env; do \
		echo "=== dry-run $$env ==="; \
		out=$$(mktemp -d); \
		bin/fed-infra-up --env "$$env" --dry-run --render-dir "$$out"; \
		test -n "$$(ls -A $$out)" || { echo "FAIL: $$env rendered nothing"; exit 1; }; \
		rm -rf "$$out"; \
	done
