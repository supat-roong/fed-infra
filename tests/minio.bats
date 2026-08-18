#!/usr/bin/env bats
load helper

setup() {
  setup_stubs
  source "$FED_INFRA_ROOT/lib/common.sh"
  source "$FED_INFRA_ROOT/lib/config.sh"
  source "$FED_INFRA_ROOT/lib/render.sh"
  source "$FED_INFRA_ROOT/lib/minio.sh"
  fed_config_defaults
  export FED_NAMESPACE=demo-ns
  export FED_S3_ACCESS_KEY=ak FED_S3_SECRET_KEY=sk
}

@test "fed_minio_install applies namespace and minio, then waits for the statefulset" {
  fed_minio_install
  assert_called "kubectl apply -f -"
  assert_called "kubectl rollout status statefulset/minio -n demo-ns"
}

@test "fed_minio_install skips the rollout wait when dry-running" {
  export FED_DRY_RUN=1 FED_RENDER_DIR="$BATS_TEST_TMPDIR/out"
  fed_minio_install
  refute_called "kubectl rollout status"
  [ -f "$FED_RENDER_DIR/minio.yaml" ]
  [ -f "$FED_RENDER_DIR/namespace.yaml" ]
}

@test "fed_minio_ensure_bucket runs mc with the given endpoint and credentials" {
  fed_minio_ensure_bucket demo-ns minio-service:9000 ak sk mybucket
  assert_called "kubectl run"
  assert_called "mc alias set t http://minio-service:9000 ak sk"
  assert_called "mc mb t/mybucket --ignore-existing"
}

@test "fed_minio_ensure_bucket deletes any leftover pod before and after" {
  fed_minio_ensure_bucket demo-ns minio-service:9000 ak sk mybucket
  # grep -c >= 2 alone would pass on a double-delete on either side of
  # `kubectl run` with none on the other, since both `kubectl delete pod`
  # calls log an identical line -- only their position relative to
  # `kubectl run` in $STUB_LOG distinguishes "before and after" from
  # "twice before" or "twice after". Assert that ordering directly.
  local run_line first_delete_line last_delete_line
  run_line=$(grep -n '^kubectl run ' "$STUB_LOG" | head -1 | cut -d: -f1)
  first_delete_line=$(grep -n '^kubectl delete pod' "$STUB_LOG" | head -1 | cut -d: -f1)
  last_delete_line=$(grep -n '^kubectl delete pod' "$STUB_LOG" | tail -1 | cut -d: -f1)
  [ -n "$run_line" ] || return 1
  [ -n "$first_delete_line" ] || return 1
  [ -n "$last_delete_line" ] || return 1
  [ "$first_delete_line" -lt "$run_line" ] || return 1
  [ "$last_delete_line" -gt "$run_line" ]
}

@test "fed_minio_ensure_bucket is a no-op when dry-running" {
  export FED_DRY_RUN=1 FED_RENDER_DIR="$BATS_TEST_TMPDIR/out"
  fed_minio_ensure_bucket demo-ns minio-service:9000 ak sk mybucket
  refute_called "kubectl run"
}

@test "minio template renders credentials and namespace" {
  run fed_render "$FED_INFRA_ROOT/manifests/minio.yaml.tpl"
  [[ "$output" == *"namespace: demo-ns"* ]] || return 1
  [[ "$output" == *'value: "ak"'* ]] || return 1
  [[ "$output" == *"kind: StatefulSet"* ]]
}
