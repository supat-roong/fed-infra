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
  # Kubernetes Dashboard: manifest version, and the NodePort/hostPort pair
  # it's exposed on -- same NODEPORT_*/HOSTPORT_* shape as every other
  # component's Service (kfp, mlflow, minio, temporal), not the single
  # containerPort==hostPort variable Karmada's apiserver port uses (that one
  # is deliberately singular because it must equal karmadactl init's own
  # --port flag; a dashboard Service's NodePort has no such constraint).
  : "${FED_K8S_DASHBOARD_VERSION:=v2.7.0}"
  : "${FED_NODEPORT_K8S_DASHBOARD:=30443}"
  : "${FED_HOSTPORT_K8S_DASHBOARD:=8443}"
  # Karmada Dashboard NodePort/hostPort pair. Used both by
  # fed_karmada_dashboard_install's Service patch and by the kind host's
  # port mapping (a consumer cannot add the mapping after cluster creation,
  # so it must exist at kind-config-render time even though nothing in this
  # file runs until fed_up_install_components dispatches to it later).
  # Replaces the old single FED_KARMADA_DASHBOARD_PORT: that variable
  # predates this library installing the dashboard at all, and reusing one
  # variable for both the containerPort and the hostPort would let a
  # consumer change one without the other going out of sync -- exactly the
  # "decorative parameter" drift every other component's port pair avoids.
  : "${FED_NODEPORT_KARMADA_DASHBOARD:=32000}"
  : "${FED_HOSTPORT_KARMADA_DASHBOARD:=32000}"
  # Ceiling for pod-readiness polling, in attempts x (wait + FED_RETRY_DELAY).
  # See fed_training_install for why the default is this generous.
  : "${FED_POD_READY_ATTEMPTS:=30}"
  : "${FED_RETRY_DELAY:=5}"
  # Deploy mode: `auto` picks juju on an amd64 docker daemon and manifests
  # otherwise (see lib/juju.sh's fed_deploy_mode and the 2026-08-28 spike
  # findings for why the daemon's arch, not the host's, decides).
  : "${FED_DEPLOY_MODE:=auto}"
  # Charm channel for juju-mode minio (lib/minio.sh's fed_minio_install_juju).
  : "${FED_MINIO_CHANNEL:=ckf-1.9/stable}"
  # Charm channels for juju-mode mlflow (lib/mlflow.sh's
  # fed_mlflow_install_juju): mlflow-server and its mysql-k8s backing store.
  : "${FED_MLFLOW_CHANNEL:=2.15/stable}"
  : "${FED_MYSQL_CHANNEL:=8.0/stable}"
  # Charm channels for juju-mode temporal (lib/temporal.sh's
  # fed_temporal_install_juju): the temporal-k8s family publishes NO latest
  # track (spike findings §4), and its backing postgresql-k8s store.
  : "${FED_TEMPORAL_CHANNEL:=1.23/stable}"
  : "${FED_TEMPORAL_ADMIN_CHANNEL:=1.23/stable}"
  : "${FED_TEMPORAL_UI_CHANNEL:=1.23/stable}"
  : "${FED_POSTGRESQL_CHANNEL:=14/stable}"
  # Charm channel for juju-mode training (lib/training.sh's
  # fed_training_install_juju): the training-operator charm.
  : "${FED_TRAINING_CHANNEL:=1.8/stable}"
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
         FED_KARMADA_APISERVER_PORT \
         FED_K8S_DASHBOARD_VERSION FED_NODEPORT_K8S_DASHBOARD FED_HOSTPORT_K8S_DASHBOARD \
         FED_NODEPORT_KARMADA_DASHBOARD FED_HOSTPORT_KARMADA_DASHBOARD \
         FED_POD_READY_ATTEMPTS FED_RETRY_DELAY \
         FED_DEPLOY_MODE FED_MINIO_CHANNEL FED_MLFLOW_CHANNEL FED_MYSQL_CHANNEL \
         FED_TEMPORAL_CHANNEL FED_TEMPORAL_ADMIN_CHANNEL FED_TEMPORAL_UI_CHANNEL \
         FED_POSTGRESQL_CHANNEL FED_TRAINING_CHANNEL
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
  case "${FED_DEPLOY_MODE:-auto}" in
    auto|manifests|juju) ;;
    *) fed_die "FED_DEPLOY_MODE must be 'auto', 'manifests' or 'juju', got: $FED_DEPLOY_MODE" ;;
  esac
}

fed_has_component() {
  case ",${FED_COMPONENTS}," in
    *",$1,"*) return 0 ;;
    *) return 1 ;;
  esac
}
