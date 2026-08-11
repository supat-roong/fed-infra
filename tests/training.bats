#!/usr/bin/env bats
load helper

setup() {
  setup_stubs
  source "$FED_INFRA_ROOT/lib/common.sh"
  source "$FED_INFRA_ROOT/lib/config.sh"
  source "$FED_INFRA_ROOT/lib/training.sh"
  fed_config_defaults
}

@test "fed_training_install applies the operator manifest and waits for the CRD when absent" {
  # Only the existence probe fails; the apply and wait that follow must still succeed.
  export STUB_KUBECTL_FAIL_GLOB="get crd*"
  fed_training_install v1.7.0
  assert_called "apply -k https://github.com/kubeflow/training-operator/manifests/overlays/standalone?ref=v1.7.0"
  assert_called "wait --for condition=established --timeout=120s crd/pytorchjobs.kubeflow.org"
}

@test "fed_training_install is a no-op when the CRD is already present" {
  fed_training_install v1.7.0   # probe succeeds by default
  refute_called "apply -k"
}

@test "fed_training_install does nothing at all under FED_DRY_RUN=1" {
  export FED_DRY_RUN=1
  fed_training_install v1.7.0
  refute_called "kubectl"
}
