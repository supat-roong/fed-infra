#!/usr/bin/env bats
load helper

setup() {
  setup_stubs
  source "$FED_INFRA_ROOT/lib/common.sh"
  source "$FED_INFRA_ROOT/lib/config.sh"
  source "$FED_INFRA_ROOT/lib/kfp.sh"
  fed_config_defaults
}

@test "fed_kfp_install clones the KFP repo at the requested tag" {
  # Only the existence probe fails; the clone that follows must still
  # succeed, otherwise neither apply would ever be reached.
  export STUB_KUBECTL_FAIL_GLOB="get deploy*"
  fed_kfp_install 2.4.0
  assert_called "git clone --depth 1 --branch 2.4.0 https://github.com/kubeflow/pipelines"
}

@test "fed_kfp_install applies both kustomize targets from the local clone, not a URL" {
  # kustomize enforces a hardcoded ~27s timeout on its own git fetch when
  # given a remote -k target, which a slow clone can exceed even though a
  # plain 'git clone' of the same repo succeeds. Applying from the local
  # checkout instead means these calls must never carry the git-url form.
  export STUB_KUBECTL_FAIL_GLOB="get deploy*"
  fed_kfp_install 2.4.0
  local tmp
  tmp=$(grep "git clone" "$STUB_LOG" | tail -1 | awk '{print $NF}')
  [ -n "$tmp" ]
  assert_called "kubectl apply -k $tmp/manifests/kustomize/cluster-scoped-resources"
  assert_called "kubectl apply -k $tmp/manifests/kustomize/env/platform-agnostic"
  run grep "kubectl apply -k" "$STUB_LOG"
  [[ "$output" != *"https://"* ]]
  # assert_called above only proves both applies happened, not in which
  # order -- cluster-scoped-resources must install the CRD that the second
  # apply's objects depend on, and the wait for it to establish must fall
  # between the two, or a reordering regression would still pass this test.
  local cluster_line wait_line platform_line
  cluster_line=$(grep -n "apply -k $tmp/manifests/kustomize/cluster-scoped-resources" "$STUB_LOG" | cut -d: -f1)
  wait_line=$(grep -n "wait --for condition=established --timeout=300s crd/applications.app.k8s.io" "$STUB_LOG" | cut -d: -f1)
  platform_line=$(grep -n "apply -k $tmp/manifests/kustomize/env/platform-agnostic" "$STUB_LOG" | cut -d: -f1)
  [ -n "$cluster_line" ] || return 1
  [ -n "$wait_line" ] || return 1
  [ -n "$platform_line" ] || return 1
  [ "$cluster_line" -lt "$wait_line" ] || return 1
  [ "$wait_line" -lt "$platform_line" ]
}

@test "fed_kfp_install removes the temp clone directory after a successful install" {
  export STUB_KUBECTL_FAIL_GLOB="get deploy*"
  fed_kfp_install 2.4.0
  local tmp
  tmp=$(grep "git clone" "$STUB_LOG" | tail -1 | awk '{print $NF}')
  [ -n "$tmp" ]
  [ ! -d "$tmp" ]
}

@test "fed_kfp_install removes the temp clone directory when an apply fails" {
  # Permanently fail the probe (so install proceeds) while transiently
  # failing only the first cluster-scoped-resources apply, independent of
  # STUB_KUBECTL_FAIL_GLOB above.
  export STUB_KUBECTL_FAIL_GLOB="get deploy*"
  export STUB_KUBECTL_FAIL_ONCE_GLOB="apply -k*cluster-scoped-resources*"
  run fed_kfp_install 2.4.0
  [ "$status" -ne 0 ]
  local tmp
  tmp=$(grep "git clone" "$STUB_LOG" | tail -1 | awk '{print $NF}')
  [ -n "$tmp" ]
  [ ! -d "$tmp" ]
}

@test "fed_kfp_install is a no-op when KFP is already present" {
  fed_kfp_install 2.4.0   # probe succeeds by default
  refute_called "git clone"
  refute_called "cluster-scoped-resources"
}

@test "fed_kfp_install is a complete no-op under FED_DRY_RUN=1" {
  export FED_DRY_RUN=1
  fed_kfp_install 2.4.0
  [ -z "$(calls)" ]
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

@test "fed_kfp_wait returns non-zero and stops on first deployment failure" {
  export STUB_KUBECTL_FAIL_GLOB="rollout status deployment/workflow-controller*"
  run fed_kfp_wait
  [ "$status" -ne 0 ]
  assert_called "rollout status deployment/workflow-controller -n kubeflow"
  refute_called "rollout status deployment/minio -n kubeflow"
  refute_called "rollout status deployment/ml-pipeline -n kubeflow"
  refute_called "rollout status deployment/ml-pipeline-ui -n kubeflow"
}
