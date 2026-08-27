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

# Juju-mode counterpart: mlflow-server charm backed by mysql-k8s (metadata,
# mysql_client interface — the charm's legacy `mysql` endpoint does NOT
# match mlflow-server, see spike findings §5) and the minio charm
# (artifacts, via the object-storage relation).
fed_mlflow_install_juju() {
  if ! fed_has_component minio; then
    fed_die "FED_DEPLOY_MODE=juju requires the minio component when mlflow is enabled (mlflow-server's artifact store is the minio charm), got: $FED_COMPONENTS"
  fi
  fed_juju_deploy "$FED_NAMESPACE" mlflow-mysql mysql-k8s "$FED_MYSQL_CHANNEL" --trust
  fed_juju_deploy "$FED_NAMESPACE" mlflow-server mlflow-server "$FED_MLFLOW_CHANNEL"
  fed_juju_integrate "$FED_NAMESPACE" mlflow-server:relational-db mlflow-mysql:database
  fed_juju_integrate "$FED_NAMESPACE" mlflow-server:object-storage minio:object-storage
  fed_juju_wait_active "$FED_NAMESPACE" mlflow-mysql
  fed_juju_wait_active "$FED_NAMESPACE" mlflow-server
}
