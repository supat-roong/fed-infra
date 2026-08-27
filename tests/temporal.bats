#!/usr/bin/env bats
load helper

setup() {
  setup_stubs
  source "$FED_INFRA_ROOT/lib/common.sh"
  source "$FED_INFRA_ROOT/lib/config.sh"
  source "$FED_INFRA_ROOT/lib/render.sh"
  source "$FED_INFRA_ROOT/lib/juju.sh"
  source "$FED_INFRA_ROOT/lib/temporal.sh"
  # Set BEFORE fed_config_defaults (which uses `:=`) so the retry-driven paths
  # -- fed_juju_wait_active and namespace registration -- resolve in one pass
  # instead of sleeping FED_RETRY_DELAY between 30 attempts. Tests that care
  # about retry counts override these locally.
  export FED_POD_READY_ATTEMPTS=1 FED_RETRY_DELAY=0
  fed_config_defaults
  export FED_NAMESPACE=demo-ns
  export FED_CLUSTER_NAME=demo FED_COMPONENTS=temporal
  # Default precondition: no Temporal release yet, i.e. a clean cluster, which
  # is what every install-path test below assumes. `helm status` succeeding is
  # the "already installed" case and is opted into explicitly by the tests
  # that exercise the skip path.
  export STUB_HELM_FAIL_GLOB="status temporal*"
}

@test "fed_temporal_install adds the repo and installs the chart" {
  fed_temporal_install demo-ns 0.62.0
  assert_called "helm repo add temporal"
  assert_called "helm upgrade --install temporal"
  assert_called "--namespace demo-ns"
}

@test "fed_temporal_install pins the requested chart version" {
  fed_temporal_install demo-ns 0.62.0
  assert_called "--version 0.62.0"
}

@test "fed_temporal_install disables the bundled elasticsearch and extra services" {
  fed_temporal_install demo-ns 0.62.0
  assert_called "elasticsearch.enabled=false"
  assert_called "prometheus.enabled=false"
  assert_called "grafana.enabled=false"
}

@test "fed_temporal_install waits for the frontend to roll out" {
  fed_temporal_install demo-ns 0.62.0
  assert_called "rollout status deployment/temporal-frontend -n demo-ns"
}

@test "fed_temporal_install renders the namespace and postgres manifests but calls no helm or kubectl under FED_DRY_RUN=1" {
  export FED_DRY_RUN=1 FED_RENDER_DIR="$BATS_TEST_TMPDIR/out"
  fed_temporal_install demo-ns 0.62.0
  [ -f "$FED_RENDER_DIR/namespace.yaml" ]
  [ -f "$FED_RENDER_DIR/temporal-postgres.yaml" ]
  refute_called "helm"
  refute_called "kubectl"
}

@test "fed_temporal_install creates its own namespace before deploying postgres" {
  fed_temporal_install demo-ns 0.62.0
  run bash -c "grep -c 'kubectl apply -f -' '$STUB_LOG'"
  [ "$output" -ge 2 ]
  local namespace_line postgres_line
  namespace_line=$(grep -n "^kind: Namespace$" "$STUB_STDIN_LOG" | head -n1 | cut -d: -f1)
  postgres_line=$(grep -n "^kind: StatefulSet$" "$STUB_STDIN_LOG" | head -n1 | cut -d: -f1)
  [ -n "$namespace_line" ]
  [ -n "$postgres_line" ]
  [ "$namespace_line" -lt "$postgres_line" ]
}

@test "fed_temporal_install fails fast when the chart install fails" {
  # Two globs, not one alternation: `|` from a variable expansion is literal
  # in a case pattern. The setup() default (status fails => not installed)
  # must stay in force, or the skip path is taken and the frontend wait below
  # legitimately runs.
  export STUB_HELM_FAIL_GLOB2="upgrade --install*"
  run fed_temporal_install demo-ns 0.62.0
  [ "$status" -ne 0 ]
  # Not a bare "rollout status": the postgres statefulset wait runs (and must
  # succeed) before the chart install is even attempted, so it legitimately
  # appears in the log. Only the frontend wait must never be reached.
  refute_called "rollout status deployment/temporal-frontend"
}

@test "fed_temporal_install deploys postgres and waits for it before installing the chart" {
  fed_temporal_install demo-ns 0.62.0
  assert_called "kubectl apply -f -"
  assert_called "rollout status statefulset/temporal-postgresql -n demo-ns"
  local postgres_line chart_line
  postgres_line=$(grep -n "rollout status statefulset/temporal-postgresql" "$STUB_LOG" | head -n1 | cut -d: -f1)
  chart_line=$(grep -n "helm upgrade --install temporal" "$STUB_LOG" | head -n1 | cut -d: -f1)
  [ "$postgres_line" -lt "$chart_line" ]
}

@test "fed_temporal_install switches both the default and visibility persistence stores to sql" {
  fed_temporal_install demo-ns 0.62.0
  assert_called "server.config.persistence.default.driver=sql"
  assert_called "server.config.persistence.default.sql.driver=postgres12"
  assert_called "server.config.persistence.default.sql.host=temporal-postgresql"
  assert_called "server.config.persistence.visibility.driver=sql"
  assert_called "server.config.persistence.visibility.sql.driver=postgres12"
  assert_called "server.config.persistence.visibility.sql.host=temporal-postgresql"
}

@test "fed_temporal_install never sets the phantom postgresql.enabled flag" {
  fed_temporal_install demo-ns 0.62.0
  refute_called "postgresql.enabled"
}

@test "temporal-postgres template renders a non-empty namespace and the configured credentials" {
  export FED_TEMPORAL_NAMESPACE=demo-ns
  export FED_TEMPORAL_DB_USER=pguser FED_TEMPORAL_DB_PASSWORD=pgpass FED_TEMPORAL_DB_NAME=pgdb
  run fed_render "$FED_INFRA_ROOT/manifests/temporal-postgres.yaml.tpl"
  [[ "$output" == *"namespace: demo-ns"* ]] || return 1
  [[ "$output" == *'value: "pguser"'* ]] || return 1
  [[ "$output" == *'value: "pgpass"'* ]] || return 1
  [[ "$output" == *'value: "pgdb"'* ]] || return 1
  # Guards the FED_TEMPLATE_VARS whitelist directly: a variable missing from
  # it is never substituted, so a leftover ${FED_TEMPORAL...} marker here
  # means the whitelist is out of sync with the template.
  [[ "$output" != *'${FED_TEMPORAL'* ]] || return 1
}

@test "fed_temporal_install skips the chart upgrade when the release is already deployed" {
  # fed-infra-up is meant to be safely re-runnable, but `helm upgrade` on a
  # second run collides with the NodePort patch fed_expose_nodeport applies
  # to temporal-web: helm's server-side apply reports a field-manager
  # conflict with "kubectl-patch" over .spec.type and .spec.ports[].targetPort
  # and aborts the whole bootstrap. Every other component (kfp, training,
  # karmada) checks for an existing install and returns early; this one did
  # not.
  unset STUB_HELM_FAIL_GLOB
  fed_temporal_install demo-ns 0.62.0
  refute_called "helm upgrade"
  assert_called "helm status temporal"
}

@test "fed_temporal_install still installs the chart when no release exists" {
  export STUB_HELM_FAIL_GLOB="status temporal*"
  fed_temporal_install demo-ns 0.62.0
  assert_called "helm upgrade --install temporal temporal/temporal"
}

@test "fed_temporal_install waits for the frontend even when it skips the upgrade" {
  unset STUB_HELM_FAIL_GLOB
  fed_temporal_install demo-ns 0.62.0
  refute_called "helm upgrade"
  assert_called "rollout status deployment/temporal-frontend"
}

@test "fed_temporal_install_juju deploys server, admin, ui, and postgresql charms" {
  export STUB_JUJU_FAIL_GLOB="show-application*"
  export STUB_JUJU_OUT='workload:active'
  fed_temporal_install_juju demo-ns
  assert_called "juju deploy -m fed-demo:demo-ns temporal-k8s temporal-k8s --channel ${FED_TEMPORAL_CHANNEL}"
  assert_called "juju deploy -m fed-demo:demo-ns temporal-admin-k8s temporal-admin-k8s --channel ${FED_TEMPORAL_ADMIN_CHANNEL}"
  assert_called "juju deploy -m fed-demo:demo-ns temporal-ui-k8s temporal-ui-k8s --channel ${FED_TEMPORAL_UI_CHANNEL}"
  assert_called "juju deploy -m fed-demo:demo-ns postgresql-k8s temporal-postgresql --channel ${FED_POSTGRESQL_CHANNEL} --trust"
}

@test "fed_temporal_install_juju sets the mandatory num-history-shards charm config" {
  # The charm has NO default for num-history-shards and sits blocked on
  # "value of 'num-history-shards' config must be set to a positive power of 2"
  # until it is set -- observed live on rev 68 during the x86_64 e2e.
  export STUB_JUJU_OUT='workload:active'
  fed_temporal_install_juju demo-ns
  assert_called "juju config -m fed-demo:demo-ns temporal-k8s num-history-shards=${FED_TEMPORAL_NUM_HISTORY_SHARDS}"
}

@test "fed_temporal_install_juju honors FED_TEMPORAL_NUM_HISTORY_SHARDS" {
  export STUB_JUJU_OUT='workload:active'
  export FED_TEMPORAL_NUM_HISTORY_SHARDS=512
  fed_temporal_install_juju demo-ns
  assert_called "temporal-k8s num-history-shards=512"
}

@test "fed_temporal_install_juju configures num-history-shards before wiring relations" {
  # Ordering matters: the charm's first config-changed must already see the
  # value, otherwise it blocks and the relation hooks run against a charm that
  # refuses to start.
  export STUB_JUJU_OUT='workload:active'
  fed_temporal_install_juju demo-ns
  local cfg_line rel_line
  cfg_line=$(grep -n "num-history-shards" "$STUB_LOG" | head -n1 | cut -d: -f1)
  rel_line=$(grep -n "integrate" "$STUB_LOG" | head -n1 | cut -d: -f1)
  [ -n "$cfg_line" ]
  [ -n "$rel_line" ]
  [ "$cfg_line" -lt "$rel_line" ]
}

@test "fed_temporal_install_juju integrates db, visibility, admin, and ui relations" {
  export STUB_JUJU_OUT='workload:active'
  fed_temporal_install_juju demo-ns
  assert_called "juju integrate -m fed-demo:demo-ns temporal-k8s:db temporal-postgresql:database"
  assert_called "juju integrate -m fed-demo:demo-ns temporal-k8s:visibility temporal-postgresql:database"
  assert_called "juju integrate -m fed-demo:demo-ns temporal-k8s:admin temporal-admin-k8s:admin"
  assert_called "juju integrate -m fed-demo:demo-ns temporal-ui-k8s:ui temporal-k8s:ui"
}

@test "fed_temporal_install_juju wires temporal-host-info for both the ui and admin charms" {
  # A required endpoint on both charms. Without it temporal-ui-k8s stays
  # blocked on "temporal-host-info relation not established" forever, even
  # after temporal-k8s reaches active (observed live on the x86_64 e2e).
  export STUB_JUJU_OUT='workload:active'
  fed_temporal_install_juju demo-ns
  assert_called "juju integrate -m fed-demo:demo-ns temporal-ui-k8s:temporal-host-info temporal-k8s:temporal-host-info"
  assert_called "juju integrate -m fed-demo:demo-ns temporal-admin-k8s:temporal-host-info temporal-k8s:temporal-host-info"
}

@test "fed_temporal_install_juju wires temporal-host-info before waiting for the ui charm" {
  export STUB_JUJU_OUT='workload:active'
  fed_temporal_install_juju demo-ns
  local rel_line wait_line
  rel_line=$(grep -n "temporal-ui-k8s:temporal-host-info" "$STUB_LOG" | head -n1 | cut -d: -f1)
  wait_line=$(grep -n "status -m fed-demo:demo-ns temporal-ui-k8s" "$STUB_LOG" | head -n1 | cut -d: -f1)
  [ -n "$rel_line" ]
  [ -n "$wait_line" ]
  [ "$rel_line" -lt "$wait_line" ]
}

@test "fed_temporal_install_juju registers the default namespace via the cli action" {
  export STUB_JUJU_OUT='workload:active'
  fed_temporal_install_juju demo-ns
  assert_called "juju run -m fed-demo:demo-ns temporal-admin-k8s/0 cli"
}

@test "fed_temporal_register_namespace warns but succeeds when the action fails" {
  export STUB_JUJU_FAIL_GLOB="run *"
  run fed_temporal_register_namespace demo-ns default
  [ "$status" -eq 0 ]
  [[ "$output" == *"registration"* ]]
}

@test "fed_temporal_register_namespace passes the namespace with -n, not positionally" {
  # The charm's bundled `temporal` CLI warns that a positional namespace is
  # deprecated ("please switch to using -n instead"); both forms were tried
  # live on the x86_64 e2e and -n is the accepted one.
  fed_temporal_register_namespace demo-ns default
  assert_called "args=operator namespace create --retention 3d -n default"
}

@test "fed_temporal_register_namespace treats an already-registered namespace as success" {
  # Every idempotent re-run hits this: the action fails with
  # "Namespace already exists." while `juju run` itself still exits 0.
  export STUB_JUJU_OUT='Action id 4 failed: command failed: unable to create namespace default: Namespace already exists.'
  run fed_temporal_register_namespace demo-ns default
  [ "$status" -eq 0 ]
  [[ "$output" == *"already registered"* ]] || return 1
  [[ "$output" != *"may have failed"* ]]
}

@test "fed_temporal_register_namespace reports success on a first registration" {
  export STUB_JUJU_OUT='output: Namespace default successfully registered.'
  run fed_temporal_register_namespace demo-ns default
  [ "$status" -eq 0 ]
  [[ "$output" != *"may have failed"* ]]
}

@test "fed_temporal_register_namespace waits for the admin unit before running the action" {
  # The `cli` action runs inside the admin charm's workload container, so a
  # cold bring-up must not fire it at a unit that has not started yet -- the
  # spike saw exactly that as "cannot connect to container".
  export STUB_JUJU_OUT='workload:active'
  fed_temporal_register_namespace demo-ns default
  local wait_line action_line
  wait_line=$(grep -n "status -m fed-demo:demo-ns temporal-admin-k8s" "$STUB_LOG" | head -n1 | cut -d: -f1)
  action_line=$(grep -n "run -m fed-demo:demo-ns temporal-admin-k8s/0 cli" "$STUB_LOG" | head -n1 | cut -d: -f1)
  [ -n "$wait_line" ]
  [ -n "$action_line" ]
  [ "$wait_line" -lt "$action_line" ]
}

@test "fed_temporal_register_namespace still attempts registration when the admin unit never activates" {
  # Non-fatal wait: retrying is a better answer than aborting the bootstrap.
  fed_temporal_register_namespace demo-ns default
  assert_called "run -m fed-demo:demo-ns temporal-admin-k8s/0 cli"
}

@test "fed_temporal_register_namespace retries a real failure up to FED_POD_READY_ATTEMPTS" {
  export FED_POD_READY_ATTEMPTS=3 FED_RETRY_DELAY=0
  export STUB_JUJU_OUT='Action id 9 failed: command failed: cannot connect to container'
  run fed_temporal_register_namespace demo-ns default
  [ "$status" -eq 0 ]
  # One `cli` invocation per attempt.
  local attempts
  attempts=$(grep -cF "temporal-admin-k8s/0 cli" "$STUB_LOG")
  [ "$attempts" -eq 3 ]
}

@test "fed_temporal_register_namespace warns actionably with the manual command on final failure" {
  export FED_POD_READY_ATTEMPTS=2 FED_RETRY_DELAY=0
  export STUB_JUJU_OUT='Action id 9 failed: command failed: cannot connect to container'
  run fed_temporal_register_namespace demo-ns default
  [ "$status" -eq 0 ]
  [[ "$output" == *"did not succeed after 2 attempts"* ]] || return 1
  # The warning must carry the exact recovery command, with the working
  # -n payload, not just "it failed".
  [[ "$output" == *"juju run -m fed-demo:demo-ns temporal-admin-k8s/0 cli"* ]] || return 1
  [[ "$output" == *"operator namespace create --retention 3d -n default"* ]]
}

@test "fed_temporal_register_namespace does not retry after a successful registration" {
  export FED_POD_READY_ATTEMPTS=5 FED_RETRY_DELAY=0
  export STUB_JUJU_OUT='output: Namespace default successfully registered.'
  fed_temporal_register_namespace demo-ns default
  local attempts
  attempts=$(grep -cF "temporal-admin-k8s/0 cli" "$STUB_LOG")
  [ "$attempts" -eq 1 ]
}

@test "fed_temporal_register_namespace does not retry when the namespace already exists" {
  export FED_POD_READY_ATTEMPTS=5 FED_RETRY_DELAY=0
  export STUB_JUJU_OUT='Action id 4 failed: command failed: unable to create namespace default: Namespace already exists.'
  fed_temporal_register_namespace demo-ns default
  local attempts
  attempts=$(grep -cF "temporal-admin-k8s/0 cli" "$STUB_LOG")
  [ "$attempts" -eq 1 ]
}

@test "fed_temporal_register_namespace warns on an unrecognised failure even though juju run exits 0" {
  # `juju run` exits 0 even when the action it ran failed, so a bare
  # `|| fed_warn` could never fire -- a real failure must still be surfaced.
  export STUB_JUJU_OUT='Action id 9 failed: command failed: connection refused'
  run fed_temporal_register_namespace demo-ns default
  [ "$status" -eq 0 ]
  [[ "$output" == *"did not succeed"* ]] || return 1
  # The real message is surfaced, not swallowed.
  [[ "$output" == *"connection refused"* ]]
}

@test "fed_temporal_install_juju performs no real side effects under FED_DRY_RUN=1" {
  export FED_DRY_RUN=1 FED_RENDER_DIR="$BATS_TEST_TMPDIR/out"
  fed_temporal_install_juju demo-ns
  [ -z "$(calls)" ]
  grep -q "temporal-k8s" "$FED_RENDER_DIR/juju-commands.txt"
}
