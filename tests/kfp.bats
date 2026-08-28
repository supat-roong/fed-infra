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
  [[ "$output" != *"https://"* ]] || return 1
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

# --- juju mode ---

setup_juju() {
  source "$FED_INFRA_ROOT/lib/juju.sh"
  export FED_CLUSTER_NAME=demo FED_NAMESPACE=demo-ns FED_COMPONENTS=kfp
  export STUB_JUJU_OUT='workload:active'
}

@test "fed_kfp_install_juju deploys the kfp charm family into the kubeflow model" {
  setup_juju
  export STUB_JUJU_FAIL_GLOB="show-application*"
  fed_kfp_install_juju
  assert_called "juju deploy -m fed-demo:kubeflow mysql-k8s kfp-db --channel ${FED_MYSQL_CHANNEL} --trust --config profile=testing"
  assert_called "juju deploy -m fed-demo:kubeflow minio kfp-minio --channel ${FED_MINIO_CHANNEL}"
  assert_called "juju deploy -m fed-demo:kubeflow kfp-api kfp-api --channel ${FED_KFP_CHANNEL} --trust"
  assert_called "juju deploy -m fed-demo:kubeflow kfp-persistence kfp-persistence --channel ${FED_KFP_CHANNEL} --trust"
  assert_called "juju deploy -m fed-demo:kubeflow kfp-schedwf kfp-schedwf --channel ${FED_KFP_CHANNEL} --trust"
  assert_called "juju deploy -m fed-demo:kubeflow kfp-viewer kfp-viewer --channel ${FED_KFP_CHANNEL} --trust"
  assert_called "juju deploy -m fed-demo:kubeflow kfp-viz kfp-viz --channel ${FED_KFP_CHANNEL}"
  assert_called "juju deploy -m fed-demo:kubeflow kfp-ui kfp-ui --channel ${FED_KFP_CHANNEL}"
  assert_called "juju deploy -m fed-demo:kubeflow kfp-metadata-writer kfp-metadata-writer --channel ${FED_KFP_CHANNEL} --trust"
  assert_called "juju deploy -m fed-demo:kubeflow mlmd mlmd --channel ${FED_MLMD_CHANNEL} --trust"
  assert_called "juju deploy -m fed-demo:kubeflow envoy envoy --channel ${FED_ENVOY_CHANNEL}"
  assert_called "juju deploy -m fed-demo:kubeflow argo-controller argo-controller --channel ${FED_ARGO_CHANNEL} --trust"
}

@test "fed_kfp_install_juju fixes kfp-minio to the manifests-path bundled-minio credentials" {
  setup_juju
  fed_kfp_install_juju
  assert_called "juju config -m fed-demo:kubeflow kfp-minio access-key=minio secret-key=minio123"
}

@test "fed_kfp_install_juju wires the nine kfp relations" {
  setup_juju
  fed_kfp_install_juju
  assert_called "juju integrate -m fed-demo:kubeflow kfp-api:relational-db kfp-db:database"
  assert_called "juju integrate -m fed-demo:kubeflow kfp-api:object-storage kfp-minio:object-storage"
  assert_called "juju integrate -m fed-demo:kubeflow kfp-api:kfp-viz kfp-viz:kfp-viz"
  assert_called "juju integrate -m fed-demo:kubeflow kfp-persistence:kfp-api kfp-api:kfp-api"
  assert_called "juju integrate -m fed-demo:kubeflow kfp-ui:kfp-api kfp-api:kfp-api"
  assert_called "juju integrate -m fed-demo:kubeflow kfp-ui:object-storage kfp-minio:object-storage"
  assert_called "juju integrate -m fed-demo:kubeflow argo-controller:object-storage kfp-minio:object-storage"
  assert_called "juju integrate -m fed-demo:kubeflow kfp-metadata-writer:grpc mlmd:grpc"
  assert_called "juju integrate -m fed-demo:kubeflow envoy:grpc mlmd:grpc"
}

@test "fed_kfp_install_juju waits for the api and ui workloads" {
  setup_juju
  fed_kfp_install_juju
  assert_called "juju status -m fed-demo:kubeflow kfp-api --format=oneline"
  assert_called "juju status -m fed-demo:kubeflow kfp-ui --format=oneline"
}

@test "fed_kfp_install_juju never touches kustomize, git, or the ARM patches" {
  setup_juju
  fed_kfp_install_juju
  refute_called "git clone"
  refute_called "kubectl apply -k"
  refute_called "kubectl set image"
}

@test "fed_kfp_install_juju performs no real side effects under FED_DRY_RUN=1" {
  setup_juju
  export FED_DRY_RUN=1 FED_RENDER_DIR="$BATS_TEST_TMPDIR/out"
  fed_kfp_install_juju
  [ -z "$(calls)" ]
  grep -q "kfp-api" "$FED_RENDER_DIR/juju-commands.txt"
}
