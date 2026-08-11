.PHONY: test lint check
test:
	bats tests/
lint:
	shellcheck -x $$(find bin -type f 2>/dev/null) lib/*.sh tests/stubs/*
check: lint test
