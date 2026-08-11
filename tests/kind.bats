#!/usr/bin/env bats
load helper

setup() {
  setup_stubs
  source "$FED_INFRA_ROOT/lib/common.sh"
  source "$FED_INFRA_ROOT/lib/config.sh"
  source "$FED_INFRA_ROOT/lib/render.sh"
  source "$FED_INFRA_ROOT/lib/kind.sh"
  fed_config_defaults
  export FED_CLUSTER_NAME=demo
}

@test "fed_kind_ensure_cluster creates the cluster when absent" {
  export STUB_KIND_OUT="other-cluster"
  fed_kind_ensure_cluster demo "$FED_INFRA_ROOT/kind/single-cluster.yaml.tpl"
  assert_called "kind create cluster --name demo --config -"
}

@test "fed_kind_ensure_cluster is a no-op when the cluster exists" {
  export STUB_KIND_OUT="demo"
  fed_kind_ensure_cluster demo "$FED_INFRA_ROOT/kind/single-cluster.yaml.tpl"
  refute_called "kind create cluster"
}

@test "fed_kind_ensure_cluster does not match a cluster by prefix" {
  export STUB_KIND_OUT="demo-other"
  fed_kind_ensure_cluster demo "$FED_INFRA_ROOT/kind/single-cluster.yaml.tpl"
  assert_called "kind create cluster --name demo"
}

@test "fed_kind_load_image skips loading when the digest already matches" {
  export STUB_DOCKER_OUT="sha256:abcdef123456789"
  # 'docker image inspect' returns the id above, trimmed to 12 chars by the
  # implementation. FED_KIND_CRICTL_OUT injects the in-cluster id so the test
  # does not need a real 'docker exec ... crictl images'.
  export FED_KIND_CRICTL_OUT="abcdef123456"
  fed_kind_load_image myimg:v1 demo
  refute_called "kind load docker-image"
}

@test "fed_kind_load_image loads when the cluster copy is stale" {
  export STUB_DOCKER_OUT="sha256:abcdef123456789"
  export FED_KIND_CRICTL_OUT="999999999999"
  fed_kind_load_image myimg:v1 demo
  assert_called "kind load docker-image myimg:v1 --name demo"
}

@test "fed_kind_load_image loads when the image is absent from the cluster" {
  export STUB_DOCKER_OUT="sha256:abcdef123456789"
  export FED_KIND_CRICTL_OUT=""
  fed_kind_load_image myimg:v1 demo
  assert_called "kind load docker-image myimg:v1 --name demo"
}

@test "fed_kind_delete_cluster deletes by name" {
  fed_kind_delete_cluster demo
  assert_called "kind delete cluster --name demo"
}

@test "kind template renders the configured host port mappings" {
  export FED_HOSTPORT_KFP=8080 FED_NODEPORT_KFP=30080
  run fed_render "$FED_INFRA_ROOT/kind/single-cluster.yaml.tpl"
  [[ "$output" == *"containerPort: 30080"* ]]
  [[ "$output" == *"hostPort: 8080"* ]]
  [[ "$output" == *"name: demo"* ]]
}

@test "fed_kind_ensure_cluster appends the requested worker nodes" {
  export STUB_KIND_OUT="" FED_KIND_WORKERS=2
  run fed_kind_ensure_cluster demo "$FED_INFRA_ROOT/kind/single-cluster.yaml.tpl"
  [ "$status" -eq 0 ]
  assert_called "kind create cluster --name demo"
}

# The stub previously logged only argv, never the piped stdin, so the
# rendered cluster config handed to `kind create cluster --config -` was
# invisible to every test — deleting the worker-append loop in kind.sh
# entirely still left the whole suite green. These assert on
# $STUB_STDIN_LOG (populated by tests/stubs/kind) to actually cover
# FED_KIND_WORKERS, the one structural difference between consumers' clusters.

@test "fed_kind_ensure_cluster's piped config has one '- role: worker' line per FED_KIND_WORKERS" {
  export STUB_KIND_OUT="" FED_KIND_WORKERS=2
  fed_kind_ensure_cluster demo "$FED_INFRA_ROOT/kind/single-cluster.yaml.tpl"
  [ "$(grep -c '^  - role: worker$' "$STUB_STDIN_LOG")" -eq 2 ]
}

@test "fed_kind_ensure_cluster's piped config has no worker lines when FED_KIND_WORKERS=0" {
  export STUB_KIND_OUT="" FED_KIND_WORKERS=0
  fed_kind_ensure_cluster demo "$FED_INFRA_ROOT/kind/single-cluster.yaml.tpl"
  [ "$(grep -c '^  - role: worker$' "$STUB_STDIN_LOG")" -eq 0 ]
}

# Regression coverage for the "unreachable fed_die" bug: bats calls
# fed_kind_load_image directly, without set -e, which is exactly the shell
# option context production never uses (bin/fed-infra-up always sets
# `set -euo pipefail`). Both cases below run the function through
# `bash -c 'set -euo pipefail; ...'` to reproduce the real entrypoint's
# strict mode, where a plain `var=$(pipeline)` assignment aborts the script
# on a failing pipeline before any following line — including a fed_die —
# can execute.

@test "fed_kind_load_image dies with a diagnostic under strict mode when the image is missing locally" {
  export STUB_DOCKER_FAIL_GLOB="image inspect*"
  run bash -c "
    set -euo pipefail
    . '$FED_INFRA_ROOT/lib/common.sh'
    . '$FED_INFRA_ROOT/lib/config.sh'
    . '$FED_INFRA_ROOT/lib/kind.sh'
    fed_config_defaults
    fed_kind_load_image myimg:v1 demo
  "
  [ "$status" -eq 1 ]
  [[ "$output" == *"image not found locally: myimg:v1 (build it first)"* ]]
}

@test "fed_kind_load_image falls back to kind load under strict mode when the control-plane container is unreachable" {
  export STUB_DOCKER_FAIL_GLOB="exec *"
  run bash -c "
    set -euo pipefail
    . '$FED_INFRA_ROOT/lib/common.sh'
    . '$FED_INFRA_ROOT/lib/config.sh'
    . '$FED_INFRA_ROOT/lib/kind.sh'
    fed_config_defaults
    fed_kind_load_image myimg:v1 demo
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"loading image myimg:v1 into cluster demo"* ]]
  assert_called "kind load docker-image myimg:v1 --name demo"
}
