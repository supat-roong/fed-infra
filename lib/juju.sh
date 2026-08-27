#!/usr/bin/env bash
# juju.sh — the juju deploy mode: cloud/controller/model lifecycle for the
# kind cluster, plus the mode resolver. All juju-mode code is additive; the
# manifests mode never calls anything here.

fed_juju_cloud_name()      { printf 'fed-%s-k8s' "$FED_CLUSTER_NAME"; }
fed_juju_controller_name() { printf 'fed-%s' "$FED_CLUSTER_NAME"; }

# Resolve the effective deploy mode. `auto` keys off the Docker daemon's
# server architecture — kind nodes inherit the daemon's arch, so it (not the
# host CPU: an arm64 laptop can drive an x86_64 Colima profile) decides
# whether the amd64-only charm stack can run (see the 2026-08-28 spike
# findings). No docker / unknown arch resolves to manifests, the
# always-works default.
fed_deploy_mode() {
  case "${FED_DEPLOY_MODE:-auto}" in
    manifests|juju) printf '%s' "$FED_DEPLOY_MODE"; return 0 ;;
  esac
  # A dry run performs no side effects at all — not even the read-only docker
  # probe (tests assert an empty stub log). `auto` therefore renders the
  # manifests contract under --dry-run; set FED_DEPLOY_MODE=juju explicitly
  # to dry-run the juju command stream.
  if [ "${FED_DRY_RUN:-0}" = "1" ]; then printf 'manifests'; return 0; fi
  local arch
  arch=$(docker version --format '{{.Server.Arch}}' 2>/dev/null) || arch=""
  if [ "$arch" = "amd64" ]; then printf 'juju'; else printf 'manifests'; fi
}

# Charms in this stack assert `juju < 4.0.0`, and Juju 4 dropped pod-spec
# support (minio deploys inert). brew's juju is 4.x — see spike findings §1.
fed_juju_require() {
  fed_require_cmd juju
  local ver
  ver=$(juju version 2>/dev/null) || ver=""
  case "$ver" in
    3.*) ;;
    *) fed_die "juju 3.6.x is required, found: ${ver:-nothing}. brew installs 4.x, which cannot deploy these charms; install a 3.6 client from https://github.com/juju/juju/releases" ;;
  esac
}

# Single execution seam: every mutating juju call goes through here so a dry
# run can log (and record under FED_RENDER_DIR, keeping `make contracts`'s
# non-empty-render-dir check meaningful for juju-mode fixtures).
fed_juju() {
  if [ "${FED_DRY_RUN:-0}" = "1" ]; then
    fed_log "dry-run: juju $*"
    if [ -n "${FED_RENDER_DIR:-}" ]; then
      mkdir -p "$FED_RENDER_DIR"
      printf 'juju %s\n' "$*" >> "$FED_RENDER_DIR/juju-commands.txt"
    fi
    return 0
  fi
  juju "$@"
}

# kfp deliberately absent: it stays on kustomize in both modes (spike §9).
fed_juju_components_enabled() {
  fed_has_component minio || fed_has_component mlflow \
    || fed_has_component temporal || fed_has_component training
}

# Models needed for the enabled components: the consumer model
# ($FED_NAMESPACE) for minio/mlflow/temporal, the hardcoded kubeflow model
# for training. Deduplicated: a consumer may set FED_NAMESPACE=kubeflow.
fed_juju_models() {
  local models=""
  if fed_has_component minio || fed_has_component mlflow || fed_has_component temporal; then
    models="$FED_NAMESPACE"
  fi
  if fed_has_component training; then
    case " $models " in
      *" ${FED_KFP_NAMESPACE:-kubeflow} "*) ;;
      *) models="${models:+$models }${FED_KFP_NAMESPACE:-kubeflow}" ;;
    esac
  fi
  printf '%s' "$models"
}

fed_juju_ensure() {
  if [ "${FED_DRY_RUN:-0}" = "1" ]; then
    fed_log "dry-run: would ensure juju cloud/controller/models for ${FED_CLUSTER_NAME}"
    return 0
  fi
  local cloud controller m
  cloud=$(fed_juju_cloud_name)
  controller=$(fed_juju_controller_name)

  if juju show-cloud --client "$cloud" >/dev/null 2>&1; then
    fed_log "juju cloud '${cloud}' already registered"
  else
    fed_log "registering kind cluster as juju cloud '${cloud}'"
    juju add-k8s "$cloud" --client --context-name "kind-${FED_CLUSTER_NAME}" || return 1
  fi

  if juju show-controller "$controller" >/dev/null 2>&1; then
    fed_log "juju controller '${controller}' already bootstrapped"
  else
    fed_log "bootstrapping juju controller '${controller}' (about a minute warm, longer cold)"
    juju bootstrap "$cloud" "$controller" || return 1
  fi

  for m in $(fed_juju_models); do
    if juju show-model "${controller}:${m}" >/dev/null 2>&1; then
      fed_log "juju model '${m}' already exists"
    else
      fed_log "creating juju model '${m}'"
      juju add-model "$m" "$cloud" --controller "$controller" || return 1
    fi
  done
}
