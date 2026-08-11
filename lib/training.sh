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
}
