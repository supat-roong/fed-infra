#!/usr/bin/env bats
load helper

setup() { setup_stubs; }

render_consumer() {
  local name=$1 out=$2
  "$FED_INFRA_ROOT/bin/fed-infra-up" \
    --env "$FED_INFRA_ROOT/tests/fixtures/${name}.env" \
    --dry-run --render-dir "$out"
}

@test "consumer-a renders byte-identically to its golden files" {
  local out="$BATS_TEST_TMPDIR/a"
  render_consumer consumer-a "$out"
  run diff -r "$FED_INFRA_ROOT/tests/golden/consumer-a" "$out"
  [ "$status" -eq 0 ]
}

@test "consumer-b renders byte-identically to its golden files" {
  local out="$BATS_TEST_TMPDIR/b"
  render_consumer consumer-b "$out"
  run diff -r "$FED_INFRA_ROOT/tests/golden/consumer-b" "$out"
  [ "$status" -eq 0 ]
}

@test "the two consumers render materially different manifests" {
  local a="$BATS_TEST_TMPDIR/a" b="$BATS_TEST_TMPDIR/b"
  render_consumer consumer-a "$a"
  render_consumer consumer-b "$b"
  run diff "$a/mlflow-server.yaml" "$b/mlflow-server.yaml"
  [ "$status" -ne 0 ]
}
