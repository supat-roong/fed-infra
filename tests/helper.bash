FED_INFRA_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
export FED_INFRA_ROOT

setup_stubs() {
  export STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
  : > "$STUB_LOG"
  export PATH="$FED_INFRA_ROOT/tests/stubs:$PATH"
}

calls() { cat "$STUB_LOG"; }

assert_called() {
  if ! grep -qF -- "$1" "$STUB_LOG"; then
    echo "expected call not found: $1" >&2
    echo "--- actual calls ---" >&2
    cat "$STUB_LOG" >&2
    return 1
  fi
}

refute_called() {
  if grep -qF -- "$1" "$STUB_LOG"; then
    echo "unexpected call found: $1" >&2
    return 1
  fi
}
