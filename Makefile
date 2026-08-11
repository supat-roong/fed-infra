.PHONY: test lint check
test:
	bats tests/
lint:
	shellcheck -x -P SCRIPTDIR $$(find bin -type f 2>/dev/null) lib/*.sh tests/stubs/*
check: lint test
