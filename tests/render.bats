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

@test "namespace template renders to a valid Namespace object" {
  run fed_render "$FED_INFRA_ROOT/manifests/namespace.yaml.tpl"
  [[ "$output" == *"kind: Namespace"* ]]
  [[ "$output" == *"name: demo-ns"* ]]
}
