#!/usr/bin/env bats
load helper

setup() {
  setup_stubs
  source "$FED_INFRA_ROOT/lib/common.sh"
  source "$FED_INFRA_ROOT/lib/config.sh"
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

@test "fed_temporal_install does nothing at all under FED_DRY_RUN=1" {
  export FED_DRY_RUN=1
  fed_temporal_install demo-ns 0.62.0
  refute_called "helm"
  refute_called "kubectl"
}

@test "fed_temporal_install fails fast when the chart install fails" {
  export STUB_HELM_FAIL_GLOB="upgrade --install*"
  run fed_temporal_install demo-ns 0.62.0
  [ "$status" -ne 0 ]
  refute_called "rollout status"
}
