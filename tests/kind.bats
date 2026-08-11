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
