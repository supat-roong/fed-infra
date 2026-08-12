#!/usr/bin/env bash
# temporal.sh — Temporal server + PostgreSQL via the official Helm chart.
#
# The chart bundles Elasticsearch, Prometheus and Grafana by default. All three
# are disabled here: this is a local single-node kind cluster, and Elasticsearch
# alone would roughly double the memory footprint. Visibility falls back to the
# PostgreSQL store, which is sufficient for workflow listing and history.

fed_temporal_install() {
  local ns=$1 ver=$2
  if [ "${FED_DRY_RUN:-0}" = "1" ]; then
    fed_log "dry-run: would install Temporal ${ver} into ${ns}"
    return 0
  fi
  fed_require_cmd helm

  fed_log "adding the Temporal Helm repo"
  helm repo add temporal https://go.temporal.io/helm-charts || return 1
  helm repo update >/dev/null 2>&1 || return 1

  fed_log "installing Temporal ${ver} into ${ns}"
  helm upgrade --install temporal temporal/temporal \
    --namespace "$ns" --create-namespace \
    --version "$ver" \
    --set server.replicaCount=1 \
    --set cassandra.enabled=false \
    --set postgresql.enabled=true \
    --set server.config.persistence.default.driver=sql \
    --set elasticsearch.enabled=false \
    --set prometheus.enabled=false \
    --set grafana.enabled=false \
    --wait --timeout 15m || return 1

  fed_log "waiting for the Temporal frontend"
  kubectl rollout status deployment/temporal-frontend -n "$ns" --timeout=600s || return 1
}
