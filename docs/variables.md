# Variable reference

Every `FED_*` variable read from `infra.env`. See the
[README](../README.md#configuration) for how configuration is loaded, and
the [Deploy modes](../README.md#deploy-modes) and
[Components](../README.md#components) sections for context.

## Required

Setup fails immediately if any of these is missing:

| Variable | Meaning |
|---|---|
| `FED_CLUSTER_NAME` | kind cluster name; also derives the kubeconfig context `kind-${FED_CLUSTER_NAME}`. |
| `FED_NAMESPACE` | Namespace for the consumer's own resources (standalone MinIO, MLflow server). KFP always installs into `kubeflow` regardless. |
| `FED_PROFILE` | `single` (one cluster) or `multi` (host cluster + `FED_MEMBER_COUNT` members joined via Karmada; shared services install on the host only). `multi` requires `karmada` in `FED_COMPONENTS`. |
| `FED_COMPONENTS` | Comma-separated component list, no spaces. See [Components](../README.md#components). |

## Optional, with defaults

| Variable | Default | Meaning |
|---|---|---|
| `FED_KFP_VERSION` | `2.4.0` | KFP manifest ref and ARM image-patch tag. Manifests mode only; juju mode uses `FED_KFP_CHANNEL`. |
| `FED_TRAINING_OPERATOR_VERSION` | `v1.7.0` | Training Operator manifest ref. |
| `FED_KIND_WORKERS` | `0` | Extra worker nodes beyond the control-plane node. |
| `FED_POD_READY_ATTEMPTS` | `30` | Pod-readiness poll attempts (about 17 min at the default delay). Raise on slow machines or a cold `multi` bring-up; a high ceiling costs nothing when healthy. |
| `FED_RETRY_DELAY` | `5` | Seconds between retries. |
| `FED_MLFLOW_VERSION` | `2.12.2` | Upstream MLflow image tag the local image builds `FROM`. |
| `FED_MLFLOW_IMAGE` | `fed-mlflow:${FED_MLFLOW_VERSION}` | Local MLflow image (upstream + `boto3`), built by `fed_mlflow_build_image` and loaded into kind. |
| `FED_MINIO_IMAGE` | `docker.io/pgsty/minio:RELEASE.2026-08-04T00-00-00Z` | MinIO server image, used for both the standalone StatefulSet and KFP's bundled MinIO. Pinned, and a community rebuild because the official `minio/minio` images on Docker Hub and quay.io no longer serve anonymous pulls. Override to point at a mirror. |
| `FED_MC_IMAGE` | `docker.io/pgsty/mc:RELEASE.2026-09-16T00-00-00Z` | MinIO client image used by the short-lived bucket-creation pod. Same pinning and registry rationale as `FED_MINIO_IMAGE`. |
| `FED_IMAGES` | (empty) | Space-separated consumer-built images to `kind load` into the cluster. The consumer builds them before calling `fed-infra-up`. |
| `FED_IMAGE_ARCHIVE` | (empty) | Path to an OCI image tar (as written by `fed_kind_export_images`) imported into every node of a newly created kind cluster, so those images are never pulled. A cache, not a requirement: a missing file or failed import only warns. Not re-imported into an existing cluster. Setting it also makes a newly created cluster keep unpacked image layers (kind discards them by default), which costs node disk but is what lets `fed_kind_export_images` export pulled images. |
| `FED_S3_BUCKET` | `mlflow-artifacts` | Bucket created for MLflow's artifact store. |
| `FED_NODEPORT_KFP` | `30080` | NodePort for the KFP UI. |
| `FED_NODEPORT_MLFLOW` | `30500` | NodePort for the MLflow UI. |
| `FED_NODEPORT_MINIO_API` | `30900` | NodePort for the standalone MinIO S3 API. |
| `FED_NODEPORT_MINIO_CONSOLE` | `30901` | NodePort for the standalone MinIO console. |
| `FED_HOSTPORT_KFP` | `8080` | Host port mapped to `FED_NODEPORT_KFP`; the port you browse to. |
| `FED_HOSTPORT_MLFLOW` | `5050` | Host port mapped to `FED_NODEPORT_MLFLOW`. |
| `FED_HOSTPORT_MINIO_API` | `9000` | Host port mapped to `FED_NODEPORT_MINIO_API`. |
| `FED_HOSTPORT_MINIO_CONSOLE` | `9001` | Host port mapped to `FED_NODEPORT_MINIO_CONSOLE`. |
| `FED_DRY_RUN` | `0` | Set to `1` to render manifests and log actions without touching Docker/kind/kubectl. See [Dry run](../README.md#dry-run). |
| `FED_RENDER_DIR` | (empty) | Output directory for rendered manifests. Required when `FED_DRY_RUN=1`. |
| `FED_DEPLOY_MODE` | `auto` | `auto` \| `manifests` \| `juju`. See [Deploy modes](../README.md#deploy-modes). |

## Juju mode only

Charmhub channels and charm config, read only when the effective deploy mode
is `juju`:

| Variable | Default | Meaning |
|---|---|---|
| `FED_MINIO_CHANNEL` | `ckf-1.9/stable` | `minio` charm. |
| `FED_MYSQL_CHANNEL` | `8.0/stable` | `mysql-k8s` charm backing `mlflow-server`. |
| `FED_MYSQL_PROFILE` | `testing` | mysql-k8s `profile` config. `testing` sizes mysqld for local kind clusters; the charm's `production` default has been observed stalling in "Initialising mysqld" on kind. |
| `FED_MLFLOW_CHANNEL` | `2.15/stable` | `mlflow-server` charm. |
| `FED_POSTGRESQL_CHANNEL` | `14/stable` | `postgresql-k8s` charm backing Temporal. |
| `FED_TEMPORAL_CHANNEL` | `1.23/stable` | `temporal-k8s` charm. No `latest` track exists for this family. |
| `FED_TEMPORAL_ADMIN_CHANNEL` | `1.23/stable` | `temporal-admin-k8s` charm. |
| `FED_TEMPORAL_UI_CHANNEL` | `1.23/stable` | `temporal-ui-k8s` charm. |
| `FED_TRAINING_CHANNEL` | `1.8/stable` | `training-operator` charm. |
| `FED_KFP_CHANNEL` | `2.15/stable` | Every `kfp-*` charm. (Manifests mode uses `FED_KFP_VERSION`.) |
| `FED_MLMD_CHANNEL` | `ckf-1.10/stable` | `mlmd` metadata store backing kfp. |
| `FED_ENVOY_CHANNEL` | `2.4/stable` | `envoy` charm (grpc-web front for mlmd). |
| `FED_ARGO_CHANNEL` | `3.7/stable` | `argo-controller` workflow engine backing kfp. |
| `FED_*_REVISION` | see below | Charmhub revision pinned for each charm (amd64). |
| `FED_TEMPORAL_NUM_HISTORY_SHARDS` | `4` | `temporal-k8s` `num-history-shards` config (must be a positive power of 2; the charm stays `blocked` without it). **Schema-locked**: Temporal pins the shard count permanently at first schema init, so choose it on the *first* bring-up; changing it later requires destroying and recreating the deployment. `4` suits a single-node local cluster. |

### Charm revisions

A channel is a moving pointer, so each charm is also pinned to a revision.
The revision fixes both the charm code and the OCI images it bundles by
digest. A pin applies only while its channel is left at the default: if you
override a channel, its revisions go empty and float on the new channel
unless you set them too. Set a revision to an empty value (e.g.
`FED_MYSQL_REVISION=`) to float on the default channel instead.

| Variable | Default | Charm (channel) |
|---|---|---|
| `FED_MINIO_REVISION` | `383` | `minio` (`FED_MINIO_CHANNEL`), both the standalone app and `kfp-minio` |
| `FED_MYSQL_REVISION` | `423` | `mysql-k8s` (`FED_MYSQL_CHANNEL`), both `mlflow-mysql` and `kfp-db` |
| `FED_MLFLOW_REVISION` | `762` | `mlflow-server` |
| `FED_POSTGRESQL_REVISION` | `925` | `postgresql-k8s` |
| `FED_TEMPORAL_REVISION` | `68` | `temporal-k8s` |
| `FED_TEMPORAL_ADMIN_REVISION` | `28` | `temporal-admin-k8s` |
| `FED_TEMPORAL_UI_REVISION` | `31` | `temporal-ui-k8s` |
| `FED_TRAINING_REVISION` | `545` | `training-operator` |
| `FED_KFP_API_REVISION` | `2557` | `kfp-api` (`FED_KFP_CHANNEL`) |
| `FED_KFP_PERSISTENCE_REVISION` | `2568` | `kfp-persistence` (`FED_KFP_CHANNEL`) |
| `FED_KFP_SCHEDWF_REVISION` | `2575` | `kfp-schedwf` (`FED_KFP_CHANNEL`) |
| `FED_KFP_VIEWER_REVISION` | `2598` | `kfp-viewer` (`FED_KFP_CHANNEL`) |
| `FED_KFP_VIZ_REVISION` | `2513` | `kfp-viz` (`FED_KFP_CHANNEL`) |
| `FED_KFP_UI_REVISION` | `2575` | `kfp-ui` (`FED_KFP_CHANNEL`) |
| `FED_KFP_METADATA_WRITER_REVISION` | `1623` | `kfp-metadata-writer` (`FED_KFP_CHANNEL`) |
| `FED_MLMD_REVISION` | `441` | `mlmd` |
| `FED_ENVOY_REVISION` | `576` | `envoy` |
| `FED_ARGO_REVISION` | `939` | `argo-controller` |

## Consumer-supplied, no default

These are only read when the relevant component is enabled, so they aren't
validated unconditionally, but setup fails partway through if they're
missing and needed:

| Variable | Meaning |
|---|---|
| `FED_S3_ENDPOINT` | `host:port` of the S3 store backing MLflow's artifact root: the consumer's own standalone MinIO or a shared one (e.g. KFP's bundled MinIO). Manifests mode only; juju mode hardcodes the minio charm's in-cluster address instead. Still **required whenever `mlflow` is enabled**, even if you expect to land in juju mode, because the effective mode isn't known at validation time. Never read by kfp's bucket step, which always uses KFP's bundled-minio defaults (`minio`/`minio123`). |
| `FED_S3_ACCESS_KEY` / `FED_S3_SECRET_KEY` | Manifests mode: MinIO's root credentials, and the credentials MLflow uses for its Deployment env and bucket provisioning. Juju mode: passed to the `minio` charm as `access-key`/`secret-key` config (`secret-key` must be at least 8 characters); if unset, the charm keeps its own random default and setup continues with a warning. Juju-mode `mlflow` never reads these; it gets credentials from the minio charm via the `object-storage` relation. |

## Internal / derived (never set in `infra.env`)

| Variable | Meaning |
|---|---|
| `FED_INFRA_ROOT` | Absolute path of the checked-out submodule, exported by `bin/fed-infra-up`/`-down`. |
| `FED_KFP_NAMESPACE` | Hardcoded `kubeflow`; upstream KFP always installs there. |
| `FED_K8S_DASHBOARD_NAMESPACE` | Hardcoded `kubernetes-dashboard` (upstream's `recommended.yaml`). |
| `FED_KARMADA_DASHBOARD_NAMESPACE` | Hardcoded `karmada-system`. |
| `FED_KARMADA_ADMIN_SA` | Hardcoded `karmada-admin-sa`, the ServiceAccount used to mint Karmada Dashboard login tokens. |
| `FED_ARGOEXEC_IMAGE` | Pinned `argoexec` image used when patching `workflow-controller` for ARM/kind stability. |
| `FED_KIND_CRICTL_OUT` | Test-only seam for stubbing `crictl images`; never set outside `tests/`. |
| `FED_REQUIRED_VARS`, `FED_TEMPLATE_VARS` | Internal lists for validation and rendering; not for consumers. |
