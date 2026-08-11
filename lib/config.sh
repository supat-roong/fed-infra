#!/usr/bin/env bash
# config.sh — load, default, and validate a consumer's infra.env.

FED_REQUIRED_VARS="FED_CLUSTER_NAME FED_NAMESPACE FED_PROFILE FED_COMPONENTS"

fed_config_load() {
  local env_file=$1
  [ -f "$env_file" ] || fed_die "infra.env not found: $env_file"
  set -a
  # shellcheck disable=SC1090
  . "$env_file"
  set +a
  fed_config_defaults
  fed_config_validate
}

fed_config_defaults() {
  : "${FED_KFP_VERSION:=2.4.0}"
  : "${FED_KIND_WORKERS:=0}"
  : "${FED_MLFLOW_VERSION:=2.12.2}"
  : "${FED_MLFLOW_IMAGE:=fl-mlflow:${FED_MLFLOW_VERSION}}"
  : "${FED_IMAGES:=}"
  : "${FED_S3_BUCKET:=mlflow-artifacts}"
  : "${FED_NODEPORT_KFP:=30080}"
  : "${FED_NODEPORT_MLFLOW:=30500}"
  : "${FED_NODEPORT_MINIO_API:=30900}"
  : "${FED_NODEPORT_MINIO_CONSOLE:=30901}"
  : "${FED_HOSTPORT_KFP:=8080}"
  : "${FED_HOSTPORT_MLFLOW:=5050}"
  : "${FED_HOSTPORT_MINIO_API:=9000}"
  : "${FED_HOSTPORT_MINIO_CONSOLE:=9001}"
  : "${FED_DRY_RUN:=0}"
  : "${FED_RENDER_DIR:=}"
  export FED_KFP_VERSION FED_KIND_WORKERS FED_MLFLOW_VERSION FED_MLFLOW_IMAGE \
         FED_IMAGES FED_S3_BUCKET FED_NODEPORT_KFP FED_NODEPORT_MLFLOW \
         FED_NODEPORT_MINIO_API FED_NODEPORT_MINIO_CONSOLE FED_HOSTPORT_KFP \
         FED_HOSTPORT_MLFLOW FED_HOSTPORT_MINIO_API FED_HOSTPORT_MINIO_CONSOLE \
         FED_DRY_RUN FED_RENDER_DIR
}

fed_config_validate() {
  local v
  for v in $FED_REQUIRED_VARS; do
    eval "local value=\${$v:-}"
    # shellcheck disable=SC2154
    [ -n "$value" ] || fed_die "missing required variable: $v"
  done
  case "$FED_PROFILE" in
    single|multi) ;;
    *) fed_die "FED_PROFILE must be 'single' or 'multi', got: $FED_PROFILE" ;;
  esac
}

fed_has_component() {
  case ",${FED_COMPONENTS}," in
    *",$1,"*) return 0 ;;
    *) return 1 ;;
  esac
}
