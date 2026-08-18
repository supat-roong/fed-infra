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
  : "${FED_TEMPORAL_VERSION:=0.62.0}"
  : "${FED_TEMPORAL_NAMESPACE:=${FED_NAMESPACE:-}}"
  : "${FED_TEMPORAL_DB_NAME:=temporal}"
  : "${FED_TEMPORAL_DB_USER:=temporal}"
  : "${FED_TEMPORAL_DB_PASSWORD:=temporal}"
  : "${FED_NODEPORT_TEMPORAL_UI:=30733}"
  : "${FED_HOSTPORT_TEMPORAL_UI:=8233}"
  : "${FED_TRAINING_OPERATOR_VERSION:=v1.7.0}"
  : "${FED_KIND_WORKERS:=0}"
  : "${FED_MLFLOW_VERSION:=2.12.2}"
  : "${FED_MLFLOW_IMAGE:=fed-mlflow:${FED_MLFLOW_VERSION}}"
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
  : "${FED_MEMBER_COUNT:=2}"
  : "${FED_MEMBER_PREFIX:=member}"
  : "${FED_KARMADA_VERSION:=v1.17.0}"
  : "${FED_KARMADA_CONFIG:=${HOME}/.karmada/karmada-apiserver.config}"
  # karmadactl init's own --port default. kind/multi-host.yaml.tpl maps this
  # same value as a hostPort, so the apiserver is reachable at
  # https://127.0.0.1:${FED_KARMADA_APISERVER_PORT} from the host machine
  # that runs kubectl/karmadactl against $FED_KARMADA_CONFIG -- both driven
  # off this one variable so they cannot drift apart.
  : "${FED_KARMADA_APISERVER_PORT:=32443}"
  # NodePort the Karmada dashboard is expected to be exposed on. fed-infra
  # never installs the dashboard itself (that's left to the consumer), but
  # the port mapping must exist on the kind host node at cluster-creation
  # time -- a consumer cannot add one afterwards -- so it lives here.
  : "${FED_KARMADA_DASHBOARD_PORT:=32000}"
  # Ceiling for pod-readiness polling, in attempts x (wait + FED_RETRY_DELAY).
  # See fed_training_install for why the default is this generous.
  : "${FED_POD_READY_ATTEMPTS:=30}"
  : "${FED_RETRY_DELAY:=5}"
  export FED_KFP_VERSION FED_TEMPORAL_VERSION FED_TEMPORAL_NAMESPACE \
         FED_TEMPORAL_DB_NAME FED_TEMPORAL_DB_USER FED_TEMPORAL_DB_PASSWORD \
         FED_NODEPORT_TEMPORAL_UI FED_HOSTPORT_TEMPORAL_UI \
         FED_TRAINING_OPERATOR_VERSION FED_KIND_WORKERS \
         FED_MLFLOW_VERSION FED_MLFLOW_IMAGE \
         FED_IMAGES FED_S3_BUCKET FED_NODEPORT_KFP FED_NODEPORT_MLFLOW \
         FED_NODEPORT_MINIO_API FED_NODEPORT_MINIO_CONSOLE FED_HOSTPORT_KFP \
         FED_HOSTPORT_MLFLOW FED_HOSTPORT_MINIO_API FED_HOSTPORT_MINIO_CONSOLE \
         FED_DRY_RUN FED_RENDER_DIR \
         FED_MEMBER_COUNT FED_MEMBER_PREFIX FED_KARMADA_VERSION FED_KARMADA_CONFIG \
         FED_KARMADA_APISERVER_PORT FED_KARMADA_DASHBOARD_PORT \
         FED_POD_READY_ATTEMPTS FED_RETRY_DELAY
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
  # fed_up_multi installs the Karmada control plane off FED_PROFILE alone, so
  # listing `karmada` in FED_COMPONENTS changes nothing on its own. Rather than
  # leave a decorative entry that reads as if it gated something, require it:
  # a multi contract that omits it now fails fast instead of quietly getting
  # Karmada anyway. Gating the install on it instead would allow the worse
  # state -- member clusters created with no federation to bind them.
  if [ "$FED_PROFILE" = "multi" ] && ! fed_has_component karmada; then
    fed_die "FED_PROFILE=multi requires the karmada component in FED_COMPONENTS, got: $FED_COMPONENTS"
  fi
  if fed_has_component mlflow; then
    for v in FED_S3_ENDPOINT FED_S3_ACCESS_KEY FED_S3_SECRET_KEY; do
      eval "local value=\${$v:-}"
      # shellcheck disable=SC2154
      [ -n "$value" ] || fed_die "missing required variable: $v (required when the mlflow component is enabled)"
    done
  fi
}

fed_has_component() {
  case ",${FED_COMPONENTS}," in
    *",$1,"*) return 0 ;;
    *) return 1 ;;
  esac
}
