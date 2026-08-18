#!/usr/bin/env bats
load helper

setup() {
  setup_stubs
  source "$FED_INFRA_ROOT/lib/common.sh"
  source "$FED_INFRA_ROOT/lib/config.sh"
  source "$FED_INFRA_ROOT/lib/render.sh"
  # fed_karmada_init's image pre-fetch reuses fed_kind_cluster_image_id (the
  # same digest-check kind.sh already uses for fed_kind_load_image) to skip
  # pulling an image the cluster already has.
  source "$FED_INFRA_ROOT/lib/kind.sh"
  source "$FED_INFRA_ROOT/lib/karmada.sh"
  fed_config_defaults
  export FED_KARMADA_CONFIG="$BATS_TEST_TMPDIR/.karmada/karmada-apiserver.config"
  # The docker stub's own default output is shaped like an image digest
  # (sha256:...), not an IP -- fine for the image-id callers it was written
  # for, but nonsensical as a "docker inspect ... IPAddress" result here.
  # Give join tests a plausible default; tests that care about a specific
  # value (or about no IP being resolvable) override or unset it.
  export STUB_DOCKER_OUT="10.0.0.5"
  # fed_karmada_init now verifies `karmadactl version` against
  # FED_KARMADA_VERSION before doing anything else -- default this to a
  # matching value so every test that doesn't care about the check
  # specifically exercises the same "installed karmadactl matches" path
  # instead of tripping the mismatch fed_die. Tests for the check itself
  # override it.
  export STUB_KARMADACTL_OUT='karmadactl version: version.Info{GitVersion:"v1.17.0", GitCommit:"deadbeef", GitTreeState:"clean"}'
}

# --- fed_karmada_init ---

@test "fed_karmada_init skips karmadactl init when karmada-system already exists" {
  fed_karmada_init host
  assert_called "kubectl config use-context kind-host"
  assert_called "kubectl get namespace karmada-system"
  refute_called "karmadactl init"
}

@test "fed_karmada_init passes the expected flags when karmada-system does not exist" {
  export STUB_KUBECTL_FAIL_GLOB="get namespace karmada-system*"
  local karmada_data
  karmada_data=$(dirname "$FED_KARMADA_CONFIG")
  fed_karmada_init host
  assert_called "karmadactl init"
  assert_called "--karmada-data=${karmada_data}"
  assert_called "--karmada-pki=${karmada_data}/pki"
  assert_called "--cert-external-ip=127.0.0.1"
  assert_called "--cert-external-dns=localhost"
  assert_called "--karmada-apiserver-advertise-address=127.0.0.1"
  assert_called "--etcd-storage-mode=emptyDir"
}

@test "fed_karmada_init passes --port matching FED_KARMADA_APISERVER_PORT to karmadactl init" {
  # karmadactl init --port defaults to 32443, and kind/multi-host.yaml.tpl
  # maps that same port from FED_KARMADA_APISERVER_PORT to the host. If this
  # flag were left off (or hardcoded to a different value), the two would be
  # free to drift and the apiserver would be unreachable from the host again
  # -- exactly the gap this flag closes.
  export STUB_KUBECTL_FAIL_GLOB="get namespace karmada-system*"
  fed_karmada_init host
  assert_called "--port=32443"
}

@test "fed_karmada_init passes a custom FED_KARMADA_APISERVER_PORT through to karmadactl init, not a hardcoded default" {
  export STUB_KUBECTL_FAIL_GLOB="get namespace karmada-system*"
  export FED_KARMADA_APISERVER_PORT=40443
  fed_karmada_init host
  assert_called "--port=40443"
  refute_called "--port=32443"
}

@test "fed_karmada_init fails fast when the installed karmadactl version does not match FED_KARMADA_VERSION" {
  # FED_KARMADA_VERSION used to be purely decorative: karmadactl init has no
  # flag that pins the Karmada control plane's own image tag (only
  # --kube-image-tag, for the Kubernetes components it installs), so the
  # installed version was entirely whatever karmadactl happened to be on
  # PATH. Verifying the two agree, and refusing to proceed on a mismatch, is
  # what makes the variable genuinely load-bearing.
  export STUB_KUBECTL_FAIL_GLOB="get namespace karmada-system*"
  export STUB_KARMADACTL_OUT='karmadactl version: version.Info{GitVersion:"v1.16.0", GitCommit:"aaa"}'
  run fed_karmada_init host
  [ "$status" -ne 0 ]
  [[ "$output" == *"v1.16.0"* ]] || return 1
  [[ "$output" == *"v1.17.0"* ]] || return 1
  refute_called "karmadactl init"
}

@test "fed_karmada_init proceeds when the installed karmadactl version matches FED_KARMADA_VERSION" {
  export STUB_KUBECTL_FAIL_GLOB="get namespace karmada-system*"
  export STUB_KARMADACTL_OUT='karmadactl version: version.Info{GitVersion:"v1.17.0", GitCommit:"aaa"}'
  fed_karmada_init host
  assert_called "karmadactl init"
}

@test "fed_karmada_init fails fast with a clear message when karmadactl version output cannot be parsed" {
  export STUB_KUBECTL_FAIL_GLOB="get namespace karmada-system*"
  export STUB_KARMADACTL_OUT='garbage, not the expected version.Info struct'
  run fed_karmada_init host
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not parse"* ]] || return 1
  refute_called "karmadactl init"
}

@test "fed_karmada_verify_version passes when karmadactl's version matches" {
  export STUB_KARMADACTL_OUT='karmadactl version: version.Info{GitVersion:"v1.17.0", GitCommit:"aaa"}'
  run fed_karmada_verify_version v1.17.0
  [ "$status" -eq 0 ]
}

@test "fed_karmada_verify_version names both the installed and expected version when they differ" {
  export STUB_KARMADACTL_OUT='karmadactl version: version.Info{GitVersion:"v1.16.0", GitCommit:"aaa"}'
  run fed_karmada_verify_version v1.17.0
  [ "$status" -ne 0 ]
  [[ "$output" == *"v1.16.0"* ]] || return 1
  [[ "$output" == *"v1.17.0"* ]]
}

@test "fed_karmada_verify_version is a complete no-op under FED_DRY_RUN=1" {
  export FED_DRY_RUN=1
  fed_karmada_verify_version v1.17.0
  [ -z "$(calls)" ]
}

@test "fed_karmada_verify_version's own version lookup runs to completion under set -euo pipefail when karmadactl fails" {
  # Same idiom as everywhere else in this file: guard the command
  # substitution so a failing `karmadactl version` cannot trip the caller's
  # errexit before the "could not parse" diagnostic below it gets to run.
  export STUB_KARMADACTL_FAIL_GLOB="version*"
  run bash -c "
    set -euo pipefail
    source '$FED_INFRA_ROOT/lib/common.sh'
    source '$FED_INFRA_ROOT/lib/karmada.sh'
    fed_karmada_verify_version v1.17.0
    echo UNREACHABLE
  "
  [ "$status" -ne 0 ]
  [[ "$output" != *"UNREACHABLE"* ]] || return 1
  [[ "$output" == *"could not parse"* ]]
}

@test "fed_karmada_init pre-fetches the Karmada core images before karmadactl init" {
  # On Apple Silicon an in-cluster pull of these can be slow enough to time
  # out `karmadactl init` outright -- the original hand-rolled bootstrap
  # side-loaded them first specifically "to avoid container networking
  # timeouts".
  export STUB_KUBECTL_FAIL_GLOB="get namespace karmada-system*"
  fed_karmada_init host
  assert_called "docker pull docker.io/karmada/karmada-aggregated-apiserver:v1.17.0"
  assert_called "docker pull docker.io/karmada/karmada-controller-manager:v1.17.0"
  assert_called "docker pull docker.io/karmada/karmada-scheduler:v1.17.0"
  assert_called "docker pull docker.io/karmada/karmada-webhook:v1.17.0"
  assert_called "kind load docker-image docker.io/karmada/karmada-aggregated-apiserver:v1.17.0 --name host"
  local pull_line init_line
  pull_line=$(grep -n "docker pull docker.io/karmada" "$STUB_LOG" | head -1 | cut -d: -f1)
  init_line=$(grep -n "karmadactl init" "$STUB_LOG" | head -1 | cut -d: -f1)
  [ -n "$pull_line" ]
  [ -n "$init_line" ]
  [ "$pull_line" -lt "$init_line" ]
}

@test "fed_karmada_init's image pre-fetch uses FED_KARMADA_VERSION as the image tag, not a hardcoded one" {
  export STUB_KUBECTL_FAIL_GLOB="get namespace karmada-system*"
  export FED_KARMADA_VERSION=v1.20.5
  export STUB_KARMADACTL_OUT='karmadactl version: version.Info{GitVersion:"v1.20.5", GitCommit:"deadbeef"}'
  fed_karmada_init host
  assert_called "docker pull docker.io/karmada/karmada-scheduler:v1.20.5"
  refute_called "docker pull docker.io/karmada/karmada-scheduler:v1.17.0"
}

@test "fed_karmada_init skips pre-fetching an image already present in the host cluster" {
  export STUB_KUBECTL_FAIL_GLOB="get namespace karmada-system*"
  export FED_KIND_CRICTL_OUT="abcdef123456"
  fed_karmada_init host
  refute_called "docker pull"
  refute_called "kind load docker-image"
  assert_called "karmadactl init"
}

@test "fed_karmada_init's image pre-fetch failing does not abort the bootstrap" {
  # `|| true` throughout, matching the original: a failed pre-fetch is only
  # a missed optimization -- karmadactl init still pulls in-cluster on a miss.
  export STUB_KUBECTL_FAIL_GLOB="get namespace karmada-system*"
  export STUB_DOCKER_FAIL_GLOB="pull*"
  run fed_karmada_init host
  [ "$status" -eq 0 ]
  assert_called "karmadactl init"
}

@test "fed_karmada_init's image pre-fetch load failing does not abort the bootstrap" {
  export STUB_KUBECTL_FAIL_GLOB="get namespace karmada-system*"
  export STUB_KIND_FAIL_GLOB="load docker-image*"
  run fed_karmada_init host
  [ "$status" -eq 0 ]
  assert_called "karmadactl init"
}

@test "fed_karmada_prefetch_images is a complete no-op under FED_DRY_RUN=1" {
  export FED_DRY_RUN=1
  fed_karmada_prefetch_images host v1.17.0
  [ -z "$(calls)" ]
}

@test "fed_karmada_prefetch_images's image-presence check runs to completion under set -euo pipefail when it fails" {
  # Same idiom as fed_karmada_join's IP lookup and fed_kind_load_image's
  # digest check (see lib/karmada.sh's top-of-file comment and
  # fed_kind_load_image): a plain `var=$(pipeline)` assignment under the
  # caller's `set -euo pipefail` aborts the whole script on a failing
  # pipeline before any graceful fallback below it can run. Exercise this
  # for real, under errexit, not just via `run` (which always shields the
  # call from it).
  export STUB_DOCKER_FAIL_GLOB="exec * crictl images*"
  run bash -c "
    set -euo pipefail
    source '$FED_INFRA_ROOT/lib/common.sh'
    source '$FED_INFRA_ROOT/lib/kind.sh'
    source '$FED_INFRA_ROOT/lib/karmada.sh'
    fed_karmada_prefetch_images host v1.17.0
    echo REACHED_AFTER_PREFETCH
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"REACHED_AFTER_PREFETCH"* ]]
}

@test "fed_karmada_init creates the karmada data/pki directories before init" {
  export STUB_KUBECTL_FAIL_GLOB="get namespace karmada-system*"
  fed_karmada_init host
  [ -d "$(dirname "$FED_KARMADA_CONFIG")/pki" ]
}

@test "fed_karmada_init is a complete no-op under FED_DRY_RUN=1" {
  export FED_DRY_RUN=1
  fed_karmada_init host
  [ -z "$(calls)" ]
}

@test "fed_karmada_init fails fast when the context switch fails" {
  export STUB_KUBECTL_FAIL_GLOB="config use-context*"
  run fed_karmada_init host
  [ "$status" -ne 0 ]
  refute_called "karmadactl init"
}

@test "fed_karmada_init fails fast when karmadactl init fails" {
  export STUB_KUBECTL_FAIL_GLOB="get namespace karmada-system*"
  export STUB_KARMADACTL_FAIL_GLOB="init*"
  run fed_karmada_init host
  [ "$status" -ne 0 ]
}

# --- fed_karmada_join ---

@test "fed_karmada_join joins a cluster not yet registered" {
  # Only the existence probe (the very first 'get cluster member1' call, with
  # no further flags) fails; the two later 'get cluster member1 -o
  # jsonpath=...' reads for secretRef must still succeed, so a permanent
  # STUB_KUBECTL_FAIL_GLOB would wrongly fail those too. FAIL_ONCE fails
  # exactly the first match and lets every later one through.
  export STUB_KUBECTL_FAIL_ONCE_GLOB="*get cluster member1*"
  fed_karmada_join member1 kind-member1
  assert_called "karmadactl --kubeconfig=${FED_KARMADA_CONFIG} join member1"
  assert_called "--cluster-context=kind-member1"
}

@test "fed_karmada_join skips karmadactl join for an already-registered cluster" {
  fed_karmada_join member1 kind-member1
  refute_called "karmadactl"
}

@test "fed_karmada_join still re-patches the endpoint for an already-registered cluster" {
  # Re-patching on every call (not only right after joining) is deliberate:
  # a kind container can get a new Docker-network IP across a docker/host
  # restart even though the cluster stays registered with Karmada.
  fed_karmada_join member1 kind-member1
  assert_called "patch cluster member1 --type=merge"
  assert_called "patch secret"
}

@test "fed_karmada_join patches the Cluster apiEndpoint and rewrites the Secret's kubeconfig to the container's Docker IP" {
  export STUB_DOCKER_OUT="10.42.0.7"
  local plain b64
  plain=$'server: https://127.0.0.1:6443\naltserver: https://localhost:6443\n'
  b64=$(printf '%s' "$plain" | python3 -c "import sys, base64; sys.stdout.write(base64.b64encode(sys.stdin.buffer.read()).decode())")
  export STUB_KUBECTL_SECRET_KUBECONFIG_OUT="$b64"

  fed_karmada_join member1 kind-member1

  assert_called "patch cluster member1 --type=merge"
  assert_called "https://10.42.0.7:6443"

  local patch_secret_call patched_b64 decoded
  patch_secret_call=$(grep "patch secret" "$STUB_LOG" | tail -1)
  [ -n "$patch_secret_call" ]
  patched_b64=$(printf '%s' "$patch_secret_call" | sed -E 's/.*"kubeconfig":"([^"]*)".*/\1/')
  [ -n "$patched_b64" ]
  decoded=$(printf '%s' "$patched_b64" | python3 -c "import sys, base64; sys.stdout.write(base64.b64decode(sys.stdin.read()).decode())")
  [[ "$decoded" == *"https://10.42.0.7:6443"* ]] || return 1
  # Both occurrences must be gone, not just one -- this is the essential
  # part of the port: a kubeconfig with either placeholder left in it still
  # points the Karmada control plane at itself instead of the member.
  [[ "$decoded" != *"127.0.0.1"* ]] || return 1
  [[ "$decoded" != *"localhost"* ]]
}

@test "fed_karmada_join is a complete no-op under FED_DRY_RUN=1" {
  export FED_DRY_RUN=1
  fed_karmada_join member1 kind-member1
  [ -z "$(calls)" ]
}

@test "fed_karmada_join fails fast when karmadactl join fails" {
  export STUB_KUBECTL_FAIL_ONCE_GLOB="*get cluster member1*"
  export STUB_KARMADACTL_FAIL_GLOB="*join*"
  run fed_karmada_join member1 kind-member1
  [ "$status" -ne 0 ]
  refute_called "patch cluster"
}

@test "fed_karmada_join fails fast when patching the Cluster object fails" {
  export STUB_KUBECTL_FAIL_GLOB="*patch cluster*"
  run fed_karmada_join member1 kind-member1
  [ "$status" -ne 0 ]
  refute_called "patch secret"
}

@test "fed_karmada_join fails fast when patching the Secret fails" {
  export STUB_KUBECTL_FAIL_GLOB="*patch secret*"
  run fed_karmada_join member1 kind-member1
  [ "$status" -ne 0 ]
}

@test "fed_karmada_join returns success without patching when the Docker IP cannot be determined" {
  export STUB_DOCKER_FAIL_GLOB="inspect*"
  run fed_karmada_join member1 kind-member1
  [ "$status" -eq 0 ]
  refute_called "patch cluster"
}

@test "fed_karmada_join's empty-IP fallback runs to completion under set -euo pipefail, not just under 'run'" {
  # bin/fed-infra-up sources this library under set -euo pipefail. The IP
  # lookup below is a plain `ip=$(...)` assignment (not `local ip=$(...)`,
  # which would mask a failing command substitution behind the `local`
  # builtin's own exit status) -- so if the substitution's pipeline itself
  # fails, errexit propagates it and kills the whole script on that line,
  # before the graceful "empty ip -> warn and return 0" branch below it
  # ever runs. A plain `run fed_karmada_join ...` in this same test file
  # cannot catch that: `run` always shields the call from errexit, which
  # is exactly the blind spot this test exists to close. Exercise it for
  # real, in a subshell that actually has errexit on, and assert on a
  # marker printed *after* the call returns -- not just the exit status,
  # which could pass for the wrong reason (e.g. the marker line itself
  # silently not running while the subshell still happens to exit 0).
  export STUB_DOCKER_FAIL_GLOB="inspect*"
  run bash -c "
    set -euo pipefail
    source '$FED_INFRA_ROOT/lib/common.sh'
    source '$FED_INFRA_ROOT/lib/karmada.sh'
    fed_karmada_join member1 kind-member1
    echo REACHED_AFTER_JOIN
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"REACHED_AFTER_JOIN"* ]] || return 1
  [[ "$output" == *"could not determine the Docker-network IP"* ]]
}

# --- fed_karmada_wait_cluster ---

@test "fed_karmada_wait_cluster waits for the cluster to report Ready" {
  fed_karmada_wait_cluster member1
  assert_called "kubectl --kubeconfig=${FED_KARMADA_CONFIG} wait --for=condition=Ready cluster/member1 --timeout=120s"
}

@test "fed_karmada_wait_cluster is a complete no-op under FED_DRY_RUN=1" {
  export FED_DRY_RUN=1
  fed_karmada_wait_cluster member1
  [ -z "$(calls)" ]
}

@test "fed_karmada_wait_cluster fails fast when the wait fails" {
  export STUB_KUBECTL_FAIL_GLOB="*wait*"
  run fed_karmada_wait_cluster member1
  [ "$status" -ne 0 ]
}

@test "fed_karmada_init fails fast when karmada-system exists but its datastore is empty" {
  # karmadactl init runs etcd with --etcd-storage-mode=emptyDir, so a
  # docker/host restart brings the control plane back with every CRD, Cluster
  # registration and PropagationPolicy gone while the namespace itself still
  # exists. Probing only the namespace reports "already initialized" and
  # skips, leaving a control plane that cannot serve cluster.karmada.io and
  # fails much later, at join, with an unrelated-looking error.
  export STUB_KUBECTL_FAIL_GLOB="*get crd clusters.cluster.karmada.io*"
  run fed_karmada_init host
  [ "$status" -eq 1 ]
  [[ "$output" == *"karmada-system"* ]] || return 1
  [[ "$output" == *"emptyDir"* ]] || return 1
  refute_called "karmadactl init"
}

@test "fed_karmada_init skips only when the datastore actually has the cluster CRD" {
  fed_karmada_init host
  assert_called "kubectl get namespace karmada-system"
  assert_called "get crd clusters.cluster.karmada.io"
  refute_called "karmadactl init"
}
