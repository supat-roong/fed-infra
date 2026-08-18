#!/usr/bin/env bash
# dashboard.sh — Kubernetes Dashboard, Karmada Dashboard, and a shared 24h
# access-token helper for both.
#
# fed_dashboard_token deliberately takes no kubeconfig/context argument: it
# is a thin two-arg wrapper around `kubectl create token`, shared by both
# dashboards, that relies entirely on the caller's ambient kubectl context
# (or $KUBECONFIG). For the Kubernetes Dashboard that is the host cluster's
# current context, already selected before any component install runs. For
# the Karmada Dashboard the admin ServiceAccount lives inside the Karmada
# control plane's own apiserver, not the host cluster's -- a caller wanting
# that token sets KUBECONFIG="$FED_KARMADA_CONFIG" (or an equivalent
# --kubeconfig wrapper) first, the same way every other Karmada-apiserver
# call in this library does.

FED_K8S_DASHBOARD_NAMESPACE=kubernetes-dashboard
FED_KARMADA_DASHBOARD_NAMESPACE=karmada-system
FED_KARMADA_ADMIN_SA=karmada-admin-sa

fed_k8s_dashboard_install() {
  local version=$1
  if [ "${FED_DRY_RUN:-0}" = "1" ]; then
    fed_log "dry-run: would install the Kubernetes Dashboard ${version}"
    fed_apply "${FED_INFRA_ROOT}/manifests/dashboard-admin.yaml.tpl" dashboard-admin
    return 0
  fi

  if kubectl get deployment kubernetes-dashboard -n "$FED_K8S_DASHBOARD_NAMESPACE" >/dev/null 2>&1; then
    fed_log "Kubernetes Dashboard already installed"
    return 0
  fi

  fed_log "installing Kubernetes Dashboard ${version}"
  kubectl apply -f "https://raw.githubusercontent.com/kubernetes/dashboard/${version}/aio/deploy/recommended.yaml" || return 1
  fed_apply "${FED_INFRA_ROOT}/manifests/dashboard-admin.yaml.tpl" dashboard-admin
}

# Ported from the original hand-rolled bootstrap (installs the Karmada
# Dashboard, wires it to the Karmada control plane's kubeconfig, and exposes
# it on a NodePort). Runs against the host cluster's current kubectl context
# for everything except the Karmada-apiserver-scoped ServiceAccount/binding
# below, which explicitly targets $karmada_config instead.
fed_karmada_dashboard_install() {
  local karmada_config=$1
  if [ "${FED_DRY_RUN:-0}" = "1" ]; then
    fed_log "dry-run: would install the Karmada Dashboard and expose it on NodePort ${FED_NODEPORT_KARMADA_DASHBOARD}"
    return 0
  fi

  if kubectl get deployment karmada-dashboard -n "$FED_KARMADA_DASHBOARD_NAMESPACE" >/dev/null 2>&1; then
    fed_log "Karmada Dashboard already installed"
  else
    fed_log "installing the Karmada Dashboard"
    kubectl apply -f https://raw.githubusercontent.com/karmada-io/dashboard/main/deploy/karmada-dashboard.yaml || return 1
    # Best-effort, matching the original bootstrap (`|| true`): a slow or
    # stalled rollout must not abort the secret/token wiring below, which is
    # what actually makes the dashboard usable once its pods do come up.
    kubectl rollout status deployment/karmada-dashboard -n "$FED_KARMADA_DASHBOARD_NAMESPACE" --timeout=5m || true
  fi

  # The dashboard backend reads its Karmada-apiserver kubeconfig from this
  # Secret. Re-created on every call, not only right after a fresh install --
  # same reasoning as fed_karmada_join's Docker-IP re-patch in lib/karmada.sh:
  # $karmada_config's contents can change (e.g. a re-issued certificate)
  # independently of whether the Deployment itself already exists. The
  # second, identically-keyed copy in kubeflow is ported as-is from the
  # original bootstrap this replaces.
  #
  # Each `create ... --dry-run=client -o yaml | kubectl apply -f -` pair is
  # deliberately NOT one bare pipe with a single trailing `|| return 1`: a
  # pipeline's own exit status is only the *last* command's unless the
  # caller happens to have `set -o pipefail` active (true for bin/fed-infra-up,
  # not guaranteed for every caller, e.g. a bats test invoking this function
  # directly). Capturing the render into a variable first and guarding that
  # assignment, then piping the variable through a second, separately-guarded
  # command, makes both stages fail fast regardless of the caller's shell
  # options -- the same "don't assume the caller's set -e/-o pipefail"
  # discipline as the guarded command substitutions elsewhere in this
  # library (see the ip=$(...) comment in lib/karmada.sh).
  fed_log "writing the Karmada kubeconfig secret"
  local secret_yaml
  secret_yaml=$(kubectl create secret generic karmada-kubeconfig \
    --from-file=karmada-kubeconfig="$karmada_config" -n "$FED_KARMADA_DASHBOARD_NAMESPACE" \
    --dry-run=client -o yaml) || return 1
  printf '%s\n' "$secret_yaml" | kubectl apply -f - || return 1

  secret_yaml=$(kubectl create secret generic karmada-kubeconfig-kf \
    --from-file=karmada-kubeconfig="$karmada_config" -n kubeflow \
    --dry-run=client -o yaml) || return 1
  printf '%s\n' "$secret_yaml" | kubectl apply -f - || return 1

  # This ServiceAccount lives inside the Karmada control plane's own
  # apiserver, not the host cluster's -- every call here targets it
  # explicitly via --kubeconfig rather than the ambient kubectl context.
  # fed_dashboard_token later mints a 24h token for it; see that function's
  # own comment for why it takes no kubeconfig argument itself.
  fed_log "granting ${FED_KARMADA_ADMIN_SA} cluster-admin for dashboard login"
  local sa_yaml
  sa_yaml=$(kubectl --kubeconfig="$karmada_config" create serviceaccount "$FED_KARMADA_ADMIN_SA" \
    -n "$FED_KARMADA_DASHBOARD_NAMESPACE" --dry-run=client -o yaml) || return 1
  printf '%s\n' "$sa_yaml" | kubectl --kubeconfig="$karmada_config" apply -f - || return 1

  local binding_yaml
  binding_yaml=$(kubectl --kubeconfig="$karmada_config" create clusterrolebinding "${FED_KARMADA_ADMIN_SA}-binding" \
    --clusterrole=cluster-admin \
    --serviceaccount="${FED_KARMADA_DASHBOARD_NAMESPACE}:${FED_KARMADA_ADMIN_SA}" \
    --dry-run=client -o yaml) || return 1
  printf '%s\n' "$binding_yaml" | kubectl --kubeconfig="$karmada_config" apply -f - || return 1

  fed_expose_nodeport karmada-dashboard "$FED_KARMADA_DASHBOARD_NAMESPACE" \
    "[{\"name\":\"http\",\"port\":80,\"targetPort\":80,\"nodePort\":${FED_NODEPORT_KARMADA_DASHBOARD}}]" || return 1
}

# Thin, dashboard-agnostic wrapper around `kubectl create token`: mints a 24h
# token for an already-existing ServiceAccount and hands it back on stdout
# only -- never through fed_log, which would put a cluster-admin credential
# in whatever the caller happens to redirect its logs to. See the top-of-file
# comment for why this takes no kubeconfig argument of its own.
fed_dashboard_token() {
  local ns=$1 sa=$2 token
  if [ "${FED_DRY_RUN:-0}" = "1" ]; then
    fed_log "dry-run: would create a 24h dashboard token for ${sa} in ${ns} (not logged)"
    return 0
  fi
  token=$(kubectl create token "$sa" -n "$ns" --duration=24h) || return 1
  fed_log "created 24h dashboard token for ${sa} in ${ns} (not logged)"
  printf '%s' "$token"
}
