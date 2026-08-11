#!/usr/bin/env bash
# kind.sh — kind cluster lifecycle and digest-checked image loading.

fed_kind_ensure_cluster() {
  local name=$1 tpl=$2
  if [ "${FED_DRY_RUN:-0}" = "1" ]; then
    fed_log "dry-run: would ensure kind cluster '${name}' exists"
    return 0
  fi
  if kind get clusters 2>/dev/null | grep -qx "$name"; then
    fed_log "kind cluster '$name' already exists"
    return 0
  fi
  fed_log "creating kind cluster '$name'"

  # Worker nodes are appended rather than templated, because the count varies
  # per consumer and YAML has no repeat construct.
  local rendered i=0
  rendered=$(fed_render "$tpl")
  while [ "$i" -lt "${FED_KIND_WORKERS:-0}" ]; do
    rendered="${rendered}
  - role: worker"
    i=$((i + 1))
  done
  printf '%s\n' "$rendered" | kind create cluster --name "$name" --config -
}

# Returns the 12-char image id of $1 inside cluster $2, or empty if absent.
fed_kind_cluster_image_id() {
  local image=$1 cluster=$2
  if [ -n "${FED_KIND_CRICTL_OUT+x}" ]; then
    printf '%s' "$FED_KIND_CRICTL_OUT"
    return 0
  fi
  docker exec "${cluster}-control-plane" crictl images 2>/dev/null \
    | awk -v r="${image%:*}" -v t="${image#*:}" '$1==r && $2==t {print $3}' \
    | head -n 1
}

fed_kind_load_image() {
  local image=$1 cluster=$2
  if [ "${FED_DRY_RUN:-0}" = "1" ]; then
    fed_log "dry-run: would load image ${image} into cluster ${cluster}"
    return 0
  fi
  local local_id cluster_id
  # Capture failure explicitly rather than letting the plain assignment abort
  # under the entrypoints' `set -euo pipefail`: a failing pipeline on the
  # right-hand side of `var=$(...)` propagates through `pipefail` and kills
  # the script on this line before fed_die below ever runs.
  local_id=$(docker image inspect "$image" --format '{{.Id}}' 2>/dev/null \
    | cut -d: -f2 | cut -c1-12) || local_id=""
  [ -n "$local_id" ] || fed_die "image not found locally: $image (build it first)"

  # Same reasoning: if the control-plane container is gone, fall through to
  # `kind load` below instead of aborting the whole script.
  cluster_id=$(fed_kind_cluster_image_id "$image" "$cluster") || cluster_id=""
  if [ -n "$cluster_id" ] && [ "$(printf '%s' "$cluster_id" | cut -c1-12)" = "$local_id" ]; then
    fed_log "image $image already current in cluster $cluster"
    return 0
  fi

  fed_log "loading image $image into cluster $cluster"
  kind load docker-image "$image" --name "$cluster"
}

fed_kind_delete_cluster() {
  local name=$1
  fed_log "deleting kind cluster '$name'"
  kind delete cluster --name "$name"
}
