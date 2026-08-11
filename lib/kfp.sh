#!/usr/bin/env bash
# kfp.sh — Kubeflow Pipelines install, ARM/kind stability patches, readiness.
# The patches exist because the upstream images published to gcr.io are either
# amd64-only or no longer served; ghcr.io hosts working multi-arch equivalents.

FED_KFP_NAMESPACE=kubeflow
FED_ARGOEXEC_IMAGE="quay.io/argoproj/argoexec:v3.4.17"

fed_kfp_install() {
  local ver=$1
  if kubectl get deploy -n "$FED_KFP_NAMESPACE" ml-pipeline >/dev/null 2>&1; then
    fed_log "KFP already installed"
    return 0
  fi
  fed_log "installing KFP ${ver} cluster-scoped resources"
  kubectl apply -k "https://github.com/kubeflow/pipelines/manifests/kustomize/cluster-scoped-resources?ref=${ver}"
  kubectl wait --for condition=established --timeout=300s crd/applications.app.k8s.io
  fed_log "installing KFP ${ver} core"
  kubectl apply -k "https://github.com/kubeflow/pipelines/manifests/kustomize/env/platform-agnostic?ref=${ver}"
}

fed_kfp_patch_arm() {
  local ver=$1 ns=$FED_KFP_NAMESPACE
  fed_log "patching KFP images for ARM/kind stability"
  kubectl set image deployment/ml-pipeline-ui \
    "ml-pipeline-ui=ghcr.io/kubeflow/kfp-frontend:${ver}" -n "$ns" || return 1
  kubectl set image deployment/ml-pipeline \
    "ml-pipeline-api-server=ghcr.io/kubeflow/kfp-api-server:${ver}" -n "$ns" || return 1
  kubectl set image deployment/ml-pipeline-visualizationserver \
    "ml-pipeline-visualizationserver=ghcr.io/kubeflow/kfp-visualization-server:${ver}" -n "$ns" || return 1
  kubectl set env deployment/ml-pipeline \
    "V2_LAUNCHER_IMAGE=ghcr.io/kubeflow/kfp-launcher:${ver}" -n "$ns" || return 1
  kubectl patch deployment workflow-controller -n "$ns" --type=json \
    -p="[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/args/3\",\"value\":\"${FED_ARGOEXEC_IMAGE}\"}]" || return 1
}

# Patches KFP's own bundled MinIO (namespace kubeflow), which is separate from
# the standalone MinIO in minio.sh. Uses 'replace' on the whole ports array so
# repeated runs cannot append duplicate container ports.
fed_kfp_patch_minio() {
  local ns=$FED_KFP_NAMESPACE
  fed_log "patching KFP MinIO image and console port"
  kubectl set image deployment/minio minio=minio/minio:latest -n "$ns" || return 1
  kubectl patch deployment minio -n "$ns" --type=json \
    -p='[{"op":"replace","path":"/spec/template/spec/containers/0/ports","value":[{"containerPort":9000},{"containerPort":9001}]}]' || return 1
  kubectl patch deployment minio -n "$ns" --type=json \
    -p='[{"op":"replace","path":"/spec/template/spec/containers/0/args","value":["server","/data","--console-address",":9001"]}]' || return 1
}

fed_kfp_wait() {
  local ns=$FED_KFP_NAMESPACE d
  fed_log "waiting for KFP core deployments"
  for d in workflow-controller minio ml-pipeline ml-pipeline-ui; do
    kubectl rollout status "deployment/$d" -n "$ns" --timeout=15m || return 1
  done
}
