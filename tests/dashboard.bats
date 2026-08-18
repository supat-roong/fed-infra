#!/usr/bin/env bats
load helper

setup() {
  setup_stubs
  source "$FED_INFRA_ROOT/lib/common.sh"
  source "$FED_INFRA_ROOT/lib/config.sh"
  source "$FED_INFRA_ROOT/lib/render.sh"
  source "$FED_INFRA_ROOT/lib/nodeport.sh"
  source "$FED_INFRA_ROOT/lib/dashboard.sh"
  fed_config_defaults
  export FED_NAMESPACE=demo-ns
  export FED_KARMADA_CONFIG="$BATS_TEST_TMPDIR/.karmada/karmada-apiserver.config"
}

# --- fed_k8s_dashboard_install ---

@test "fed_k8s_dashboard_install applies the upstream manifest pinned to the requested version" {
  export STUB_KUBECTL_FAIL_GLOB="get deployment kubernetes-dashboard*"
  fed_k8s_dashboard_install v2.7.0
  assert_called "kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml"
}

@test "fed_k8s_dashboard_install uses the given version, not a hardcoded one" {
  export STUB_KUBECTL_FAIL_GLOB="get deployment kubernetes-dashboard*"
  fed_k8s_dashboard_install v2.9.9
  assert_called "kubernetes/dashboard/v2.9.9/aio/deploy/recommended.yaml"
  refute_called "v2.7.0"
}

@test "fed_k8s_dashboard_install applies the admin ServiceAccount template" {
  export STUB_KUBECTL_FAIL_GLOB="get deployment kubernetes-dashboard*"
  fed_k8s_dashboard_install v2.7.0
  assert_called "kubectl apply -f -"
  grep -q "kind: ServiceAccount" "$STUB_STDIN_LOG"
  grep -q "namespace: demo-ns" "$STUB_STDIN_LOG"
}

@test "fed_k8s_dashboard_install is idempotent -- a second call with the dashboard namespace present does not re-apply" {
  # Default stub state: 'get deployment' succeeds, i.e. already installed.
  fed_k8s_dashboard_install v2.7.0
  refute_called "recommended.yaml"
  refute_called "kubectl apply -f -"
}

@test "fed_k8s_dashboard_install is a complete no-op under FED_DRY_RUN=1" {
  export FED_DRY_RUN=1 FED_RENDER_DIR="$BATS_TEST_TMPDIR/out"
  fed_k8s_dashboard_install v2.7.0
  [ -z "$(calls)" ]
  [ -f "$FED_RENDER_DIR/dashboard-admin.yaml" ]
}

@test "fed_k8s_dashboard_install fails fast when the upstream manifest apply fails" {
  export STUB_KUBECTL_FAIL_ONCE_GLOB="get deployment kubernetes-dashboard*"
  export STUB_KUBECTL_FAIL_GLOB2="*recommended.yaml*"
  run fed_k8s_dashboard_install v2.7.0
  [ "$status" -ne 0 ]
}

@test "fed_k8s_dashboard_install fails fast when the admin ServiceAccount apply fails" {
  export STUB_KUBECTL_FAIL_GLOB="get deployment kubernetes-dashboard*"
  export STUB_KUBECTL_FAIL_GLOB2="apply -f -"
  run fed_k8s_dashboard_install v2.7.0
  [ "$status" -ne 0 ]
}

# --- dashboard-admin.yaml.tpl ---

@test "dashboard-admin template renders a ServiceAccount and a cluster-admin ClusterRoleBinding namespaced by FED_NAMESPACE" {
  run fed_render "$FED_INFRA_ROOT/manifests/dashboard-admin.yaml.tpl"
  [[ "$output" == *"kind: ServiceAccount"* ]] || return 1
  [[ "$output" == *"kind: ClusterRoleBinding"* ]] || return 1
  [[ "$output" == *"name: cluster-admin"* ]] || return 1
  [[ "$output" == *"namespace: demo-ns"* ]]
}

# --- fed_karmada_dashboard_install ---

@test "fed_karmada_dashboard_install applies the dashboard manifest when not yet installed" {
  export STUB_KUBECTL_FAIL_ONCE_GLOB="get deployment karmada-dashboard*"
  fed_karmada_dashboard_install "$FED_KARMADA_CONFIG"
  assert_called "kubectl apply -f https://raw.githubusercontent.com/karmada-io/dashboard/main/deploy/karmada-dashboard.yaml"
}

@test "fed_karmada_dashboard_install creates the kubeconfig secret in both karmada-system and kubeflow" {
  fed_karmada_dashboard_install "$FED_KARMADA_CONFIG"
  assert_called "create secret generic karmada-kubeconfig --from-file=karmada-kubeconfig=${FED_KARMADA_CONFIG} -n karmada-system"
  assert_called "create secret generic karmada-kubeconfig-kf --from-file=karmada-kubeconfig=${FED_KARMADA_CONFIG} -n kubeflow"
}

@test "fed_karmada_dashboard_install grants the admin ServiceAccount cluster-admin against the Karmada apiserver, not the host" {
  fed_karmada_dashboard_install "$FED_KARMADA_CONFIG"
  assert_called "kubectl --kubeconfig=${FED_KARMADA_CONFIG} create serviceaccount karmada-admin-sa -n karmada-system"
  assert_called "kubectl --kubeconfig=${FED_KARMADA_CONFIG} create clusterrolebinding karmada-admin-sa-binding --clusterrole=cluster-admin --serviceaccount=karmada-system:karmada-admin-sa"
}

@test "fed_karmada_dashboard_install patches the Service to the configured NodePort" {
  export FED_NODEPORT_KARMADA_DASHBOARD=32050
  fed_karmada_dashboard_install "$FED_KARMADA_CONFIG"
  assert_called "kubectl patch service karmada-dashboard -n karmada-system"
  assert_called '"nodePort":32050'
}

@test "fed_karmada_dashboard_install is idempotent -- a second call with the dashboard already installed does not re-apply the manifest, but still refreshes the secrets and NodePort" {
  # Default stub state: 'get deployment karmada-dashboard' succeeds.
  fed_karmada_dashboard_install "$FED_KARMADA_CONFIG"
  refute_called "karmada-dashboard.yaml"
  assert_called "create secret generic karmada-kubeconfig"
  assert_called "kubectl patch service karmada-dashboard"
}

@test "fed_karmada_dashboard_install is a complete no-op under FED_DRY_RUN=1" {
  export FED_DRY_RUN=1
  fed_karmada_dashboard_install "$FED_KARMADA_CONFIG"
  [ -z "$(calls)" ]
}

@test "fed_karmada_dashboard_install fails fast when the dashboard manifest apply fails" {
  export STUB_KUBECTL_FAIL_ONCE_GLOB="get deployment karmada-dashboard*"
  export STUB_KUBECTL_FAIL_GLOB2="*karmada-dashboard.yaml*"
  run fed_karmada_dashboard_install "$FED_KARMADA_CONFIG"
  [ "$status" -ne 0 ]
  refute_called "create secret"
}

@test "fed_karmada_dashboard_install fails fast when creating the kubeconfig secret fails" {
  export STUB_KUBECTL_FAIL_GLOB="*create secret generic karmada-kubeconfig*"
  run fed_karmada_dashboard_install "$FED_KARMADA_CONFIG"
  [ "$status" -ne 0 ]
  refute_called "create serviceaccount"
}

@test "fed_karmada_dashboard_install fails fast when creating the admin ServiceAccount fails" {
  export STUB_KUBECTL_FAIL_GLOB="*create serviceaccount karmada-admin-sa*"
  run fed_karmada_dashboard_install "$FED_KARMADA_CONFIG"
  [ "$status" -ne 0 ]
  refute_called "clusterrolebinding"
}

@test "fed_karmada_dashboard_install fails fast when creating the admin ClusterRoleBinding fails" {
  export STUB_KUBECTL_FAIL_GLOB="*clusterrolebinding karmada-admin-sa-binding*"
  run fed_karmada_dashboard_install "$FED_KARMADA_CONFIG"
  [ "$status" -ne 0 ]
  refute_called "patch service karmada-dashboard"
}

@test "fed_karmada_dashboard_install fails fast when patching the Service fails" {
  export STUB_KUBECTL_FAIL_GLOB="*patch service karmada-dashboard*"
  run fed_karmada_dashboard_install "$FED_KARMADA_CONFIG"
  [ "$status" -ne 0 ]
}

@test "fed_karmada_dashboard_install waits for the dashboard rollout after a fresh install, best-effort" {
  export STUB_KUBECTL_FAIL_ONCE_GLOB="get deployment karmada-dashboard*"
  export STUB_KUBECTL_FAIL_GLOB2="rollout status deployment/karmada-dashboard*"
  run fed_karmada_dashboard_install "$FED_KARMADA_CONFIG"
  # The wait itself is best-effort (|| true in the original bootstrap this
  # ports) -- a failing rollout wait must not abort the rest of the install.
  [ "$status" -eq 0 ]
  assert_called "rollout status deployment/karmada-dashboard -n karmada-system"
  assert_called "create secret generic karmada-kubeconfig"
}

# --- fed_dashboard_token ---

@test "fed_dashboard_token calls kubectl create token with the given SA and namespace" {
  fed_dashboard_token myns mysa
  assert_called "kubectl create token mysa -n myns --duration=24h"
}

@test "fed_dashboard_token prints the token on stdout, redacted in the log, and never written to any file" {
  export STUB_KUBECTL_OUT="s3cr3t-token-value"
  local token
  token=$(fed_dashboard_token myns mysa 2>"$BATS_TEST_TMPDIR/stderr.log")
  [ "$token" = "s3cr3t-token-value" ] || return 1
  grep -qF "not logged" "$BATS_TEST_TMPDIR/stderr.log" || return 1
  ! grep -rqF "s3cr3t-token-value" "$BATS_TEST_TMPDIR"
}

@test "fed_dashboard_token is a complete no-op under FED_DRY_RUN=1" {
  export FED_DRY_RUN=1
  fed_dashboard_token myns mysa
  [ -z "$(calls)" ]
}

@test "fed_dashboard_token fails fast when kubectl create token fails" {
  export STUB_KUBECTL_FAIL_GLOB="create token*"
  run fed_dashboard_token myns mysa
  [ "$status" -ne 0 ]
}
