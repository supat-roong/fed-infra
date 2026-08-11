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
  run bash -c "grep -c 'kubectl delete pod' '$STUB_LOG'"
  [ "$output" -ge 2 ]
}

@test "fed_minio_ensure_bucket is a no-op when dry-running" {
  export FED_DRY_RUN=1 FED_RENDER_DIR="$BATS_TEST_TMPDIR/out"
  fed_minio_ensure_bucket demo-ns minio-service:9000 ak sk mybucket
  refute_called "kubectl run"
}

@test "minio template renders credentials and namespace" {
  run fed_render "$FED_INFRA_ROOT/manifests/minio.yaml.tpl"
  [[ "$output" == *"namespace: demo-ns"* ]]
  [[ "$output" == *'value: "ak"'* ]]
  [[ "$output" == *"kind: StatefulSet"* ]]
}
