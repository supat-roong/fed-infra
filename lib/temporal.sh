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

  # fed_up dispatches components in a fixed order (kfp -> training ->
  # temporal -> minio -> mlflow) and temporal deliberately runs before minio,
  # but the namespace itself is only otherwise created by fed_minio_install /
  # fed_mlflow_install applying namespace.yaml.tpl. On a clean cluster that
  # means our own postgres manifest below would target a namespace that does
  # not exist yet. Apply it here too, exactly like fed_minio_install /
  # fed_mlflow_install already do, so this component is self-sufficient
  # regardless of dispatch order.
  fed_apply "${FED_INFRA_ROOT}/manifests/namespace.yaml.tpl" namespace

  # The chart has NO postgresql dependency (only cassandra/prometheus/
  # elasticsearch/grafana), so we supply our own database first. fed_apply
  # handles FED_DRY_RUN itself (writing the manifest under FED_RENDER_DIR
  # instead of calling kubectl), so this call runs unconditionally -- matching
  # fed_minio_install / fed_mlflow_install, which always render their
  # manifests before gating the rollout wait on dry-run. Dry-run means
  # "render every manifest, perform no action", not "render nothing".
  fed_log "deploying PostgreSQL for Temporal into ${ns}"
  fed_apply "${FED_INFRA_ROOT}/manifests/temporal-postgres.yaml.tpl" temporal-postgres

  if [ "${FED_DRY_RUN:-0}" = "1" ]; then
    fed_log "dry-run: would install Temporal ${ver} into ${ns}"
    return 0
  fi

  kubectl rollout status statefulset/temporal-postgresql -n "$ns" --timeout=300s || return 1

  fed_require_cmd helm

  fed_log "adding the Temporal Helm repo"
  helm repo add temporal https://go.temporal.io/helm-charts || return 1
  helm repo update >/dev/null 2>&1 || return 1

  # fed-infra-up must stay safely re-runnable, and `helm upgrade` is not: on a
  # second run helm's server-side apply collides with the NodePort patch
  # fed_expose_nodeport applies to temporal-web, reporting a field-manager
  # conflict with "kubectl-patch" over .spec.type and
  # .spec.ports[].targetPort, and aborts the entire bootstrap even though
  # Temporal itself is perfectly healthy. Skip the chart when the release is
  # already there, matching what kfp, training and karmada each already do.
  # The consequence is that changing FED_TEMPORAL_VERSION against a cluster
  # that already has Temporal is a no-op: uninstall the release (or the
  # cluster) to move versions, same as the other components.
  if helm status temporal -n "$ns" >/dev/null 2>&1; then
    fed_log "Temporal already installed"
    fed_log "waiting for the Temporal frontend"
    kubectl rollout status deployment/temporal-frontend -n "$ns" --timeout=600s || return 1
    return 0
  fi

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

# Juju-mode counterpart: Charmed Temporal (temporal-k8s family) backed by
# postgresql-k8s. The server needs postgresql related twice — default (db)
# store and visibility store — and the admin charm initializes both schemas.
# Channels are 1.23/stable: the temporal charms publish NO latest track
# (spike findings §4).
fed_temporal_install_juju() {
  local model=$1
  fed_juju_deploy "$model" temporal-k8s temporal-k8s "$FED_TEMPORAL_CHANNEL"
  # num-history-shards has NO charm default (`juju config temporal-k8s` reports
  # it as an int whose default is null), and the charm refuses to start without
  # it, sitting blocked on:
  #   value of 'num-history-shards' config must be set to a positive power of 2
  #   (e.g. 1, 2, 4)
  # The arm64 spike never saw this because the workload container never
  # started, so §4's charm table recorded no config requirement. Set before any
  # relation so the charm's first config-changed already has it. Temporal
  # cannot change this value after the schema is initialized -- it decides the
  # history-shard count for the life of the deployment -- hence a variable
  # rather than a literal, so a consumer sizing a real cluster can raise it at
  # install time instead of patching this library.
  fed_juju_config "$model" temporal-k8s \
    "num-history-shards=${FED_TEMPORAL_NUM_HISTORY_SHARDS}"
  fed_juju_deploy "$model" temporal-admin-k8s temporal-admin-k8s "$FED_TEMPORAL_ADMIN_CHANNEL"
  fed_juju_deploy "$model" temporal-ui-k8s temporal-ui-k8s "$FED_TEMPORAL_UI_CHANNEL"
  fed_juju_deploy "$model" temporal-postgresql postgresql-k8s "$FED_POSTGRESQL_CHANNEL" --trust
  fed_juju_integrate "$model" temporal-k8s:db temporal-postgresql:database
  fed_juju_integrate "$model" temporal-k8s:visibility temporal-postgresql:database
  fed_juju_integrate "$model" temporal-k8s:admin temporal-admin-k8s:admin
  fed_juju_integrate "$model" temporal-ui-k8s:ui temporal-k8s:ui
  fed_juju_wait_active "$model" temporal-k8s
  fed_juju_wait_active "$model" temporal-ui-k8s
  fed_temporal_register_namespace "$model" default
}

# Consumers' workers heartbeat against the 'default' Temporal namespace; the
# server does not create it. The admin charm's action is `cli` with a single
# `args` string (spike findings §7; the old tctl action does not exist).
# NOTE: the args payload below is the spike's best guess for the newer
# `temporal` CLI and is verified/corrected during the x86_64 e2e —
# registration of an existing namespace fails, so failure warns, not dies.
fed_temporal_register_namespace() {
  local model=$1 ns=$2
  if [ "${FED_DRY_RUN:-0}" = "1" ]; then
    fed_log "dry-run: would register temporal namespace '${ns}'"
    return 0
  fi
  fed_log "registering temporal namespace '${ns}'"
  fed_juju_action "$model" temporal-admin-k8s/0 cli \
    "args=operator namespace create --retention 3d ${ns}" \
    || fed_warn "temporal namespace '${ns}' registration reported failure (likely already registered)"
}
