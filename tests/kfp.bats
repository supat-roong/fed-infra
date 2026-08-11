#!/usr/bin/env bats
load helper

setup() {
  setup_stubs
  source "$FED_INFRA_ROOT/lib/common.sh"
  source "$FED_INFRA_ROOT/lib/config.sh"
  source "$FED_INFRA_ROOT/lib/kfp.sh"
  fed_config_defaults
}

@test "fed_kfp_install applies cluster-scoped resources then core when absent" {
  # Only the existence probe fails; the applies that follow must still succeed,
  # otherwise the second apply would never be reached.
  export STUB_KUBECTL_FAIL_GLOB="get deploy*"
  fed_kfp_install 2.4.0
  assert_called "cluster-scoped-resources?ref=2.4.0"
  assert_called "platform-agnostic?ref=2.4.0"
}

@test "fed_kfp_install is a no-op when KFP is already present" {
  fed_kfp_install 2.4.0   # probe succeeds by default
  refute_called "cluster-scoped-resources"
}

@test "fed_kfp_patch_arm repoints all four images at ghcr" {
  fed_kfp_patch_arm 2.4.0
  assert_called "ml-pipeline-ui=ghcr.io/kubeflow/kfp-frontend:2.4.0"
  assert_called "ml-pipeline-api-server=ghcr.io/kubeflow/kfp-api-server:2.4.0"
  assert_called "ml-pipeline-visualizationserver=ghcr.io/kubeflow/kfp-visualization-server:2.4.0"
  assert_called "V2_LAUNCHER_IMAGE=ghcr.io/kubeflow/kfp-launcher:2.4.0"
}

@test "fed_kfp_patch_arm pins the argo executor image" {
  fed_kfp_patch_arm 2.4.0
  assert_called "quay.io/argoproj/argoexec:v3.4.17"
}

@test "fed_kfp_patch_minio replaces rather than appends the ports array" {
  fed_kfp_patch_minio
  assert_called '"op":"replace","path":"/spec/template/spec/containers/0/ports"'
  refute_called '"path":"/spec/template/spec/containers/0/ports/-"'
}

@test "fed_kfp_patch_minio enables the console address" {
  fed_kfp_patch_minio
  assert_called '"--console-address"'
}

@test "fed_kfp_wait waits on all four core deployments" {
  fed_kfp_wait
  assert_called "rollout status deployment/workflow-controller -n kubeflow"
  assert_called "rollout status deployment/minio -n kubeflow"
  assert_called "rollout status deployment/ml-pipeline -n kubeflow"
  assert_called "rollout status deployment/ml-pipeline-ui -n kubeflow"
}
