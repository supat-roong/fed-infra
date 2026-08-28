# fed-infra

Shared Bash library for bootstrapping local Kubernetes-based development
clusters (kind, Kubeflow Pipelines, the Kubeflow Training Operator, MLflow,
MinIO, the Kubernetes Dashboard, the Karmada Dashboard). Designed to be
consumed as a git submodule by other repositories; it holds no knowledge of
any specific consumer — see [Repo agnosticism](#repo-agnosticism) below.

## Layout

- `lib/` — sourceable Bash modules (`fed_`-prefixed functions).
- `bin/` — executable entry points (`fed-infra-up`, `fed-infra-down`).
- `manifests/`, `kind/` — Kubernetes and kind cluster configuration templates
  (`.yaml.tpl`, rendered with `envsubst`).
- `tests/` — bats test suite, with command stubs under `tests/stubs/` and
  fixture `infra.env` files / golden rendered manifests under
  `tests/fixtures/` and `tests/golden/`.

## Requirements

- Bash (targets macOS system Bash 3.2 — no associative arrays, no
  `${var,,}`, no `mapfile`).
- [bats-core](https://github.com/bats-core/bats-core) and
  [shellcheck](https://www.shellcheck.net/) for development.
- `kind`, `kubectl`, `docker`, `envsubst`, `helm` on `PATH` for actually
  bringing up a cluster (not needed just to run the test suite, which stubs
  them). `helm` is required whenever the `temporal` component is enabled
  and resolves to manifests mode (the default on arm64) — juju mode's
  `fed_temporal_install_juju` never calls `helm`.
- `juju` 3.6.x — only for `FED_DEPLOY_MODE=juju`. Homebrew's `juju` formula
  installs 4.x, which cannot deploy these charms (they assert `juju <
  4.0.0`, and Juju 4 dropped support for the pod-spec charms this stack
  uses); install a 3.6.x client from the [GitHub releases
  page](https://github.com/juju/juju/releases) instead. `fed_juju_require`
  checks this and dies with the same guidance if it's missing or the wrong
  major version. See [Deploy modes](#deploy-modes).

## Development

```bash
make check   # lint (shellcheck) + test (bats) — includes the agnosticism guard
make lint    # shellcheck only
make test    # bats only
```

Every function is prefixed `fed_` and must be idempotent — safe to run
repeatedly. Environment variables use the `FED_` prefix.

## Deploy modes

`FED_DEPLOY_MODE` (`auto` by default) picks how the `minio`, `mlflow`,
`temporal`, and `training` components get installed:

- **`manifests`** is the primary, always-works path: the bash/kustomize/Helm
  install described throughout this README. It runs on any architecture,
  arm64 included, and needs no `juju` client.
- **`juju`** installs the same four components as Charmhub charms instead
  (`lib/juju.sh`, plus each component's `_install_juju` counterpart), backed
  by `mysql-k8s` (mlflow) and `postgresql-k8s` (temporal). It needs an
  **amd64 Docker daemon** — every charm in this stack is amd64-only on
  every *stable* channel this project uses; the lone arm64 revision
  anywhere is `mysql-k8s` on `8.0/edge` (2026-08-28 arm64 spike, §4), which
  is untested here and not what `FED_MYSQL_CHANNEL` defaults to. On Apple
  Silicon that means a dedicated x86_64 Colima profile, not the default
  arm64 one. Requires the `juju` 3.6.x client — see
  [Requirements](#requirements). In juju mode, `mlflow` requires the `minio`
  component too: mlflow-server's artifact store is the `minio` charm, wired
  through the `object-storage` relation, and `fed_mlflow_install_juju` dies
  immediately if `minio` is missing from `FED_COMPONENTS`. Manifests mode has
  no such coupling — any S3-compatible endpoint at `FED_S3_ENDPOINT` works.
- **`auto`** resolves to `juju` iff `docker version --format
  '{{.Server.Arch}}'` reports `amd64`; otherwise `manifests`. kind nodes
  inherit the Docker *daemon's* architecture, not the host CPU's, so this is
  the correct signal even when the daemon itself runs a foreign-arch VM.
  `auto` never probes docker under `FED_DRY_RUN=1` (dry run performs no
  side effects at all, not even a read-only probe) and always resolves to
  `manifests` there; set `FED_DEPLOY_MODE=juju` explicitly to dry-run the
  juju command stream instead.

A few things hold regardless of mode:

- **`kfp` always uses the kustomize path**, in both modes — see the comment
  header of `lib/kfp.sh`. The kfp charm family is amd64-only on every
  Charmhub channel with no arm64 revisions anywhere, so a charm-based kfp
  stays out of scope for now.
- **`FED_PROFILE=multi` and the dashboard components
  (`k8s-dashboard`/`karmada-dashboard`) are manifests-only.** There is no
  juju equivalent for either, and `FED_DEPLOY_MODE` has no effect on them.
- **Service names differ by mode**, since manifests-mode Deployments/
  StatefulSets and juju-mode charm applications aren't the same objects —
  e.g. standalone MinIO is Service `minio-service` under manifests but
  `minio` under juju; MLflow is `mlflow-service` under manifests but
  `mlflow-server` under juju. These differences live entirely inside
  `lib/components.sh`'s per-mode branches; the NodePort/hostPort contract a
  consumer actually depends on is identical in both modes.
- **`FED_S3_ACCESS_KEY`/`FED_S3_SECRET_KEY` double as the `minio` charm's
  `access-key`/`secret-key` config** in juju mode. The charm requires
  `secret-key` to be at least 8 characters; if either variable is unset,
  `fed_minio_install_juju` warns and leaves the charm on its own random
  default rather than failing setup. See the "Consumer-supplied, no
  default" table below for the manifests-mode meaning of the same two
  variables.
- **juju's cloud, controller, and model names are derived, never
  user-set**: cloud `fed-<FED_CLUSTER_NAME>-k8s`, controller
  `fed-<FED_CLUSTER_NAME>`, and models named after the namespaces they
  back — `$FED_NAMESPACE` for `minio`/`mlflow`/`temporal`, plus the
  hardcoded `kubeflow` model when `training` is enabled (deduplicated if a
  consumer happens to set `FED_NAMESPACE=kubeflow`).

## The `infra.env` contract

A consumer configures fed-infra entirely through one file, `infra.env`, at
the consumer's repo root, plus two CLI flags. `bin/fed-infra-up` and
`bin/fed-infra-down` both take `--env <path/to/infra.env>` and `fed_config_load`
sources it, applies defaults, and validates it before anything else runs.

### Required (validated — setup dies immediately if any is missing)

| Variable | Meaning |
|---|---|
| `FED_CLUSTER_NAME` | Name passed to `kind create cluster` / `kind delete cluster`, and used to derive the kubeconfig context `kind-${FED_CLUSTER_NAME}`. |
| `FED_NAMESPACE` | Namespace fed-infra creates for the consumer's own resources: the standalone MinIO (`minio` component) and the MLflow server (`mlflow` component). Independent of `kubeflow`, the namespace KFP always installs itself into. |
| `FED_PROFILE` | Either `single` or `multi`. `single` creates one kind cluster and installs everything on it. `multi` creates a host cluster plus `FED_MEMBER_COUNT` member clusters, installs the Karmada control plane on the host, and joins every member to it; shared services still install on the host only. `multi` requires `karmada` in `FED_COMPONENTS`. |
| `FED_COMPONENTS` | Comma-separated (no spaces) list of components to install. See [FED_COMPONENTS](#fed_components) below. |

### Optional, with defaults (`fed_config_defaults`)

| Variable | Default | Meaning |
|---|---|---|
| `FED_KFP_VERSION` | `2.4.0` | Kubeflow Pipelines manifest ref (`?ref=` on the kustomize URLs) and the tag used for the ARM-friendly `ghcr.io/kubeflow/kfp-*` image patches. |
| `FED_TRAINING_OPERATOR_VERSION` | `v1.7.0` | Kubeflow Training Operator manifest ref. |
| `FED_KIND_WORKERS` | `0` | Number of extra `role: worker` nodes appended to the kind cluster (beyond the always-present control-plane node). |
| `FED_POD_READY_ATTEMPTS` | `30` | How many times to poll for a pod to become ready before giving up (~17 minutes at the default delay). Raise it on a slow machine, or for a cold `multi` bring-up where three kind clusters pull the whole KFP image set at once. A high ceiling costs nothing when things are healthy — polling returns on the first success. |
| `FED_RETRY_DELAY` | `5` | Seconds between retry attempts. |
| `FED_MLFLOW_VERSION` | `2.12.2` | Upstream `ghcr.io/mlflow/mlflow` tag the local MLflow image is built `FROM`. |
| `FED_MLFLOW_IMAGE` | `fed-mlflow:${FED_MLFLOW_VERSION}` | Local image tag built by `fed_mlflow_build_image` (adds `boto3` on top of upstream MLflow) and loaded into kind. |
| `FED_IMAGES` | `` (empty) | Space-separated list of consumer-built images (e.g. a worker/aggregator image) to `kind load docker-image` into the cluster. fed-infra does not build these — the consumer builds them before calling `fed-infra-up`. |
| `FED_S3_BUCKET` | `mlflow-artifacts` | Bucket name `fed_minio_ensure_bucket` creates for MLflow's artifact store. |
| `FED_NODEPORT_KFP` | `30080` | Node port the KFP UI Service (`ml-pipeline-ui`) is patched to expose. |
| `FED_NODEPORT_MLFLOW` | `30500` | Node port the MLflow Service is created with. |
| `FED_NODEPORT_MINIO_API` | `30900` | Node port the standalone MinIO S3 API is exposed on. |
| `FED_NODEPORT_MINIO_CONSOLE` | `30901` | Node port the standalone MinIO web console is exposed on. |
| `FED_HOSTPORT_KFP` | `8080` | Host port mapped (via the kind cluster's `extraPortMappings`) to `FED_NODEPORT_KFP`. This is the port you actually browse to. |
| `FED_HOSTPORT_MLFLOW` | `5050` | Host port mapped to `FED_NODEPORT_MLFLOW`. |
| `FED_HOSTPORT_MINIO_API` | `9000` | Host port mapped to `FED_NODEPORT_MINIO_API`. |
| `FED_HOSTPORT_MINIO_CONSOLE` | `9001` | Host port mapped to `FED_NODEPORT_MINIO_CONSOLE`. |
| `FED_DRY_RUN` | `0` | Set to `1` to render manifests and log intended actions without touching Docker/kind/kubectl. See [Dry run](#dry-run). |
| `FED_RENDER_DIR` | `` (empty) | Output directory for rendered manifests when `FED_DRY_RUN=1`. Required in that mode — `fed_apply` dies if it's unset. |
| `FED_DEPLOY_MODE` | `auto` | `auto` \| `manifests` \| `juju`. See [Deploy modes](#deploy-modes). |
| `FED_MINIO_CHANNEL` | `ckf-1.9/stable` | **juju mode only.** Charmhub channel for the `minio` charm (`fed_minio_install_juju`). |
| `FED_MYSQL_CHANNEL` | `8.0/stable` | **juju mode only.** Charmhub channel for the `mysql-k8s` charm backing `mlflow-server` (`fed_mlflow_install_juju`). |
| `FED_MYSQL_PROFILE` | `testing` | **juju mode only.** mysql-k8s `profile` config applied at deploy time. `testing` sizes mysqld for local dev/kind clusters; the charm's own `production` default sizes itself for real hardware and has been observed stalling in "Initialising mysqld" on kind. Set `production` only on machine-grade nodes. |
| `FED_MLFLOW_CHANNEL` | `2.15/stable` | **juju mode only.** Charmhub channel for the `mlflow-server` charm. |
| `FED_POSTGRESQL_CHANNEL` | `14/stable` | **juju mode only.** Charmhub channel for the `postgresql-k8s` charm backing Temporal (`fed_temporal_install_juju`). |
| `FED_TEMPORAL_CHANNEL` | `1.23/stable` | **juju mode only.** Charmhub channel for the `temporal-k8s` charm. No `latest` track exists for this charm family. |
| `FED_TEMPORAL_ADMIN_CHANNEL` | `1.23/stable` | **juju mode only.** Charmhub channel for the `temporal-admin-k8s` charm. |
| `FED_TEMPORAL_UI_CHANNEL` | `1.23/stable` | **juju mode only.** Charmhub channel for the `temporal-ui-k8s` charm. |
| `FED_TRAINING_CHANNEL` | `1.8/stable` | **juju mode only.** Charmhub channel for the `training-operator` charm (`fed_training_install_juju`). |
| `FED_TEMPORAL_NUM_HISTORY_SHARDS` | `4` | **juju mode only.** The `temporal-k8s` charm's `num-history-shards` config, which has no charm-side default — the charm stays `blocked` until it is set to a positive power of 2. **Schema-locked:** Temporal pins the shard count permanently when the schema is first initialized, so this can only be chosen on the *first* bring-up; changing it later has no effect and requires destroying and recreating the deployment. `4` suits a single-node local cluster — raise it up front for anything larger. |

### Consumer-supplied, no default (required in practice, not schema-enforced)

These are only read when the relevant component is enabled, so
`fed_config_validate` does not require them unconditionally — but setup will
fail partway through if they're missing and needed:

| Variable | Used by | Meaning |
|---|---|---|
| `FED_S3_ENDPOINT` | `mlflow` only, **manifests mode only** — rendered into the MLflow Deployment's env and read again by mlflow's own post-install bucket step (`fed_minio_ensure_bucket`); juju mode hardcodes the minio charm's in-cluster Service address instead and never reads this variable. **Not** read by kfp's post-install bucket step in either mode — that step always hardcodes KFP's own bundled-minio defaults (`minio`/`minio123`), never `FED_S3_*`. | `host:port` of the S3-compatible store backing MLflow's artifact root — this can be the consumer's own standalone MinIO (`minio-service.<FED_NAMESPACE>...`) or a shared one (e.g. KFP's own bundled MinIO in `kubeflow`). `fed_config_validate` requires it whenever `mlflow` is enabled regardless of `FED_DEPLOY_MODE`, since the effective mode (relevant for `auto`) isn't known until later — so it must be set even for a consumer that expects to land in juju mode. |
| `FED_S3_ACCESS_KEY` / `FED_S3_SECRET_KEY` | `minio` and `mlflow`, in manifests mode; `minio` only, in juju mode | In manifests mode: `minio`'s own root credentials (`MINIO_ROOT_USER`/`MINIO_ROOT_PASSWORD`), and — paired with `FED_S3_ENDPOINT` above — credentials for `mlflow`'s Deployment env and its `mc`-based bucket-provisioning step. In juju mode: these double as the `minio` charm's `access-key`/`secret-key` config (`fed_minio_install_juju`) — the charm requires `secret-key` to be at least 8 characters; if either variable is unset, the charm keeps its own random default instead of failing setup. juju-mode `mlflow` never reads these directly; it gets credentials from the minio charm via the `object-storage` relation instead. See [Deploy modes](#deploy-modes). |

### Internal / derived (never set in `infra.env`)

| Variable | Meaning |
|---|---|
| `FED_INFRA_ROOT` | Exported by `bin/fed-infra-up` / `fed-infra-down` as the absolute path of the checked-out submodule; used to locate `lib/`, `kind/`, `manifests/`. |
| `FED_KFP_NAMESPACE` | Hardcoded to `kubeflow` in `lib/kfp.sh` — upstream KFP always installs into that namespace regardless of `FED_NAMESPACE`. |
| `FED_K8S_DASHBOARD_NAMESPACE` | Hardcoded to `kubernetes-dashboard` in `lib/dashboard.sh` — upstream's `recommended.yaml` always installs into that namespace. |
| `FED_KARMADA_DASHBOARD_NAMESPACE` | Hardcoded to `karmada-system` in `lib/dashboard.sh`. |
| `FED_KARMADA_ADMIN_SA` | Hardcoded to `karmada-admin-sa` in `lib/dashboard.sh` — the ServiceAccount `fed_karmada_dashboard_install` creates against the Karmada apiserver for `fed_dashboard_token` to mint a login token for. |
| `FED_ARGOEXEC_IMAGE` | Hardcoded pinned `argoexec` image used when patching `workflow-controller` for ARM/kind stability. |
| `FED_KIND_CRICTL_OUT` | Test-only seam so bats can stub `crictl images` output; never set outside `tests/`. |
| `FED_REQUIRED_VARS`, `FED_TEMPLATE_VARS` | Internal lists consumed by `fed_config_validate` and `fed_render`; not meant to be overridden by consumers. |

## `FED_COMPONENTS`

A comma-separated subset of
`kfp,training,minio,mlflow,temporal,karmada,k8s-dashboard,karmada-dashboard`,
checked with a whole-token match (`fed_has_component`), so order doesn't
matter but there must be no spaces around the commas. Each token turns on:

- **`kfp`** — Installs Kubeflow Pipelines at `FED_KFP_VERSION` (cluster-scoped
  resources, then the platform-agnostic core) into the `kubeflow` namespace;
  patches `ml-pipeline`, `ml-pipeline-ui`, `ml-pipeline-visualizationserver`,
  and `workflow-controller` to ARM/kind-friendly images, since upstream's
  `gcr.io` images are amd64-only or no longer served; patches KFP's *own
  bundled* MinIO deployment (image, container ports, args) idempotently;
  waits for all four core deployments to roll out; provisions the
  `mlpipeline` bucket on that bundled MinIO; and exposes `ml-pipeline-ui` as
  a NodePort on `FED_NODEPORT_KFP` (reachable on the host at
  `FED_HOSTPORT_KFP`).
- **`training`** — Installs the Kubeflow Training Operator at
  `FED_TRAINING_OPERATOR_VERSION` (standalone overlay), which registers the
  `pytorchjobs.kubeflow.org` CRD, then waits for the CRD to become
  `Established` and for the operator pod to become ready.
- **`minio`** — Installs a *standalone* MinIO (separate from KFP's bundled
  one) as a StatefulSet + ClusterIP Service into `FED_NAMESPACE`, waits for
  its rollout, and exposes it as a NodePort on `FED_NODEPORT_MINIO_API` /
  `FED_NODEPORT_MINIO_CONSOLE`.
- **`mlflow`** — Builds a local image (`FED_MLFLOW_IMAGE`, upstream MLflow
  plus `boto3`), loads it into the kind cluster, deploys the MLflow tracking
  server + PVC + NodePort Service into `FED_NAMESPACE`, and — once the
  cluster is up — ensures the `FED_S3_BUCKET` bucket exists at
  `FED_S3_ENDPOINT`. That endpoint can point at the consumer's own `minio`
  component or at a shared store such as KFP's bundled MinIO; fed-infra
  doesn't care which, it only reads `FED_S3_*`.
- **`temporal`** — Deploys a Postgres instance plus the Temporal server and
  Web UI (chart version `FED_TEMPORAL_VERSION`) into `FED_NAMESPACE`, and
  exposes the UI as a NodePort on `FED_NODEPORT_TEMPORAL_UI` (reachable on
  the host at `FED_HOSTPORT_TEMPORAL_UI`).
- **`karmada`** — Only meaningful under `FED_PROFILE=multi`, where it is
  **required**: `fed_config_validate` rejects a `multi` contract that omits
  it. Installs the Karmada control plane (`FED_KARMADA_VERSION`) on the host
  cluster, writes its kubeconfig to `FED_KARMADA_CONFIG`, and joins the host
  and every member cluster, re-patching each member's Docker-network address
  on every run. Note the asymmetry with the other tokens: the `multi` profile
  drives the Karmada steps directly, so this entry is a declaration the
  contract must make rather than a switch that turns the work on and off —
  a `multi` contract without it fails fast instead of silently getting
  Karmada anyway.
- **`k8s-dashboard`** — Installs the upstream Kubernetes Dashboard
  (`FED_K8S_DASHBOARD_VERSION`) plus a `dashboard-admin` ServiceAccount bound
  to `cluster-admin` (`manifests/dashboard-admin.yaml.tpl`, namespaced by
  `FED_NAMESPACE`), and exposes it as a NodePort on
  `FED_NODEPORT_K8S_DASHBOARD` (reachable on the host at
  `FED_HOSTPORT_K8S_DASHBOARD`). Works under either profile. Get a login
  token with `fed_dashboard_token "$FED_NAMESPACE" dashboard-admin`. See
  [Dashboard access](#dashboard-access) for the security note on why a
  cluster-admin binding is acceptable here.
- **`karmada-dashboard`** — Only meaningful under `FED_PROFILE=multi`.
  Installs the Karmada Dashboard onto the host cluster, wires it to the
  Karmada control plane via a `karmada-kubeconfig` Secret (in both
  `karmada-system` and `kubeflow`), grants a `karmada-admin-sa`
  ServiceAccount cluster-admin against the Karmada apiserver itself, and
  exposes the dashboard as a NodePort on `FED_NODEPORT_KARMADA_DASHBOARD`
  (reachable on the host at `FED_HOSTPORT_KARMADA_DASHBOARD`). Get a login
  token with `KUBECONFIG="$FED_KARMADA_CONFIG" fed_dashboard_token
  karmada-system karmada-admin-sa`.

Within `fed_up`, components run in a fixed order: create/reuse the kind
cluster → `kfp` install + patches → `training` → `minio` → `mlflow`
(build image, load image, install) → `k8s-dashboard` → `karmada-dashboard`
→ load any consumer `FED_IMAGES` → `kfp` wait + bucket + NodePort →
`mlflow` bucket → `minio` NodePort → `k8s-dashboard` NodePort.

## Dashboard access

Both dashboard components grant their access ServiceAccount cluster-admin —
`k8s-dashboard` via `manifests/dashboard-admin.yaml.tpl`, `karmada-dashboard`
via a ServiceAccount created directly against the Karmada apiserver. This is
a **local-development convenience only**: the Kubernetes/Karmada Dashboards
otherwise carry no usable RBAC of their own, and a cluster-admin binding is
what makes `fed_dashboard_token` (below) hand out a token that actually
authenticates. Never do this against a shared or production cluster — it is
appropriate here only because the target is always an ephemeral local kind
cluster.

`fed_dashboard_token <namespace> <service_account>` mints a 24h token
(`kubectl create token`) and prints it on stdout only — never through
`fed_log`, so it cannot end up in a redirected log file. It takes no
kubeconfig/context argument: it relies entirely on the caller's ambient
kubectl context (or `$KUBECONFIG`), which is the host cluster's current
context for `k8s-dashboard` and requires
`KUBECONFIG="$FED_KARMADA_CONFIG"` for `karmada-dashboard`, since that
ServiceAccount lives inside the Karmada control plane's own apiserver.

Two illustrative `infra.env` shapes (matching `tests/fixtures/*.env`):

- A consumer that owns its own MinIO: `FED_COMPONENTS=kfp,training,minio,mlflow`,
  `FED_NAMESPACE` distinct from `kubeflow`, `FED_S3_ENDPOINT` pointing at that
  namespace's `minio-service`.
- A consumer that reuses KFP's bundled MinIO instead of running its own:
  `FED_COMPONENTS=kfp,training,mlflow` (no `minio`), `FED_NAMESPACE=kubeflow`,
  `FED_S3_ENDPOINT=minio-service.kubeflow.svc.cluster.local:9000`.

## Repo agnosticism

fed-infra must never contain a consumer-specific string: no consumer repo
name, product name, or business-specific identifier may appear anywhere in
this tree (this README included — the examples above deliberately use
placeholder names, the same ones the test fixtures use, rather than a real
project's name). `tests/agnostic.bats` enforces this by grepping the whole
repository, excluding `.git` and itself, for the known consumer identifiers
and failing `make check` if any are found.

This matters because fed-infra is vendored unmodified, as a pinned git
submodule, by multiple unrelated projects. Every point of contact with a
particular consumer has to flow through data — `infra.env` and `FED_*`
environment variables — rather than through a hardcoded string or
conditional. If the library ever special-cased a consumer's name, a fix or
tweak made for that consumer could silently change behavior for every other
consumer sharing the same pinned commit, and there would be no single place
left where "does this repo know about anyone in particular?" could be
answered by a single grep. The rule keeps the library boring, reusable, and
safe to bump independently in each consumer.

## Dry run

`FED_DRY_RUN=1` (or `--dry-run`) makes every mutating call — `kind create`,
`kind load docker-image`, `docker build`, `kubectl apply`, `kubectl patch`,
`kubectl wait` — a no-op that only logs what it would have done. Manifests
that would normally be applied are instead rendered with `envsubst` and
written to `FED_RENDER_DIR/<label>.yaml` (`namespace.yaml`, `minio.yaml`,
`mlflow-server.yaml`, `dashboard-admin.yaml` when `k8s-dashboard` is
enabled) so they can be inspected or diffed against `tests/golden/`.
`FED_RENDER_DIR` must be set whenever dry-run is on, or `fed_apply` dies
immediately. `karmada-dashboard` has no local template of its own (it
applies an upstream manifest directly), so it renders nothing and is a
complete no-op under dry-run, same as `karmada` itself.

```bash
vendor/fed-infra/bin/fed-infra-up \
  --env infra.env \
  --dry-run \
  --render-dir /tmp/fed-infra-render

ls /tmp/fed-infra-render
```

## Usage

```bash
# Bring the cluster + components up (idempotent — safe to re-run)
vendor/fed-infra/bin/fed-infra-up --env infra.env

# Tear everything down
vendor/fed-infra/bin/fed-infra-down --env infra.env
```

Consumers typically wrap these in their own `setup/install_*.sh` /
`setup/teardown_*.sh` scripts (to build and load their own images first) and
expose them as `make` targets — see either consumer's `Makefile` and
`setup/` directory for the pattern.

## Consumers: pinning and bumping the SHA

Consumers vendor this repo as a git submodule at `vendor/fed-infra`, pinned
to an exact commit SHA — never a branch or tag — so a change here can never
silently change a consumer's behavior until that consumer explicitly opts
in.

**Initial checkout / after cloning a consumer repo:**

```bash
git submodule update --init --recursive
```

This checks `vendor/fed-infra` out at the SHA recorded in the consumer's git
index — no separate version file to keep in sync.

**Bumping a consumer to a newer fed-infra commit:**

```bash
cd vendor/fed-infra
git fetch origin
git checkout <new-sha>          # or: git checkout origin/main -- for latest
cd ../..
git add vendor/fed-infra
git commit -m "chore: bump vendor/fed-infra to <short-sha> (<why>)"
```

**Checking what's currently pinned:**

```bash
git submodule status vendor/fed-infra
```

A leading space means the working tree matches the pinned SHA; a leading
`+` means it's checked out at some other commit (someone moved it without
committing); a leading `-` means the submodule hasn't been initialized yet.

## Nightly cross-repo contract check

A nightly-only `consumer-contracts` job in `.github/workflows/ci.yml` fetches
each consumer's real `infra.env` contracts at runtime and renders them
against this repo's current `main`, so a library change that breaks a
consumer fails here — in the repo that caused it — instead of surfacing
days later as a confusing failure in that consumer's own submodule bump.

The consumer list cannot live in the workflow file itself (see
[Repo agnosticism](#repo-agnosticism)), so it is configured out-of-band as a
repository variable:

- **Name:** `CONSUMER_CONTRACT_REPOS` (Settings → Secrets and variables →
  Actions → Variables).
- **Shape:** a JSON array of objects, each `{"repo": "<owner>/<name>",
  "envs": "<space-separated env files>"}`, e.g.:

  ```json
  [
    { "repo": "OWNER/CONSUMER_ONE", "envs": "infra.env infra.env.multi" },
    { "repo": "OWNER/CONSUMER_TWO", "envs": "infra.env infra.env.multi" }
  ]
  ```

- **If unset:** the `consumer-contracts` job's `if:` condition evaluates
  false and it shows as *skipped* in the Actions run, not failed — a fork
  simply doesn't get the cross-repo check until someone sets the variable
  there. It does not need to be set for `make check` or the regular per-PR
  CI jobs to pass.
- **On the origin repo:** a sibling `consumer-contracts-guard` job runs on
  the same schedule/dispatch triggers (but never on a fork) and fails the
  workflow if the variable is unset. This is what keeps an accidentally
  cleared variable from silently degrading the nightly run to green having
  verified nothing — the same failure shape `consumer-contracts` itself
  guards against one level further in (see the "silent-pass" checks inside
  that job).
