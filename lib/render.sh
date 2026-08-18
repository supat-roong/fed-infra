#!/usr/bin/env bash
# render.sh — envsubst-based manifest rendering with a dry-run mode.

# Explicit substitution list. envsubst with no args would replace every $NAME
# in the template, including shell variables inside container commands.
# shellcheck disable=SC2016
FED_TEMPLATE_VARS='${FED_CLUSTER_NAME} ${FED_NAMESPACE} ${FED_KIND_WORKERS}
${FED_S3_ENDPOINT} ${FED_S3_ACCESS_KEY} ${FED_S3_SECRET_KEY} ${FED_S3_BUCKET}
${FED_MLFLOW_IMAGE} ${FED_MLFLOW_VERSION}
${FED_NODEPORT_KFP} ${FED_NODEPORT_MLFLOW} ${FED_NODEPORT_MINIO_API} ${FED_NODEPORT_MINIO_CONSOLE}
${FED_HOSTPORT_KFP} ${FED_HOSTPORT_MLFLOW} ${FED_HOSTPORT_MINIO_API} ${FED_HOSTPORT_MINIO_CONSOLE}
${FED_NODEPORT_TEMPORAL_UI} ${FED_HOSTPORT_TEMPORAL_UI}
${FED_TEMPORAL_NAMESPACE} ${FED_TEMPORAL_DB_NAME} ${FED_TEMPORAL_DB_USER} ${FED_TEMPORAL_DB_PASSWORD}
${FED_MEMBER_COUNT} ${FED_MEMBER_PREFIX}
${FED_KARMADA_APISERVER_PORT}
${FED_NODEPORT_K8S_DASHBOARD} ${FED_HOSTPORT_K8S_DASHBOARD}
${FED_NODEPORT_KARMADA_DASHBOARD} ${FED_HOSTPORT_KARMADA_DASHBOARD}'

fed_render() {
  local tpl=$1
  [ -f "$tpl" ] || fed_die "template not found: $tpl"
  envsubst "$FED_TEMPLATE_VARS" < "$tpl"
}

fed_apply() {
  local tpl=$1 label=$2
  if [ "${FED_DRY_RUN:-0}" = "1" ]; then
    [ -n "${FED_RENDER_DIR:-}" ] || fed_die "FED_DRY_RUN=1 requires FED_RENDER_DIR to be set"
    mkdir -p "$FED_RENDER_DIR"
    fed_render "$tpl" > "$FED_RENDER_DIR/${label}.yaml"
    fed_log "dry-run: rendered ${label} -> ${FED_RENDER_DIR}/${label}.yaml"
  else
    fed_render "$tpl" | kubectl apply -f -
  fi
}
