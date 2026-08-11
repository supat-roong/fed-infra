#!/usr/bin/env bats
load helper

setup() {
  setup_stubs
  source "$FED_INFRA_ROOT/lib/common.sh"
  source "$FED_INFRA_ROOT/lib/config.sh"
  source "$FED_INFRA_ROOT/lib/render.sh"
  source "$FED_INFRA_ROOT/lib/mlflow.sh"
  fed_config_defaults
  export FED_NAMESPACE=demo-ns
  export FED_S3_ENDPOINT=minio-service:9000
  export FED_S3_ACCESS_KEY=ak FED_S3_SECRET_KEY=sk FED_S3_BUCKET=arts
}

@test "fed_mlflow_build_image builds when the image is absent" {
  # Only the existence probe fails; the build itself must still succeed.
  export STUB_DOCKER_FAIL_GLOB="image inspect*"
  fed_mlflow_build_image fed-mlflow:2.12.2 2.12.2
  assert_called "docker build -t fed-mlflow:2.12.2"
}

@test "fed_mlflow_build_image skips the build when the image exists" {
  fed_mlflow_build_image fed-mlflow:2.12.2 2.12.2   # probe succeeds by default
  refute_called "docker build"
}

@test "fed_mlflow_build_image cleans up context on build failure" {
  # Make all docker commands fail, including both the probe and the build.
  export STUB_DOCKER_FAIL_GLOB="*"
  # Capture the context path from docker build's last argument before it fails.
  run bash -c 'fed_mlflow_build_image fed-mlflow:2.12.2 2.12.2; return $?'
  [ $status -ne 0 ]  # Function must return non-zero
  # Extract the context path from the docker build command in the log.
  local ctx_path
  ctx_path=$(grep "docker build" "$STUB_LOG" | tail -1 | awk '{print $NF}')
  # Verify the context directory was cleaned up.
  [ -z "$ctx_path" ] || [ ! -d "$ctx_path" ]
}

@test "fed_mlflow_install applies the manifests and waits for rollout" {
  fed_mlflow_install
  assert_called "kubectl apply -f -"
  assert_called "kubectl rollout status deployment/mlflow-server -n demo-ns"
}

@test "fed_mlflow_install skips the rollout wait when dry-running" {
  export FED_DRY_RUN=1 FED_RENDER_DIR="$BATS_TEST_TMPDIR/out"
  fed_mlflow_install
  refute_called "kubectl rollout status"
  [ -f "$FED_RENDER_DIR/mlflow-server.yaml" ]
}

@test "mlflow template renders image, S3 endpoint, bucket, and nodePort" {
  export FED_MLFLOW_IMAGE=fed-mlflow:2.12.2 FED_NODEPORT_MLFLOW=30500
  run fed_render "$FED_INFRA_ROOT/manifests/mlflow-server.yaml.tpl"
  [[ "$output" == *"image: fed-mlflow:2.12.2"* ]]
  [[ "$output" == *"http://minio-service:9000"* ]]
  [[ "$output" == *"s3://arts"* ]]
  [[ "$output" == *"nodePort: 30500"* ]]
  [[ "$output" == *"namespace: demo-ns"* ]]
}

@test "mlflow template does not embed a pip install at pod start" {
  run fed_render "$FED_INFRA_ROOT/manifests/mlflow-server.yaml.tpl"
  [[ "$output" != *"pip install"* ]]
}
