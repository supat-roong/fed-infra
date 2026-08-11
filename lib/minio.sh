#!/usr/bin/env bash
# minio.sh — standalone MinIO StatefulSet and bucket provisioning.
# KFP's own bundled MinIO is handled in kfp.sh, not here.

# Note: use `if ...; then return 0; fi`, never `[ ... ] && return 0`. Under
# `set -e` the latter aborts the whole script whenever the test is false,
# because the && compound itself evaluates to a non-zero status.
fed_minio_install() {
  fed_apply "${FED_INFRA_ROOT}/manifests/namespace.yaml.tpl" namespace
  fed_apply "${FED_INFRA_ROOT}/manifests/minio.yaml.tpl" minio
  if [ "${FED_DRY_RUN:-0}" = "1" ]; then return 0; fi
  fed_log "waiting for MinIO statefulset"
  kubectl rollout status statefulset/minio -n "$FED_NAMESPACE" --timeout=180s
}

fed_minio_ensure_bucket() {
  local ns=$1 endpoint=$2 access=$3 secret=$4 bucket=$5
  if [ "${FED_DRY_RUN:-0}" = "1" ]; then
    fed_log "dry-run: would ensure bucket '${bucket}' at ${endpoint}"
    return 0
  fi
  local pod
  pod="fl-mc-$(printf '%s' "$bucket" | tr -cd 'a-z0-9')"
  fed_log "ensuring bucket '${bucket}' at ${endpoint}"
  kubectl delete pod "$pod" -n "$ns" --ignore-not-found >/dev/null 2>&1 || true
  kubectl run "$pod" --image=minio/mc:latest -n "$ns" --restart=Never --command -- \
    sh -c "mc alias set t http://${endpoint} ${access} ${secret} && mc mb t/${bucket} --ignore-existing"
  kubectl wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$pod" -n "$ns" --timeout=120s \
    || fed_warn "bucket pod for '${bucket}' did not report Succeeded; continuing"
  kubectl delete pod "$pod" -n "$ns" --ignore-not-found >/dev/null 2>&1 || true
}
