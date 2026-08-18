#!/usr/bin/env bats
load helper

setup() {
  setup_stubs
  source "$FED_INFRA_ROOT/lib/common.sh"
  source "$FED_INFRA_ROOT/lib/config.sh"
  source "$FED_INFRA_ROOT/lib/render.sh"
  fed_config_defaults
  export FED_NAMESPACE=demo-ns
  TPL="$BATS_TEST_TMPDIR/t.yaml.tpl"
}

@test "fed_render substitutes FED_ variables" {
  echo 'namespace: ${FED_NAMESPACE}' > "$TPL"
  run fed_render "$TPL"
  [ "$output" = "namespace: demo-ns" ]
}

@test "fed_render leaves non-FL variables untouched" {
  echo 'cmd: echo $HOSTNAME ${PATH}' > "$TPL"
  run fed_render "$TPL"
  [ "$output" = 'cmd: echo $HOSTNAME ${PATH}' ]
}

@test "fed_render dies on a missing template" {
  run bash -c "source '$FED_INFRA_ROOT/lib/common.sh'; source '$FED_INFRA_ROOT/lib/render.sh'; fed_render /nope.tpl"
  [ "$status" -eq 1 ]
  [[ "$output" == *"template not found"* ]]
}

@test "fed_apply pipes rendered output into kubectl apply" {
  echo 'namespace: ${FED_NAMESPACE}' > "$TPL"
  fed_apply "$TPL" thing
  assert_called "kubectl apply -f -"
}

@test "fed_apply writes a file instead of calling kubectl when dry-running" {
  echo 'namespace: ${FED_NAMESPACE}' > "$TPL"
  export FED_DRY_RUN=1 FED_RENDER_DIR="$BATS_TEST_TMPDIR/out"
  fed_apply "$TPL" thing
  refute_called "kubectl apply"
  [ "$(cat "$FED_RENDER_DIR/thing.yaml")" = "namespace: demo-ns" ]
}

@test "fed_apply dies when dry-running without a render dir" {
  echo 'x: 1' > "$TPL"
  export FED_DRY_RUN=1 FED_RENDER_DIR=""
  run fed_apply "$TPL" thing
  [ "$status" -eq 1 ]
  [[ "$output" == *"FED_RENDER_DIR"* ]]
}

@test "fed_render substitutes FED_MEMBER_COUNT and FED_MEMBER_PREFIX" {
  # Guards the FED_TEMPLATE_VARS whitelist directly for the Karmada
  # component's config: a variable missing from the whitelist is left as a
  # literal, unsubstituted ${VAR} in the output rather than an empty string
  # (see "fed_render leaves non-FL variables untouched" above -- that is
  # envsubst's documented SHELL-FORMAT behaviour), so dropping either from
  # the whitelist would fail this test with the placeholder still in
  # $output instead of "3"/"worker".
  export FED_MEMBER_COUNT=3 FED_MEMBER_PREFIX=worker
  echo 'members: ${FED_MEMBER_COUNT} prefix: ${FED_MEMBER_PREFIX}' > "$TPL"
  run fed_render "$TPL"
  [ "$output" = "members: 3 prefix: worker" ]
}

@test "fed_render substitutes FED_KARMADA_APISERVER_PORT and FED_NODEPORT_KARMADA_DASHBOARD" {
  # Same guard as above, for the two port variables kind/multi-host.yaml.tpl
  # needs to map the Karmada apiserver and dashboard NodePorts to the host --
  # dropped from the whitelist, they would leave the literal ${VAR}
  # placeholder in the rendered output (invalid YAML port values), not an
  # empty string.
  export FED_KARMADA_APISERVER_PORT=32443 FED_NODEPORT_KARMADA_DASHBOARD=32000
  echo 'apiserver: ${FED_KARMADA_APISERVER_PORT} dashboard: ${FED_NODEPORT_KARMADA_DASHBOARD}' > "$TPL"
  run fed_render "$TPL"
  [ "$output" = "apiserver: 32443 dashboard: 32000" ]
}

@test "fed_render substitutes FED_HOSTPORT_KARMADA_DASHBOARD independently of the NodePort" {
  # Guards that the whitelist carries the hostPort half of the pair too, and
  # that the two are independently substitutable, not accidentally aliased
  # to the same value by construction.
  export FED_NODEPORT_KARMADA_DASHBOARD=32000 FED_HOSTPORT_KARMADA_DASHBOARD=32050
  echo 'nodePort: ${FED_NODEPORT_KARMADA_DASHBOARD} hostPort: ${FED_HOSTPORT_KARMADA_DASHBOARD}' > "$TPL"
  run fed_render "$TPL"
  [ "$output" = "nodePort: 32000 hostPort: 32050" ]
}

@test "fed_render substitutes FED_NODEPORT_K8S_DASHBOARD and FED_HOSTPORT_K8S_DASHBOARD" {
  # Guards the whitelist for the Kubernetes Dashboard's own port pair, used
  # by kind/single-cluster.yaml.tpl and kind/multi-host.yaml.tpl.
  export FED_NODEPORT_K8S_DASHBOARD=30443 FED_HOSTPORT_K8S_DASHBOARD=8443
  echo 'nodePort: ${FED_NODEPORT_K8S_DASHBOARD} hostPort: ${FED_HOSTPORT_K8S_DASHBOARD}' > "$TPL"
  run fed_render "$TPL"
  [ "$output" = "nodePort: 30443 hostPort: 8443" ]
}

@test "fed_render substitutes FED_KFP_VERSION" {
  # FED_KFP_VERSION is defaulted and exported by fed_config_defaults, same
  # as every other variable guarded above, but was absent from
  # FED_TEMPLATE_VARS entirely -- harmless while it's only ever used as a
  # shell variable in fed_kfp_install's `kubectl apply -k` URLs, never inside
  # a template, but a future KFP template referencing it would leave the
  # literal ${FED_KFP_VERSION} placeholder in the rendered manifest instead
  # of the configured version.
  export FED_KFP_VERSION=9.9.9
  echo 'version: ${FED_KFP_VERSION}' > "$TPL"
  run fed_render "$TPL"
  [ "$output" = "version: 9.9.9" ]
}

@test "namespace template renders to a valid Namespace object" {
  run fed_render "$FED_INFRA_ROOT/manifests/namespace.yaml.tpl"
  [[ "$output" == *"kind: Namespace"* ]] || return 1
  [[ "$output" == *"name: demo-ns"* ]]
}
