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

# Execution seam for juju's deploy/config/integrate/action calls: routing
# them through here lets a dry run log (and record under FED_RENDER_DIR,
# keeping `make contracts`'s non-empty-render-dir check meaningful for
# juju-mode fixtures) instead of executing. fed_juju_ensure and
# fed_juju_teardown intentionally bypass this seam -- each calls `juju`
# directly, guarded by its own FED_DRY_RUN check -- because their
# idempotency probes (juju show-cloud/show-controller/show-model) need real
# command output to branch on, which the seam's log-and-return can't give
# them.
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

fed_juju_components_enabled() {
  fed_has_component minio || fed_has_component mlflow \
    || fed_has_component temporal || fed_has_component training \
    || fed_has_component kfp
}

# Models needed for the enabled components: the consumer model
# ($FED_NAMESPACE) for minio/mlflow/temporal, the hardcoded kubeflow model
# for training/kfp. Deduplicated: a consumer may set FED_NAMESPACE=kubeflow.
fed_juju_models() {
  local models=""
  if fed_has_component minio || fed_has_component mlflow || fed_has_component temporal; then
    models="$FED_NAMESPACE"
  fi
  if fed_has_component training || fed_has_component kfp; then
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

# fed_juju_deploy <model> <app> <charm> <channel> [extra deploy flags...]
# Skips silently when the app already exists in the model.
fed_juju_deploy() {
  local model=$1 app=$2 charm=$3 channel=$4 controller
  shift 4
  controller=$(fed_juju_controller_name)
  if [ "${FED_DRY_RUN:-0}" != "1" ]; then
    if juju show-application -m "${controller}:${model}" "$app" >/dev/null 2>&1; then
      fed_log "juju app '${app}' already deployed in model '${model}'"
      return 0
    fi
    fed_log "deploying '${charm}' as '${app}' into model '${model}' (channel ${channel})"
  fi
  fed_juju deploy -m "${controller}:${model}" "$charm" "$app" --channel "$channel" "$@"
}

# fed_juju_config <model> <app> key=value...  (re-applying is a safe no-op)
fed_juju_config() {
  local model=$1 app=$2 controller
  shift 2
  controller=$(fed_juju_controller_name)
  fed_juju config -m "${controller}:${model}" "$app" "$@"
}

# fed_juju_integrate <model> <endpoint-a> <endpoint-b>
# `juju integrate` has no --ignore-existing; detect the benign failure by
# message so re-runs stay green while real endpoint errors still fail.
fed_juju_integrate() {
  local model=$1 a=$2 b=$3 controller out rc=0
  controller=$(fed_juju_controller_name)
  if [ "${FED_DRY_RUN:-0}" = "1" ]; then
    fed_juju integrate -m "${controller}:${model}" "$a" "$b"
    return 0
  fi
  out=$(juju integrate -m "${controller}:${model}" "$a" "$b" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    case "$out" in
      *"already exists"*) fed_log "relation ${a} <-> ${b} already exists" ;;
      *) fed_warn "juju integrate failed: ${out}"; return "$rc" ;;
    esac
  fi
  return 0
}

fed_juju_app_active() {
  local model=$1 app=$2 controller
  controller=$(fed_juju_controller_name)
  juju status -m "${controller}:${model}" "$app" --format=oneline 2>/dev/null \
    | grep -q 'workload:active'
}

# Poll (never a fixed sleep — same budget rationale as fed_training_install's
# pod wait) until the app's workload column reports active.
fed_juju_wait_active() {
  local model=$1 app=$2
  if [ "${FED_DRY_RUN:-0}" = "1" ]; then
    fed_log "dry-run: would wait for '${app}' in model '${model}' to become active"
    return 0
  fi
  fed_log "waiting for '${app}' in model '${model}' to become active"
  fed_retry "$FED_POD_READY_ATTEMPTS" "$FED_RETRY_DELAY" fed_juju_app_active "$model" "$app"
}

# fed_juju_action <model> <unit> <action> [param=value...]
fed_juju_action() {
  local model=$1 unit=$2 action=$3 controller
  shift 3
  controller=$(fed_juju_controller_name)
  fed_juju run -m "${controller}:${model}" "$unit" "$action" "$@"
}

# Client-state hygiene for fed_down. The kind cluster deletion that follows
# destroys the in-cluster controller and every model; only the local client's
# controller/cloud records need cleaning (spike §8: remove-cloud also drops
# the credential). A machine without the juju CLI has nothing to clean.
fed_juju_teardown() {
  if [ "${FED_DRY_RUN:-0}" = "1" ]; then
    fed_log "dry-run: would unregister the juju controller and remove the kind cloud"
    return 0
  fi
  command -v juju >/dev/null 2>&1 || return 0
  local cloud controller
  cloud=$(fed_juju_cloud_name)
  controller=$(fed_juju_controller_name)
  if juju show-controller "$controller" >/dev/null 2>&1; then
    fed_log "unregistering juju controller '${controller}'"
    juju unregister "$controller" --no-prompt \
      || fed_warn "could not unregister controller '${controller}'; remove it manually with: juju unregister ${controller}"
  fi
  if juju show-cloud --client "$cloud" >/dev/null 2>&1; then
    fed_log "removing juju cloud '${cloud}' from the client"
    juju remove-cloud "$cloud" --client \
      || fed_warn "could not remove cloud '${cloud}'"
  fi
}
