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
  # component's config: a variable missing from it renders as an empty
  # string with no error, so this would silently start passing 0/empty
  # instead of failing if either were dropped from the whitelist.
  export FED_MEMBER_COUNT=3 FED_MEMBER_PREFIX=worker
  echo 'members: ${FED_MEMBER_COUNT} prefix: ${FED_MEMBER_PREFIX}' > "$TPL"
  run fed_render "$TPL"
  [ "$output" = "members: 3 prefix: worker" ]
}

@test "fed_render substitutes FED_KARMADA_APISERVER_PORT and FED_KARMADA_DASHBOARD_PORT" {
  # Same guard as above, for the two port variables kind/multi-host.yaml.tpl
  # needs to map the Karmada apiserver and dashboard NodePorts to the host --
  # dropped from the whitelist, they would render as empty strings (invalid
  # YAML port values) with no error from fed_render itself.
  export FED_KARMADA_APISERVER_PORT=32443 FED_KARMADA_DASHBOARD_PORT=32000
  echo 'apiserver: ${FED_KARMADA_APISERVER_PORT} dashboard: ${FED_KARMADA_DASHBOARD_PORT}' > "$TPL"
  run fed_render "$TPL"
  [ "$output" = "apiserver: 32443 dashboard: 32000" ]
}

@test "namespace template renders to a valid Namespace object" {
  run fed_render "$FED_INFRA_ROOT/manifests/namespace.yaml.tpl"
  [[ "$output" == *"kind: Namespace"* ]] || return 1
  [[ "$output" == *"name: demo-ns"* ]]
}
