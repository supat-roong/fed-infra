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
  # temporal-host-info is a *required* endpoint on both temporal-admin-k8s and
  # temporal-ui-k8s (`juju info` lists it under `requires` for each), provided
  # by temporal-k8s. The spike could only flag this as UNVERIFIED because no
  # workload ever started; the x86_64 e2e confirmed temporal-ui-k8s sits
  #   blocked: temporal-host-info relation not established
  # indefinitely without it, even once temporal-k8s itself is active. The admin
  # charm reaches active without it (it gets its database info over the `admin`
  # relation) but needs the frontend address this relation carries to run the
  # `cli` action, i.e. to register the namespace below.
  fed_juju_integrate "$model" temporal-ui-k8s:temporal-host-info temporal-k8s:temporal-host-info
  fed_juju_integrate "$model" temporal-admin-k8s:temporal-host-info temporal-k8s:temporal-host-info
  fed_juju_wait_active "$model" temporal-k8s
  fed_juju_wait_active "$model" temporal-ui-k8s
  fed_temporal_register_namespace "$model" default
}

# Consumers' workers heartbeat against the 'default' Temporal namespace; the
# server does not create it. The admin charm's action is `cli` with a single
# `args` string (spike findings §7; the old tctl action does not exist).
#
# Payload verified live on the x86_64 e2e (rev 28): the spike's guess at the
# newer `temporal` CLI was right, and a first run prints
# "Namespace default successfully registered." Re-registering an existing
# namespace makes the ACTION fail with "Namespace already exists." — expected
# on every idempotent re-run, so this must never abort the bootstrap.
#
# `juju run` exits 0 even when the action it ran failed (also verified live),
# so a plain `|| fed_warn` is dead code and would let a real failure pass
# silently. Inspect the output instead: swallow the already-exists case, warn
# about anything else. Same shape as fed_juju_integrate's benign-failure
# detection, and for the same reason.
#
# Detection alone is not enough, though: on a cold bring-up the action fires
# at a workload container that may not exist yet ("cannot connect to
# container" was exactly the spike's failure), so the path waits for the admin
# unit first and then retries, rather than warning once and walking away.
fed_temporal_register_namespace() {
  local model=$1 ns=$2
  if [ "${FED_DRY_RUN:-0}" = "1" ]; then
    fed_log "dry-run: would register temporal namespace '${ns}'"
    return 0
  fi

  # The `cli` action runs INSIDE the admin charm's workload container, so
  # firing it before that unit is active fails for a reason that has nothing
  # to do with the namespace. Non-fatal on purpose: if the unit never reports
  # active the retry loop below is still a better answer than aborting, and it
  # keeps this whole function never-die. The two sibling waits in
  # fed_temporal_install_juju stay fatal because a dead server or UI really is
  # a failed bring-up; a missing namespace is recoverable by hand.
  fed_juju_wait_active "$model" temporal-admin-k8s \
    || fed_warn "temporal-admin-k8s did not report active; attempting namespace registration anyway"

  fed_log "registering temporal namespace '${ns}'"
  FED_TEMPORAL_REGISTER_OUT=""
  if fed_retry "$FED_POD_READY_ATTEMPTS" "$FED_RETRY_DELAY" \
       fed_temporal_register_attempt "$model" "$ns"; then
    return 0
  fi

  # Never die -- a consumer's workers can be pointed at a namespace registered
  # after the fact, so a failure here must not cost them the whole cluster.
  # But say exactly how to finish the job.
  fed_warn "temporal namespace '${ns}' registration did not succeed after ${FED_POD_READY_ATTEMPTS} attempts; continuing without it"
  fed_warn "last output: ${FED_TEMPORAL_REGISTER_OUT}"
  fed_warn "register it by hand with: juju run -m $(fed_juju_controller_name):${model} temporal-admin-k8s/0 cli args=\"$(fed_temporal_register_args "$ns")\""
  return 0
}

# The verified `args` payload for registering one namespace. Factored out so
# the failure path above can print the exact command an operator has to run --
# a warning that only says "it failed" is not actionable.
fed_temporal_register_args() {
  printf 'operator namespace create --retention 3d -n %s' "$1"
}

# One registration attempt, shaped for fed_retry: returns 0 once the namespace
# is registered (whether this call created it or an earlier run did) and
# non-zero for anything else, so a real failure is retried while success and
# the already-registered case stop the loop immediately.
#
# The output is published in a global rather than returned, because fed_retry
# invokes this in the current shell and cannot capture its stdout.
fed_temporal_register_attempt() {
  local model=$1 ns=$2
  FED_TEMPORAL_REGISTER_OUT=$(fed_juju_action "$model" temporal-admin-k8s/0 cli \
    "args=$(fed_temporal_register_args "$ns")" 2>&1) || true
  case "$FED_TEMPORAL_REGISTER_OUT" in
    *"already exists"*)
      fed_log "temporal namespace '${ns}' already registered"
      return 0 ;;
    *"successfully registered"*|*"command succeeded"*)
      fed_log "temporal namespace '${ns}' registered"
      return 0 ;;
    *)
      return 1 ;;
  esac
}
