#!/usr/bin/env bats
load helper

setup() {
  setup_stubs
  ENVFILE="$BATS_TEST_TMPDIR/infra.env"
  RENDER="$BATS_TEST_TMPDIR/render"
}

write_env() {
  cat > "$ENVFILE" <<EOF
FED_CLUSTER_NAME=demo
FED_NAMESPACE=demo-ns
FED_PROFILE=single
FED_COMPONENTS=$1
FED_S3_ENDPOINT=minio-service.demo-ns.svc.cluster.local:9000
FED_S3_ACCESS_KEY=ak
FED_S3_SECRET_KEY=sk
EOF
}

write_multi_env() {
  cat > "$ENVFILE" <<EOF
FED_CLUSTER_NAME=host
FED_NAMESPACE=demo-ns
FED_PROFILE=multi
FED_COMPONENTS=$1
FED_S3_ENDPOINT=minio-service.demo-ns.svc.cluster.local:9000
FED_S3_ACCESS_KEY=ak
FED_S3_SECRET_KEY=sk
EOF
}

# Sources every lib directly (same technique tests/karmada.bats and
# tests/kind.bats already use) and calls fed_up/fed_down for real, rather
# than through bin/fed-infra-up --dry-run. --dry-run guards away every
# cluster-create, karmada-join, and image-load call by design, which is
# exactly what a separate no-op test below covers; asserting on *which*
# clusters get created/joined/loaded needs the calls to actually reach the
# stubs on PATH. No real cluster or Karmada control plane is ever created --
# only tests/stubs/* are on PATH.
source_multi_libs() {
  # shellcheck disable=SC1091
  source "$FED_INFRA_ROOT/lib/common.sh"
  # shellcheck disable=SC1091
  source "$FED_INFRA_ROOT/lib/config.sh"
  # shellcheck disable=SC1091
  source "$FED_INFRA_ROOT/lib/render.sh"
  # shellcheck disable=SC1091
  source "$FED_INFRA_ROOT/lib/kind.sh"
  # shellcheck disable=SC1091
  source "$FED_INFRA_ROOT/lib/karmada.sh"
  # shellcheck disable=SC1091
  source "$FED_INFRA_ROOT/lib/kfp.sh"
  # shellcheck disable=SC1091
  source "$FED_INFRA_ROOT/lib/training.sh"
  # shellcheck disable=SC1091
  source "$FED_INFRA_ROOT/lib/temporal.sh"
  # shellcheck disable=SC1091
  source "$FED_INFRA_ROOT/lib/minio.sh"
  # shellcheck disable=SC1091
  source "$FED_INFRA_ROOT/lib/mlflow.sh"
  # shellcheck disable=SC1091
  source "$FED_INFRA_ROOT/lib/nodeport.sh"
  # shellcheck disable=SC1091
  source "$FED_INFRA_ROOT/lib/dashboard.sh"
  # shellcheck disable=SC1091
  source "$FED_INFRA_ROOT/lib/components.sh"
  fed_config_defaults
  export FED_CLUSTER_NAME=host
  export FED_NAMESPACE=demo-ns
  export FED_PROFILE=multi
  export FED_COMPONENTS=""
  export FED_KARMADA_CONFIG="$BATS_TEST_TMPDIR/.karmada/karmada-apiserver.config"
  # fed_karmada_join always resolves a Docker-network IP and patches the
  # Cluster/Secret with it, even when the cluster was already joined (see
  # lib/karmada.sh). Give it a plausible value so that path runs instead of
  # the "IP not found" fallback -- matches tests/karmada.bats's own setup.
  export STUB_DOCKER_OUT="10.0.0.5"
}

@test "fed-infra-up with all components installs kfp, minio, and mlflow" {
  write_env "kfp,minio,mlflow"
  run "$FED_INFRA_ROOT/bin/fed-infra-up" --env "$ENVFILE" --dry-run --render-dir "$RENDER"
  [ "$status" -eq 0 ]
  [ -f "$RENDER/minio.yaml" ]
  [ -f "$RENDER/mlflow-server.yaml" ]
}

@test "fed-infra-up omits minio when the component is not listed" {
  write_env "kfp,mlflow"
  run "$FED_INFRA_ROOT/bin/fed-infra-up" --env "$ENVFILE" --dry-run --render-dir "$RENDER"
  [ "$status" -eq 0 ]
  [ ! -f "$RENDER/minio.yaml" ]
  [ -f "$RENDER/mlflow-server.yaml" ]
}

@test "fed-infra-up --dry-run performs no real cluster, image, or apply side effects" {
  write_env "kfp,training,minio,mlflow,k8s-dashboard"
  run "$FED_INFRA_ROOT/bin/fed-infra-up" --env "$ENVFILE" --dry-run --render-dir "$RENDER"
  [ "$status" -eq 0 ]
  # refute_called "docker build" / "kubectl apply" do not discriminate here:
  # fed_kfp_install's "kubectl get deploy" probe and fed_mlflow_build_image's
  # "docker image inspect" probe both succeed by default in the stubs, so
  # both functions return via their "already installed/built" branch and
  # never reach the build/apply calls those two lines refute -- true whether
  # or not their own FED_DRY_RUN guard (the thing actually under test) is
  # even present. Assert the stub log is empty instead: every dry-run-guarded
  # function must return before calling any stub at all, including the
  # probes themselves, which *do* get called (and logged) once a guard is
  # missing -- see the sibling "is a complete no-op under FED_DRY_RUN=1"
  # tests in kind.bats/kfp.bats for the same idiom on a single function.
  [ -z "$(calls)" ]
  [ -f "$RENDER/minio.yaml" ]
  [ -f "$RENDER/mlflow-server.yaml" ]
  [ -f "$RENDER/dashboard-admin.yaml" ]
}

@test "fed-infra-up fails with a clear message when --env is missing" {
  run "$FED_INFRA_ROOT/bin/fed-infra-up"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--env"* ]]
}

@test "fed-infra-down deletes the configured cluster" {
  write_env "kfp"
  run "$FED_INFRA_ROOT/bin/fed-infra-down" --env "$ENVFILE"
  [ "$status" -eq 0 ]
  assert_called "kind delete cluster --name demo"
}

@test "fed-infra-down kills stale kubectl port-forwards via the stubbed pkill" {
  write_env "kfp"
  run "$FED_INFRA_ROOT/bin/fed-infra-down" --env "$ENVFILE"
  [ "$status" -eq 0 ]
  assert_called "pkill -f kubectl port-forward"
}

@test "fed_expose_nodeport patches a service to NodePort with the given ports" {
  source "$FED_INFRA_ROOT/lib/common.sh"
  source "$FED_INFRA_ROOT/lib/nodeport.sh"
  fed_expose_nodeport mysvc myns '[{"port":80,"targetPort":3000,"nodePort":30080}]'
  assert_called "kubectl patch service mysvc -n myns"
  assert_called '"type":"NodePort"'
}

# --- fed_up / fed_down: multi profile ---

@test "fed_up multi creates the host cluster and the default number of member clusters" {
  source_multi_libs
  fed_up
  assert_called "kind create cluster --name host"
  assert_called "kind create cluster --name member1"
  assert_called "kind create cluster --name member2"
  refute_called "kind create cluster --name member3"
}

@test "fed_up multi creates a custom member count with a custom prefix" {
  source_multi_libs
  export FED_MEMBER_COUNT=3 FED_MEMBER_PREFIX=worker
  fed_up
  assert_called "kind create cluster --name worker1"
  assert_called "kind create cluster --name worker2"
  assert_called "kind create cluster --name worker3"
  refute_called "kind create cluster --name worker4"
}

@test "fed_up multi creates the host cluster from a template with port mappings, unlike the members" {
  source_multi_libs
  export STUB_KIND_OUT=""
  fed_up
  # Host + 2 members all pipe their rendered config through the same
  # `kind create cluster --config -` invocation, landing in one combined
  # log, so this only proves *something* in the batch carried port mappings
  # (i.e. the host used multi-host.yaml.tpl, not member.yaml.tpl). Proving
  # members individually get none is covered precisely in tests/kind.bats.
  grep -q "extraPortMappings" "$STUB_STDIN_LOG"
}

@test "fed_up multi installs karmada on the host and joins the host and every member" {
  source_multi_libs
  fed_up
  # fed_karmada_init's context switch and namespace probe run unconditionally
  # every call, regardless of whether karmada-system already exists (it does,
  # per the kubectl stub's default success exit) -- so these prove
  # fed_karmada_init(host) ran without needing to force its "not yet
  # initialized" branch.
  assert_called "kubectl config use-context kind-host"
  assert_called "kubectl get namespace karmada-system"
  # fed_karmada_join re-resolves the Docker IP and patches the Cluster
  # object on *every* call, even an already-registered one (see
  # lib/karmada.sh) -- a far more reliable "this cluster was joined" signal
  # in these tests than asserting on `karmadactl join` itself, which the
  # default (already-registered) stub state skips, same as
  # tests/karmada.bats's own "still re-patches" test does.
  assert_called "patch cluster host --type=merge"
  assert_called "patch cluster member1 --type=merge"
  assert_called "patch cluster member2 --type=merge"
}

@test "fed_up multi waits for the host and every member to report Ready in Karmada" {
  source_multi_libs
  fed_up
  assert_called "kubectl --kubeconfig=${FED_KARMADA_CONFIG} wait --for=condition=Ready cluster/host --timeout=120s"
  assert_called "kubectl --kubeconfig=${FED_KARMADA_CONFIG} wait --for=condition=Ready cluster/member1 --timeout=120s"
  assert_called "kubectl --kubeconfig=${FED_KARMADA_CONFIG} wait --for=condition=Ready cluster/member2 --timeout=120s"
}

@test "fed_up multi loads FED_IMAGES into the host and every member cluster" {
  source_multi_libs
  export FED_IMAGES="myimg:v1"
  fed_up
  assert_called "kind load docker-image myimg:v1 --name host"
  assert_called "kind load docker-image myimg:v1 --name member1"
  assert_called "kind load docker-image myimg:v1 --name member2"
}

@test "fed_up multi installs shared components only against the host context, never a member context" {
  source_multi_libs
  export FED_COMPONENTS="minio"
  fed_up
  assert_called "kubectl config use-context kind-host"
  refute_called "kubectl config use-context kind-member1"
  refute_called "kubectl config use-context kind-member2"
  assert_called "kubectl apply -f -"
}

@test "fed_up multi switches to the host context before installing shared components" {
  source_multi_libs
  export FED_COMPONENTS="minio"
  fed_up
  local ctx_line apply_line
  ctx_line=$(grep -n "kubectl config use-context kind-host" "$STUB_LOG" | tail -1 | cut -d: -f1)
  apply_line=$(grep -n "kubectl apply -f -" "$STUB_LOG" | head -1 | cut -d: -f1)
  [ -n "$ctx_line" ]
  [ -n "$apply_line" ]
  [ "$ctx_line" -lt "$apply_line" ]
}

@test "fed_up multi with no components enabled applies no manifests" {
  source_multi_libs
  fed_up
  refute_called "kubectl apply -f -"
  refute_called "kubectl apply -k"
}

@test "fed_up installs the Kubernetes Dashboard when k8s-dashboard is listed, using FED_K8S_DASHBOARD_VERSION" {
  source_multi_libs
  export FED_COMPONENTS="k8s-dashboard" FED_K8S_DASHBOARD_VERSION=v9.9.9
  # Default stub state has 'get deployment kubernetes-dashboard' succeed
  # (i.e. already installed), which would skip the manifest apply this test
  # exists to check -- force the "not yet installed" branch.
  export STUB_KUBECTL_FAIL_ONCE_GLOB="get deployment kubernetes-dashboard*"
  fed_up
  assert_called "kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v9.9.9/aio/deploy/recommended.yaml"
  assert_called "kubectl patch service kubernetes-dashboard -n kubernetes-dashboard"
}

@test "fed_up does not install the Kubernetes Dashboard when k8s-dashboard is not listed" {
  source_multi_libs
  export FED_COMPONENTS="minio"
  fed_up
  refute_called "recommended.yaml"
  refute_called "kubernetes-dashboard"
}

@test "fed_up installs the Karmada Dashboard when karmada-dashboard is listed, wired to FED_KARMADA_CONFIG" {
  source_multi_libs
  export FED_COMPONENTS="karmada,karmada-dashboard"
  # Default stub state has 'get deployment karmada-dashboard' succeed (i.e.
  # already installed), which would skip the manifest apply this test
  # exists to check -- force the "not yet installed" branch, same idiom
  # tests/dashboard.bats and tests/karmada.bats both use.
  export STUB_KUBECTL_FAIL_ONCE_GLOB="get deployment karmada-dashboard*"
  fed_up
  assert_called "kubectl apply -f https://raw.githubusercontent.com/karmada-io/dashboard/main/deploy/karmada-dashboard.yaml"
  assert_called "create secret generic karmada-kubeconfig --from-file=karmada-kubeconfig=${FED_KARMADA_CONFIG}"
  assert_called "kubectl patch service karmada-dashboard -n karmada-system"
}

@test "fed_up does not install the Karmada Dashboard when karmada-dashboard is not listed" {
  source_multi_libs
  export FED_COMPONENTS="karmada"
  fed_up
  refute_called "karmada-dashboard.yaml"
  refute_called "karmada-kubeconfig"
}

@test "fed-infra-up multi profile is a complete no-op for real side effects under --dry-run, except rendering manifests" {
  write_multi_env "minio,mlflow,karmada,karmada-dashboard"
  run "$FED_INFRA_ROOT/bin/fed-infra-up" --env "$ENVFILE" --dry-run --render-dir "$RENDER"
  [ "$status" -eq 0 ]
  # Same non-discriminating trap as the single-profile version of this test:
  # refute_called "docker build" never fires regardless of whether
  # fed_mlflow_build_image's own FED_DRY_RUN guard is present, because its
  # "docker image inspect" probe succeeds by default in the stub. Assert the
  # stub log is empty instead -- covers docker build, the inotify-raise
  # (docker exec ... sysctl) and Karmada image pre-fetch (docker pull / kind
  # load docker-image) added for the multi profile, and karmada-dashboard's
  # own manifest apply / secret / ServiceAccount / ClusterRoleBinding calls,
  # all in one assertion that cannot miss a newly added call the way an
  # enumerated refute_called list can.
  [ -z "$(calls)" ]
  [ -f "$RENDER/minio.yaml" ]
  [ -f "$RENDER/mlflow-server.yaml" ]
}

@test "fed_down multi deletes every member cluster before the host cluster" {
  source_multi_libs
  fed_down
  assert_called "kind delete cluster --name member1"
  assert_called "kind delete cluster --name member2"
  assert_called "kind delete cluster --name host"
  local m1 m2 h
  m1=$(grep -n "kind delete cluster --name member1" "$STUB_LOG" | cut -d: -f1)
  m2=$(grep -n "kind delete cluster --name member2" "$STUB_LOG" | cut -d: -f1)
  h=$(grep -n "kind delete cluster --name host" "$STUB_LOG" | cut -d: -f1)
  [ "$m1" -lt "$h" ]
  [ "$m2" -lt "$h" ]
}

@test "fed_down multi deletes a custom member count with a custom prefix, still before the host" {
  source_multi_libs
  export FED_MEMBER_COUNT=1 FED_MEMBER_PREFIX=worker
  fed_down
  assert_called "kind delete cluster --name worker1"
  assert_called "kind delete cluster --name host"
  local w1 h
  w1=$(grep -n "kind delete cluster --name worker1" "$STUB_LOG" | cut -d: -f1)
  h=$(grep -n "kind delete cluster --name host" "$STUB_LOG" | cut -d: -f1)
  [ "$w1" -lt "$h" ]
}

@test "fed_down single profile is unaffected by FED_MEMBER_COUNT (still deletes only the configured cluster)" {
  source_multi_libs
  export FED_PROFILE=single FED_MEMBER_COUNT=2
  fed_down
  assert_called "kind delete cluster --name host"
  refute_called "kind delete cluster --name member1"
  refute_called "kind delete cluster --name member2"
}
