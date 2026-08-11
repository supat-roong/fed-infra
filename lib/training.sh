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
  # not scheduled yet. fed_retry polls instead of a fixed sleep, keeping
  # roughly the same ~120s ceiling (12 attempts x up to 30s wait each, with
  # a 5s gap between attempts).
  fed_retry 12 5 kubectl wait --for=condition=ready pod \
    -l control-plane=kubeflow-training-operator \
    -n "${FED_KFP_NAMESPACE:-kubeflow}" --timeout=30s || return 1
}
