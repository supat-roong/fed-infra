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

@test "fed_kind_ensure_cluster raises inotify limits on the control-plane node after creating a cluster" {
  # kind nodes running many pods (the multi profile's members especially)
  # routinely exhaust the default inotify instance/watch ceiling, which
  # surfaces as a confusing "too many open files" from kubelet/containerd
  # rather than anything that names inotify. Generic kind hygiene, not
  # Karmada-specific -- applies to the single profile too.
  export STUB_KIND_OUT="other-cluster"
  fed_kind_ensure_cluster demo "$FED_INFRA_ROOT/kind/single-cluster.yaml.tpl"
  assert_called "docker exec demo-control-plane sysctl -w fs.inotify.max_user_instances=512 fs.inotify.max_user_watches=524288"
}

@test "fed_kind_ensure_cluster raises inotify limits even when the cluster already exists" {
  # The original hand-rolled bootstrap raised these on every run, not just
  # right after creation -- a node can lose the setting across a docker/host
  # restart even though the kind cluster itself is unchanged.
  export STUB_KIND_OUT="demo"
  fed_kind_ensure_cluster demo "$FED_INFRA_ROOT/kind/single-cluster.yaml.tpl"
  assert_called "docker exec demo-control-plane sysctl -w fs.inotify.max_user_instances=512 fs.inotify.max_user_watches=524288"
}

@test "fed_kind_ensure_cluster does not fail cluster bootstrap when raising inotify limits fails" {
  # The original used `|| true` throughout for exactly this: raising limits
  # is hygiene, not a hard prerequisite, and must never abort a bootstrap
  # that otherwise succeeded.
  export STUB_KIND_OUT="other-cluster"
  export STUB_DOCKER_FAIL_GLOB="exec * sysctl*"
  run fed_kind_ensure_cluster demo "$FED_INFRA_ROOT/kind/single-cluster.yaml.tpl"
  [ "$status" -eq 0 ]
}

@test "fed_kind_ensure_cluster is a complete no-op under FED_DRY_RUN=1" {
  export FED_DRY_RUN=1
  fed_kind_ensure_cluster demo "$FED_INFRA_ROOT/kind/single-cluster.yaml.tpl"
  [ -z "$(calls)" ]
}

@test "fed_kind_delete_cluster deletes by name" {
  fed_kind_delete_cluster demo
  assert_called "kind delete cluster --name demo"
}

@test "kind template renders the configured host port mappings" {
  export FED_HOSTPORT_KFP=8080 FED_NODEPORT_KFP=30080
  run fed_render "$FED_INFRA_ROOT/kind/single-cluster.yaml.tpl"
  [[ "$output" == *"containerPort: 30080"* ]] || return 1
  [[ "$output" == *"hostPort: 8080"* ]] || return 1
  [[ "$output" == *"name: demo"* ]]
}

@test "multi-host template renders the same host port mappings as single-cluster" {
  export FED_HOSTPORT_KFP=8080 FED_NODEPORT_KFP=30080 \
         FED_HOSTPORT_MLFLOW=5050 FED_NODEPORT_MLFLOW=30500 \
         FED_HOSTPORT_MINIO_API=9000 FED_NODEPORT_MINIO_API=30900 \
         FED_HOSTPORT_MINIO_CONSOLE=9001 FED_NODEPORT_MINIO_CONSOLE=30901 \
         FED_HOSTPORT_TEMPORAL_UI=8233 FED_NODEPORT_TEMPORAL_UI=30733
  run fed_render "$FED_INFRA_ROOT/kind/multi-host.yaml.tpl"
  # Note: bats does not abort a test on a failing bare `[[ ]]` unless it is
  # the function's last statement (only the final command's status is
  # checked), so every assertion below is guarded with `|| return 1` to make
  # sure a false one actually fails the test instead of being silently
  # shadowed by a later true one.
  [[ "$output" == *"name: demo"* ]] || return 1
  [[ "$output" == *"containerPort: 30080"* ]] || return 1
  [[ "$output" == *"hostPort: 8080"* ]] || return 1
  [[ "$output" == *"containerPort: 30500"* ]] || return 1
  [[ "$output" == *"hostPort: 5050"* ]] || return 1
  [[ "$output" == *"containerPort: 30900"* ]] || return 1
  [[ "$output" == *"hostPort: 9000"* ]] || return 1
  [[ "$output" == *"containerPort: 30901"* ]] || return 1
  [[ "$output" == *"hostPort: 9001"* ]] || return 1
  [[ "$output" == *"containerPort: 30733"* ]] || return 1
  [[ "$output" == *"hostPort: 8233"* ]] || return 1
}

@test "multi-host template renders every port mapping single-cluster has, plus the Karmada apiserver and dashboard ports" {
  # The two templates are no longer byte-identical: only the multi profile
  # runs a Karmada control plane on the host, so only multi-host.yaml.tpl
  # needs its NodePort mapped to the host. single-cluster.yaml.tpl is
  # unchanged, so multi-host's rendered output must still start with exactly
  # single-cluster's, with the Karmada ports appended after.
  run fed_render "$FED_INFRA_ROOT/kind/single-cluster.yaml.tpl"
  local single_output="$output"
  run fed_render "$FED_INFRA_ROOT/kind/multi-host.yaml.tpl"
  [[ "$output" == "$single_output"* ]] || return 1
  [[ "$output" == *"containerPort: 32443"* ]] || return 1
  [[ "$output" == *"hostPort: 32443"* ]] || return 1
  [[ "$output" == *"containerPort: 32000"* ]] || return 1
  [[ "$output" == *"hostPort: 32000"* ]]
}

@test "multi-host template renders the configured Karmada apiserver and dashboard ports, not just the defaults" {
  export FED_KARMADA_APISERVER_PORT=40443 FED_KARMADA_DASHBOARD_PORT=40000
  run fed_render "$FED_INFRA_ROOT/kind/multi-host.yaml.tpl"
  [[ "$output" == *"containerPort: 40443"* ]] || return 1
  [[ "$output" == *"hostPort: 40443"* ]] || return 1
  [[ "$output" == *"containerPort: 40000"* ]] || return 1
  [[ "$output" == *"hostPort: 40000"* ]] || return 1
  [[ "$output" != *"32443"* ]] || return 1
  [[ "$output" != *"32000"* ]]
}

@test "member template has no extraPortMappings and no name field" {
  run fed_render "$FED_INFRA_ROOT/kind/member.yaml.tpl"
  [[ "$output" != *"extraPortMappings"* ]] || return 1
  [[ "$output" != *"hostPort"* ]] || return 1
  [[ "$output" != *"name:"* ]] || return 1
  [[ "$output" == *"role: control-plane"* ]] || return 1
}

@test "member template has no Karmada apiserver/dashboard port mappings" {
  # The Karmada control plane pods run on the host only -- a member never
  # needs its own NodePort mapped to the machine's localhost.
  run fed_render "$FED_INFRA_ROOT/kind/member.yaml.tpl"
  [[ "$output" != *"32443"* ]] || return 1
  [[ "$output" != *"32000"* ]]
}

@test "fed_kind_ensure_cluster's piped config for a member has no port mappings" {
  export STUB_KIND_OUT=""
  fed_kind_ensure_cluster member1 "$FED_INFRA_ROOT/kind/member.yaml.tpl"
  assert_called "kind create cluster --name member1"
  [ "$(grep -c 'extraPortMappings' "$STUB_STDIN_LOG")" -eq 0 ]
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
  [[ "$output" == *"loading image myimg:v1 into cluster demo"* ]] || return 1
  assert_called "kind load docker-image myimg:v1 --name demo"
}

@test "fed_kind_raise_inotify_limits leaves an already-higher limit alone" {
  # The sysctl is shared with the host kernel rather than namespaced per
  # container, so `sysctl -w ...=512` does not just raise this node's ceiling
  # -- it overwrites the machine's. An operator who raised it to survive
  # several clusters would silently have it dropped back to 512 by the next
  # fed-infra-up. Raise means raise.
  export STUB_DOCKER_OUT="8192"
  fed_kind_raise_inotify_limits demo
  refute_called "sysctl -w fs.inotify.max_user_instances=512"
}

@test "fed_kind_raise_inotify_limits still raises a lower limit" {
  export STUB_DOCKER_OUT="128"
  fed_kind_raise_inotify_limits demo
  assert_called "sysctl -w fs.inotify.max_user_instances=512"
}

@test "fed_kind_raise_inotify_limits raises when the current value cannot be read" {
  export STUB_DOCKER_FAIL_GLOB="exec demo-control-plane sysctl -n*"
  fed_kind_raise_inotify_limits demo
  assert_called "sysctl -w fs.inotify.max_user_instances=512"
}
