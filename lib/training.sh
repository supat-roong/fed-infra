#!/usr/bin/env bash
# training.sh — Kubeflow Training Operator: registers the pytorchjobs CRD.

fed_training_install() {
  local ver=$1
  if [ "${FED_DRY_RUN:-0}" = "1" ]; then
    fed_log "dry-run: would install Training Operator ${ver}"
    return 0
  fi
  if kubectl get crd pytorchjobs.kubeflow.org >/dev/null 2>&1; then
    fed_log "Training Operator already installed"
    return 0
  fi
  fed_log "installing Kubeflow Training Operator ${ver}"
  kubectl apply -k "https://github.com/kubeflow/training-operator/manifests/overlays/standalone?ref=${ver}" || return 1
  kubectl wait --for condition=established --timeout=120s crd/pytorchjobs.kubeflow.org || return 1
  # A label selector that matches zero pods returns immediately with an
  # error instead of polling, and right after 'apply -k' the pod is usually
  # not scheduled yet, so fed_retry polls instead of a fixed sleep.
  #
  # The budget is FED_POD_READY_ATTEMPTS x (up to 30s wait + FED_RETRY_DELAY),
  # i.e. ~17 minutes at the defaults. It used to be a hardcoded 12 attempts
  # (~7 minutes) described in a comment as a "~120s ceiling" -- both the
  # number and the comment were wrong for anything but a warm single-cluster
  # bring-up. A cold multi-profile bring-up pulls the entire KFP image set
  # into three kind clusters competing for one machine's bandwidth, and was
  # measured still short of ready at 23 minutes, failing the bootstrap on a
  # wait rather than on any real error. Raised and made overridable so a
  # slower machine can extend it without patching the library. Nothing is
  # paid for a high ceiling when things are healthy: fed_retry returns on the
  # first success.
  fed_retry "$FED_POD_READY_ATTEMPTS" "$FED_RETRY_DELAY" kubectl wait --for=condition=ready pod \
    -l control-plane=kubeflow-training-operator \
    -n "${FED_KFP_NAMESPACE:-kubeflow}" --timeout=30s || return 1
}
