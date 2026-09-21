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
  else
    fed_log "creating kind cluster '$name'"

    # Worker nodes are appended rather than templated, because the count
    # varies per consumer and YAML has no repeat construct.
    local rendered i=0
    rendered=$(fed_render "$tpl")
    while [ "$i" -lt "${FED_KIND_WORKERS:-0}" ]; do
      rendered="${rendered}
  - role: worker"
      i=$((i + 1))
    done
    printf '%s\n' "$rendered" | kind create cluster --name "$name" --config -
    # Only on creation: an existing cluster already holds whatever it pulled,
    # and re-importing a multi-GB archive on every idempotent re-run would
    # cost minutes for nothing.
    if [ -n "${FED_IMAGE_ARCHIVE:-}" ]; then
      fed_kind_import_archive "$FED_IMAGE_ARCHIVE" "$name"
    fi
  fi

  # Applies whether the cluster was just created or already existed: a node
  # can lose this setting across a docker/host restart even though kind
  # itself still reports the cluster present.
  fed_kind_raise_inotify_limits "$name"
}

# kind nodes running many pods routinely exhaust the default inotify
# instance/watch ceiling, surfacing as "too many open files" from
# kubelet/containerd -- a classic, confusing failure under load, and worse
# the more clusters/pods a single machine hosts (i.e. exactly the multi
# profile). Generic kind hygiene, not Karmada-specific, so every profile's
# node gets it. `|| true` throughout, matching the original hand-rolled
# script this was ported from: raising the limit is an optimization, and a
# failure here (e.g. sysctl unsupported in some container runtime) must
# never abort an otherwise-successful cluster bootstrap.
fed_kind_raise_inotify_limits() {
  local name=$1
  if [ "${FED_DRY_RUN:-0}" = "1" ]; then
    fed_log "dry-run: would raise inotify limits on ${name}-control-plane"
    return 0
  fi
  # Raise means raise. This sysctl is shared with the host kernel rather than
  # namespaced per container (verified live: setting it on the VM immediately
  # changed the value read inside a node container), so writing 512
  # unconditionally does not merely set this node's ceiling -- it overwrites
  # the whole machine's. An operator who raised it by hand to survive several
  # clusters would have it silently dropped back to 512 by the next
  # fed-infra-up. Guarded with `|| cur=""` for the usual reason: callers
  # source this under `set -euo pipefail`, and an unreadable value must fall
  # through to "set it" rather than abort the bootstrap.
  local cur
  cur=$(docker exec "${name}-control-plane" sysctl -n fs.inotify.max_user_instances 2>/dev/null) || cur=""
  case "$cur" in
    ''|*[!0-9]*) ;;
    *)
      if [ "$cur" -ge 512 ]; then
        fed_log "inotify limits on ${name}-control-plane already at ${cur}, leaving them alone"
        return 0
      fi
      ;;
  esac

  fed_log "raising inotify limits on ${name}-control-plane"
  docker exec "${name}-control-plane" \
    sysctl -w fs.inotify.max_user_instances=512 fs.inotify.max_user_watches=524288 || true
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

# Seeds every node of cluster $2 with the images in archive $1 (an OCI tar
# from fed_kind_export_images), straight into containerd's k8s.io namespace
# so kubelet finds them already present -- digest-pinned refs included, which
# `kind load docker-image` cannot carry because docker drops them on save.
# A warm cache, never a requirement: a missing archive or a failed import only
# warns, and whatever is absent is pulled as usual.
fed_kind_import_archive() {
  local archive=$1 cluster=$2 node nodes
  if [ ! -f "$archive" ]; then
    fed_warn "image archive not found, pulling everything: $archive"
    return 0
  fi
  nodes=$(kind get nodes --name "$cluster" 2>/dev/null) || nodes=""
  for node in $nodes; do
    fed_log "importing image archive into ${node}"
    docker exec -i "$node" ctr --namespace=k8s.io images import - < "$archive" \
      || fed_warn "image archive import into ${node} failed; its images will be pulled instead"
  done
}

# Writes every named image in cluster $1's control-plane containerd to the
# OCI tar $2, for a later fed_kind_import_archive. Bare `sha256:` entries are
# the ids containerd records alongside each named ref, not images of their
# own. Each ref is probed with a throwaway in-node export first: some images
# reference content the node never fetched (seen on nightly run 35638783453:
# "content digest sha256:00cbc2...: not found"), and a single such ref fails
# the whole bulk export. Written via a temp file so a failed export never
# leaves a truncated archive where a cache step would pick it up.
fed_kind_export_images() {
  local cluster=$1 archive=$2 node refs ref ok=""
  node="${cluster}-control-plane"
  refs=$(docker exec "$node" ctr --namespace=k8s.io images ls -q | grep -v '^sha256:') || refs=""
  for ref in $refs; do
    if docker exec "$node" ctr --namespace=k8s.io images export /dev/null "$ref" >/dev/null 2>&1; then
      ok="${ok:+$ok }${ref}"
    else
      fed_warn "skipping ${ref}: its content is incomplete in ${node}"
    fi
  done
  [ -n "$ok" ] || { fed_warn "no images to export from ${node}"; return 1; }
  # shellcheck disable=SC2086 # one ref per word, by design
  if docker exec "$node" ctr --namespace=k8s.io images export - $ok > "${archive}.tmp"; then
    mv "${archive}.tmp" "$archive"
  else
    rm -f "${archive}.tmp"
    return 1
  fi
}

fed_kind_delete_cluster() {
  local name=$1
  fed_log "deleting kind cluster '$name'"
  kind delete cluster --name "$name"
}
