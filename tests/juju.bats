#!/usr/bin/env bats
load helper

setup() {
  setup_stubs
  source "$FED_INFRA_ROOT/lib/common.sh"
  source "$FED_INFRA_ROOT/lib/config.sh"
  source "$FED_INFRA_ROOT/lib/juju.sh"
  export FED_CLUSTER_NAME=demo FED_NAMESPACE=demo-ns
  export FED_COMPONENTS="minio,mlflow"
  fed_config_defaults
}

@test "fed_juju_cloud_name and fed_juju_controller_name derive from FED_CLUSTER_NAME" {
  [ "$(fed_juju_cloud_name)" = "fed-demo-k8s" ]
  [ "$(fed_juju_controller_name)" = "fed-demo" ]
}

@test "fed_juju runs the juju CLI outside dry-run" {
  fed_juju status
  assert_called "juju status"
}

@test "fed_juju logs instead of executing under FED_DRY_RUN=1 and records the command" {
  export FED_DRY_RUN=1 FED_RENDER_DIR="$BATS_TEST_TMPDIR/out"
  fed_juju deploy minio
  refute_called "juju deploy"
  grep -q "juju deploy minio" "$FED_RENDER_DIR/juju-commands.txt"
}

@test "fed_deploy_mode honors explicit manifests and juju values" {
  export FED_DEPLOY_MODE=manifests
  [ "$(fed_deploy_mode)" = "manifests" ]
  export FED_DEPLOY_MODE=juju
  [ "$(fed_deploy_mode)" = "juju" ]
}

@test "fed_deploy_mode auto resolves juju on an amd64 docker daemon" {
  export FED_DEPLOY_MODE=auto STUB_DOCKER_OUT=amd64
  [ "$(fed_deploy_mode)" = "juju" ]
}

@test "fed_deploy_mode auto resolves manifests on a non-amd64 daemon" {
  export FED_DEPLOY_MODE=auto STUB_DOCKER_OUT=arm64
  [ "$(fed_deploy_mode)" = "manifests" ]
}

@test "fed_deploy_mode auto resolves manifests under FED_DRY_RUN=1 without probing docker" {
  export FED_DEPLOY_MODE=auto FED_DRY_RUN=1 STUB_DOCKER_OUT=amd64
  [ "$(fed_deploy_mode)" = "manifests" ]
  refute_called "docker version"
}

@test "fed_config_validate rejects an invalid FED_DEPLOY_MODE" {
  ENVFILE="$BATS_TEST_TMPDIR/infra.env"
  cat > "$ENVFILE" <<'EOF'
FED_CLUSTER_NAME=demo
FED_NAMESPACE=demo-ns
FED_PROFILE=single
FED_COMPONENTS=minio
FED_DEPLOY_MODE=sideways
EOF
  run bash -c "source '$FED_INFRA_ROOT/lib/common.sh'; source '$FED_INFRA_ROOT/lib/config.sh'; fed_config_load '$ENVFILE'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FED_DEPLOY_MODE"* ]]
}

@test "fed_juju_require accepts a 3.x client and rejects a 4.x client" {
  export STUB_JUJU_OUT="3.6.27-osx-arm64"
  fed_juju_require
  export STUB_JUJU_OUT="4.0.14-osx-arm64"
  run fed_juju_require
  [ "$status" -eq 1 ]
  [[ "$output" == *"3.6"* ]]
}

@test "fed_juju_models lists the consumer model for minio/mlflow/temporal" {
  export FED_COMPONENTS="minio,mlflow,temporal"
  [ "$(fed_juju_models)" = "demo-ns" ]
}

@test "fed_juju_models adds the kubeflow model for training, deduplicated" {
  export FED_COMPONENTS="minio,training"
  [ "$(fed_juju_models)" = "demo-ns kubeflow" ]
  export FED_NAMESPACE=kubeflow FED_COMPONENTS="mlflow,training"
  [ "$(fed_juju_models)" = "kubeflow" ]
}

@test "fed_juju_components_enabled is true for juju components and false otherwise" {
  export FED_COMPONENTS="minio"
  run fed_juju_components_enabled
  [ "$status" -eq 0 ]
  export FED_COMPONENTS="karmada,k8s-dashboard,kfp"
  run fed_juju_components_enabled
  [ "$status" -eq 1 ]
}

@test "fed_juju_ensure registers cloud, bootstraps, and adds models when nothing exists" {
  export STUB_JUJU_FAIL_GLOB="show-*"
  fed_juju_ensure
  assert_called "juju add-k8s fed-demo-k8s --client --context-name kind-demo"
  assert_called "juju bootstrap fed-demo-k8s fed-demo"
  assert_called "juju add-model demo-ns fed-demo-k8s --controller fed-demo"
}

@test "fed_juju_ensure skips cloud, controller, and model creation when they already exist" {
  fed_juju_ensure
  refute_called "juju add-k8s"
  refute_called "juju bootstrap"
  refute_called "juju add-model"
}

@test "fed_juju_ensure is a complete no-op under FED_DRY_RUN=1" {
  export FED_DRY_RUN=1 FED_RENDER_DIR="$BATS_TEST_TMPDIR/out"
  fed_juju_ensure
  [ -z "$(calls)" ]
}
