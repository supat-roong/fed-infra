#!/usr/bin/env bash
# kfp.sh — Kubeflow Pipelines install, ARM/kind stability patches, readiness.
# The patches exist because the upstream images published to gcr.io are either
# amd64-only or no longer served; ghcr.io hosts working multi-arch equivalents.
#
# In manifests mode this kustomize path runs everywhere (it is also the only
# kfp on arm64: the kfp charm family is amd64-only on every Charmhub channel,
# spike findings §9). In juju mode, fed_kfp_install_juju below deploys the
# charm family instead — juju mode itself is already arch-gated to amd64
# daemons, so the charms' arch restriction costs nothing there.

FED_KFP_NAMESPACE=kubeflow
FED_ARGOEXEC_IMAGE="quay.io/argoproj/argoexec:v3.4.17"

fed_kfp_install() {
  local ver=$1
  if [ "${FED_DRY_RUN:-0}" = "1" ]; then
    fed_log "dry-run: would install KFP ${ver}"
    return 0
  fi
  if kubectl get deploy -n "$FED_KFP_NAMESPACE" ml-pipeline >/dev/null 2>&1; then
    fed_log "KFP already installed"
    return 0
  fi
  # kustomize enforces a hardcoded ~27s timeout on the git fetch it performs
  # internally for a remote -k target. On a slow connection cloning the KFP
  # repo alone can take 40s+, so `kubectl apply -k <git-url>` can never
  # succeed there no matter how many times it is retried. Plain `git clone`
  # has no such cap, so clone once ourselves and apply from the checkout.
  local tmp rc=0
  tmp=$(mktemp -d) || return 1
  fed_log "cloning KFP ${ver} manifests"
  if ! git clone --depth 1 --branch "$ver" https://github.com/kubeflow/pipelines "$tmp"; then
    rm -rf "$tmp"
    return 1
  fi
  fed_log "installing KFP ${ver} cluster-scoped resources"
  kubectl apply -k "$tmp/manifests/kustomize/cluster-scoped-resources" || rc=$?
  if [ "$rc" -eq 0 ]; then
    kubectl wait --for condition=established --timeout=300s crd/applications.app.k8s.io || rc=$?
  fi
  if [ "$rc" -eq 0 ]; then
    fed_log "installing KFP ${ver} core"
    kubectl apply -k "$tmp/manifests/kustomize/env/platform-agnostic" || rc=$?
  fi
  rm -rf "$tmp"
  return "$rc"
}

fed_kfp_patch_arm() {
  local ver=$1 ns=$FED_KFP_NAMESPACE
  if [ "${FED_DRY_RUN:-0}" = "1" ]; then
    fed_log "dry-run: would patch KFP images for ARM/kind stability"
    return 0
  fi
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
  if [ "${FED_DRY_RUN:-0}" = "1" ]; then
    fed_log "dry-run: would patch KFP MinIO image and console port"
    return 0
  fi
  fed_log "patching KFP MinIO image and console port"
  kubectl set image deployment/minio minio=minio/minio:latest -n "$ns" || return 1
  kubectl patch deployment minio -n "$ns" --type=json \
    -p='[{"op":"replace","path":"/spec/template/spec/containers/0/ports","value":[{"containerPort":9000},{"containerPort":9001}]}]' || return 1
  kubectl patch deployment minio -n "$ns" --type=json \
    -p='[{"op":"replace","path":"/spec/template/spec/containers/0/args","value":["server","/data","--console-address",":9001"]}]' || return 1
}

fed_kfp_wait() {
  local ns=$FED_KFP_NAMESPACE d
  if [ "${FED_DRY_RUN:-0}" = "1" ]; then
    fed_log "dry-run: would wait for KFP core deployments"
    return 0
  fi
  fed_log "waiting for KFP core deployments"
  for d in workflow-controller minio ml-pipeline ml-pipeline-ui; do
    kubectl rollout status "deployment/$d" -n "$ns" --timeout=15m || return 1
  done
}

# Juju-mode counterpart: the standalone Kubeflow Pipelines charm family in
# the kubeflow model. App set and relation topology follow the upstream
# kubeflow-pipelines bundle plus the KFP-2.x metadata plumbing
# (mlmd + envoy + kfp-metadata-writer); kfp-profile-controller and
# metacontroller are deliberately absent — they serve multi-user Kubeflow
# profiles, which this standalone deployment has no use for. kfp-minio is
# kfp's own object store (mirroring upstream's bundled MinIO) and keeps the
# same fixed minio/minio123 credentials the manifests path already uses for
# the mlpipeline bucket step.
fed_kfp_install_juju() {
  local model=${FED_KFP_NAMESPACE:-kubeflow}
  fed_juju_deploy "$model" kfp-db mysql-k8s "$FED_MYSQL_CHANNEL" --trust \
    --config "profile=${FED_MYSQL_PROFILE}"
  fed_juju_deploy "$model" kfp-minio minio "$FED_MINIO_CHANNEL"
  fed_juju_config "$model" kfp-minio access-key=minio secret-key=minio123
  fed_juju_deploy "$model" kfp-api kfp-api "$FED_KFP_CHANNEL" --trust
  fed_juju_deploy "$model" kfp-persistence kfp-persistence "$FED_KFP_CHANNEL" --trust
  fed_juju_deploy "$model" kfp-schedwf kfp-schedwf "$FED_KFP_CHANNEL" --trust
  fed_juju_deploy "$model" kfp-viewer kfp-viewer "$FED_KFP_CHANNEL" --trust
  fed_juju_deploy "$model" kfp-viz kfp-viz "$FED_KFP_CHANNEL"
  fed_juju_deploy "$model" kfp-ui kfp-ui "$FED_KFP_CHANNEL"
  fed_juju_deploy "$model" kfp-metadata-writer kfp-metadata-writer "$FED_KFP_CHANNEL"
  fed_juju_deploy "$model" mlmd mlmd "$FED_MLMD_CHANNEL" --trust
  fed_juju_deploy "$model" envoy envoy "$FED_ENVOY_CHANNEL"
  fed_juju_deploy "$model" argo-controller argo-controller "$FED_ARGO_CHANNEL" --trust
  fed_juju_integrate "$model" kfp-api:relational-db kfp-db:database
  fed_juju_integrate "$model" kfp-api:object-storage kfp-minio:object-storage
  fed_juju_integrate "$model" kfp-api:kfp-viz kfp-viz:kfp-viz
  fed_juju_integrate "$model" kfp-persistence:kfp-api kfp-api:kfp-api
  fed_juju_integrate "$model" kfp-ui:kfp-api kfp-api:kfp-api
  fed_juju_integrate "$model" kfp-ui:object-storage kfp-minio:object-storage
  fed_juju_integrate "$model" argo-controller:object-storage kfp-minio:object-storage
  fed_juju_integrate "$model" kfp-metadata-writer:grpc mlmd:grpc
  fed_juju_integrate "$model" envoy:grpc mlmd:grpc
  fed_juju_wait_active "$model" kfp-api
  fed_juju_wait_active "$model" kfp-ui
}
