#!/usr/bin/env bash
# mlflow.sh — build the mlflow+boto3 image and deploy the tracking server.

fed_mlflow_build_image() {
  local image=$1 version=$2
  if [ "${FED_DRY_RUN:-0}" = "1" ]; then
    fed_log "dry-run: would build mlflow image ${image}"
    return 0
  fi
  if docker image inspect "$image" >/dev/null 2>&1; then
    fed_log "mlflow image $image already built"
    return 0
  fi
  fed_log "building mlflow image $image"
  local ctx
  ctx=$(mktemp -d)
  cat > "$ctx/Dockerfile" <<EOF
FROM ghcr.io/mlflow/mlflow:v${version}
RUN pip install --no-cache-dir boto3
EOF
  local rc=0
  docker build -t "$image" "$ctx" || rc=$?
  rm -rf "$ctx"
  return "$rc"
}

fed_mlflow_install() {
  fed_apply "${FED_INFRA_ROOT}/manifests/namespace.yaml.tpl" namespace
  fed_apply "${FED_INFRA_ROOT}/manifests/mlflow-server.yaml.tpl" mlflow-server
  if [ "${FED_DRY_RUN:-0}" = "1" ]; then return 0; fi
  fed_log "waiting for MLflow server"
  kubectl rollout status deployment/mlflow-server -n "$FED_NAMESPACE" --timeout=300s
}
