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

@test "fed_training_install also waits for the operator pod to become ready when absent" {
  export STUB_KUBECTL_FAIL_GLOB="get crd*"
  fed_training_install v1.7.0
  assert_called "wait --for=condition=ready pod -l control-plane=kubeflow-training-operator -n kubeflow --timeout=30s"
}

@test "fed_training_install honors FED_KFP_NAMESPACE for the pod-readiness wait" {
  export STUB_KUBECTL_FAIL_GLOB="get crd*"
  export FED_KFP_NAMESPACE=custom-ns
  fed_training_install v1.7.0
  assert_called "wait --for=condition=ready pod -l control-plane=kubeflow-training-operator -n custom-ns --timeout=30s"
}

@test "fed_training_install retries the pod-readiness wait instead of failing when no pod exists yet" {
  # Right after 'apply -k' the label selector can match zero pods, and a
  # bare 'kubectl wait' returns immediately with an error in that case
  # rather than polling. Simulate exactly that: the first wait call fails,
  # a later one (after fed_retry's delay) succeeds.
  export STUB_KUBECTL_FAIL_GLOB="get crd*"
  export STUB_KUBECTL_FAIL_ONCE_GLOB="wait --for=condition=ready pod*"
  export STUB_KUBECTL_FAIL_ONCE_COUNT=1
  run fed_training_install v1.7.0
  [ "$status" -eq 0 ]
  local attempts
  attempts=$(grep -c "wait --for=condition=ready pod" "$STUB_LOG")
  [ "$attempts" -eq 2 ]
}

@test "fed_training_install is a no-op when the CRD is already present" {
  fed_training_install v1.7.0   # probe succeeds by default
  refute_called "apply -k"
  refute_called "wait --for=condition=ready pod"
}

@test "fed_training_install does nothing at all under FED_DRY_RUN=1" {
  export FED_DRY_RUN=1
  fed_training_install v1.7.0
  refute_called "kubectl"
}

@test "fed_training_install honors FED_POD_READY_ATTEMPTS for the readiness wait" {
  # The default budget was tuned on single-cluster bring-ups. A cold
  # multi-cluster bring-up pulls the whole KFP image set across three kind
  # clusters at once and blows straight through it, so the ceiling has to be
  # raisable by the consumer rather than baked in. Three attempts here keeps
  # the test fast while still proving the knob is read.
  export STUB_KUBECTL_FAIL_GLOB="get crd*"
  export STUB_KUBECTL_FAIL_ONCE_GLOB="wait --for=condition=ready pod*"
  # 14 failures then success: reachable only if the knob raised the ceiling
  # above the built-in default, so this cannot pass by accident the way a
  # value *below* the default would.
  export STUB_KUBECTL_FAIL_ONCE_COUNT=14
  export FED_POD_READY_ATTEMPTS=15
  export FED_RETRY_DELAY=0
  run fed_training_install v1.7.0
  [ "$status" -eq 0 ]
  local attempts
  attempts=$(grep -c "wait --for=condition=ready pod" "$STUB_LOG")
  [ "$attempts" -eq 15 ]
}

@test "fed_training_install stops at FED_POD_READY_ATTEMPTS and fails rather than looping forever" {
  export STUB_KUBECTL_FAIL_GLOB="get crd*"
  export STUB_KUBECTL_FAIL_ONCE_GLOB="wait --for=condition=ready pod*"
  export STUB_KUBECTL_FAIL_ONCE_COUNT=99
  export FED_POD_READY_ATTEMPTS=2
  run fed_training_install v1.7.0
  [ "$status" -eq 1 ]
  local attempts
  attempts=$(grep -c "wait --for=condition=ready pod" "$STUB_LOG")
  [ "$attempts" -eq 2 ]
}
