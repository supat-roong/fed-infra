# fed-infra

Shared Bash library for bootstrapping local Kubernetes-based development
clusters (kind, Kubeflow Pipelines, the Kubeflow Training Operator, MLflow,
MinIO). Designed to be consumed as a git submodule by other repositories; it
holds no knowledge of any specific consumer — see
[Repo agnosticism](#repo-agnosticism) below.

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
- `kind`, `kubectl`, `docker`, `envsubst` on `PATH` for actually bringing up
  a cluster (not needed just to run the test suite, which stubs them).

## Development

```bash
make check   # lint (shellcheck) + test (bats) — includes the agnosticism guard
make lint    # shellcheck only
make test    # bats only
```

Every function is prefixed `fed_` and must be idempotent — safe to run
repeatedly. Environment variables use the `FED_` prefix.

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

### Consumer-supplied, no default (required in practice, not schema-enforced)

These are only read when the relevant component is enabled, so
`fed_config_validate` does not require them unconditionally — but setup will
fail partway through if they're missing and needed:

| Variable | Used by | Meaning |
|---|---|---|
| `FED_S3_ENDPOINT` | `mlflow`, and the post-install bucket step for both `mlflow` and `kfp` | `host:port` of the S3-compatible store backing MLflow's artifact root — this can be the consumer's own standalone MinIO (`minio-service.<FED_NAMESPACE>...`) or a shared one (e.g. KFP's own bundled MinIO in `kubeflow`). |
| `FED_S3_ACCESS_KEY` / `FED_S3_SECRET_KEY` | same as above | Credentials for that endpoint. Rendered into the MLflow Deployment's env and used by the `mc`-based bucket-provisioning pod. |

### Internal / derived (never set in `infra.env`)

| Variable | Meaning |
|---|---|
| `FED_INFRA_ROOT` | Exported by `bin/fed-infra-up` / `fed-infra-down` as the absolute path of the checked-out submodule; used to locate `lib/`, `kind/`, `manifests/`. |
| `FED_KFP_NAMESPACE` | Hardcoded to `kubeflow` in `lib/kfp.sh` — upstream KFP always installs into that namespace regardless of `FED_NAMESPACE`. |
| `FED_ARGOEXEC_IMAGE` | Hardcoded pinned `argoexec` image used when patching `workflow-controller` for ARM/kind stability. |
| `FED_KIND_CRICTL_OUT` | Test-only seam so bats can stub `crictl images` output; never set outside `tests/`. |
| `FED_REQUIRED_VARS`, `FED_TEMPLATE_VARS` | Internal lists consumed by `fed_config_validate` and `fed_render`; not meant to be overridden by consumers. |

## `FED_COMPONENTS`

A comma-separated subset of `kfp,training,minio,mlflow,temporal,karmada`,
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

Within `fed_up`, components run in a fixed order: create/reuse the kind
cluster → `kfp` install + patches → `training` → `minio` → `mlflow`
(build image, load image, install) → load any consumer `FED_IMAGES` →
`kfp` wait + bucket + NodePort → `mlflow` bucket → `minio` NodePort.

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
`mlflow-server.yaml`) so they can be inspected or diffed against
`tests/golden/`. `FED_RENDER_DIR` must be set whenever dry-run is on, or
`fed_apply` dies immediately.

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
