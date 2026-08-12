#!/usr/bin/env bats
load helper

setup() {
  setup_stubs
  source "$FED_INFRA_ROOT/lib/common.sh"
  source "$FED_INFRA_ROOT/lib/config.sh"
  source "$FED_INFRA_ROOT/lib/render.sh"
  source "$FED_INFRA_ROOT/lib/temporal.sh"
  fed_config_defaults
  export FED_NAMESPACE=demo-ns
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
  export STUB_HELM_FAIL_GLOB="upgrade --install*"
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
  [[ "$output" == *"namespace: demo-ns"* ]]
  [[ "$output" == *'value: "pguser"'* ]]
  [[ "$output" == *'value: "pgpass"'* ]]
  [[ "$output" == *'value: "pgdb"'* ]]
  # Guards the FED_TEMPLATE_VARS whitelist directly: a variable missing from
  # it is never substituted, so a leftover ${FED_TEMPORAL...} marker here
  # means the whitelist is out of sync with the template.
  [[ "$output" != *'${FED_TEMPORAL'* ]]
}
