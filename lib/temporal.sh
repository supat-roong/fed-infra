#!/usr/bin/env bash
# temporal.sh — Temporal server + PostgreSQL via the official Helm chart.
#
# The chart bundles Elasticsearch, Prometheus and Grafana by default. All three
# are disabled here: this is a local single-node kind cluster, and Elasticsearch
# alone would roughly double the memory footprint.
#
# Two chart facts, both established by running `helm template` against 0.62.0:
#   1. There is NO postgresql subchart. `postgresql.enabled=true` is a phantom
#      value that silently does nothing. We deploy our own database.
#   2. Visibility has its own persistence store. Switching only `default` to sql
#      leaves visibility on cassandra and the chart aborts with
#      "Please specify cassandra port for visibility store".

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

  # The chart has NO postgresql dependency (only cassandra/prometheus/
  # elasticsearch/grafana), so we supply our own database first.
  fed_log "deploying PostgreSQL for Temporal into ${ns}"
  fed_apply "${FED_INFRA_ROOT}/manifests/temporal-postgres.yaml.tpl" temporal-postgres
  kubectl rollout status statefulset/temporal-postgresql -n "$ns" --timeout=300s || return 1

  # BOTH the default and visibility stores must be switched to sql. Overriding
  # only `default` leaves visibility on its cassandra default and the chart
  # aborts with "Please specify cassandra port for visibility store".
  fed_log "installing Temporal ${ver} into ${ns}"
  helm upgrade --install temporal temporal/temporal \
    --namespace "$ns" --create-namespace \
    --version "$ver" \
    --set server.replicaCount=1 \
    --set cassandra.enabled=false \
    --set elasticsearch.enabled=false \
    --set prometheus.enabled=false \
    --set grafana.enabled=false \
    --set server.config.persistence.default.driver=sql \
    --set server.config.persistence.default.sql.driver=postgres12 \
    --set server.config.persistence.default.sql.host=temporal-postgresql \
    --set server.config.persistence.default.sql.port=5432 \
    --set server.config.persistence.default.sql.database="${FED_TEMPORAL_DB_NAME}" \
    --set server.config.persistence.default.sql.user="${FED_TEMPORAL_DB_USER}" \
    --set server.config.persistence.default.sql.password="${FED_TEMPORAL_DB_PASSWORD}" \
    --set server.config.persistence.visibility.driver=sql \
    --set server.config.persistence.visibility.sql.driver=postgres12 \
    --set server.config.persistence.visibility.sql.host=temporal-postgresql \
    --set server.config.persistence.visibility.sql.port=5432 \
    --set server.config.persistence.visibility.sql.database="${FED_TEMPORAL_DB_NAME}_visibility" \
    --set server.config.persistence.visibility.sql.user="${FED_TEMPORAL_DB_USER}" \
    --set server.config.persistence.visibility.sql.password="${FED_TEMPORAL_DB_PASSWORD}" \
    --wait --timeout 15m || return 1

  fed_log "waiting for the Temporal frontend"
  kubectl rollout status deployment/temporal-frontend -n "$ns" --timeout=600s || return 1
}
