#!/usr/bin/env bash
# karmada.sh — Karmada control plane: install on the host cluster, join member
# clusters, and wait for them to report Ready.
#
# The control plane runs as pods *inside* the host kind container. A member
# cluster is joined by handing karmadactl a kubeconfig context that resolves
# on the machine running this script (kind-<name>, pointing at 127.0.0.1),
# but Karmada stores that kubeconfig verbatim and later reads it from
# *inside* the host container to actually talk to the member. From in there,
# 127.0.0.1/localhost means the host container itself, not the member -- so
# every join is followed by patching both the Cluster object's apiEndpoint
# and the kubeconfig inside its Secret to the member's real Docker-network
# IP. Skipping that patch leaves Karmada unable to reach any member it just
# joined.

fed_karmada_init() {
  local host_cluster=$1
  if [ "${FED_DRY_RUN:-0}" = "1" ]; then
    fed_log "dry-run: would initialize the Karmada control plane on ${host_cluster}"
    return 0
  fi

  kubectl config use-context "kind-${host_cluster}" || return 1

  if kubectl get namespace karmada-system >/dev/null 2>&1; then
    fed_log "Karmada control plane already initialized"
    return 0
  fi

  fed_require_cmd karmadactl

  # karmadactl init defaults its data/PKI dirs under /etc/karmada, which
  # requires sudo. Point both at a directory under HOME instead, derived
  # from FED_KARMADA_CONFIG so the two stay in sync, and pin the advertised
  # address to loopback plus emptyDir etcd storage -- what makes this work
  # unattended on a local kind cluster with no external load balancer.
  local karmada_data
  karmada_data=$(dirname "$FED_KARMADA_CONFIG") || return 1
  mkdir -p "${karmada_data}/pki" || return 1

  fed_log "initializing Karmada ${FED_KARMADA_VERSION} control plane on ${host_cluster}"
  # --port must be the same value kind/multi-host.yaml.tpl maps as a
  # hostPort (FED_KARMADA_APISERVER_PORT, default 32443, matching
  # karmadactl's own default): karmadactl init writes $FED_KARMADA_CONFIG
  # pointing at https://127.0.0.1:<this port>, and every later
  # kubectl --kubeconfig="$FED_KARMADA_CONFIG" call runs from this host
  # machine, not from inside the kind container. A hardcoded template port
  # with a different --port here would leave the apiserver unreachable
  # exactly like the gap this line fixes.
  karmadactl init \
    --karmada-data="$karmada_data" \
    --karmada-pki="${karmada_data}/pki" \
    --cert-external-ip="127.0.0.1" \
    --cert-external-dns="localhost" \
    --karmada-apiserver-advertise-address="127.0.0.1" \
    --etcd-storage-mode="emptyDir" \
    --port="$FED_KARMADA_APISERVER_PORT" || return 1
}

fed_karmada_join() {
  local cluster_name=$1 kube_context=$2
  if [ "${FED_DRY_RUN:-0}" = "1" ]; then
    fed_log "dry-run: would join ${cluster_name} to the Karmada control plane"
    return 0
  fi
  fed_require_cmd karmadactl docker python3

  if kubectl --kubeconfig="$FED_KARMADA_CONFIG" get cluster "$cluster_name" >/dev/null 2>&1; then
    fed_log "${cluster_name} already joined to Karmada"
  else
    fed_log "joining ${cluster_name} to Karmada"
    karmadactl --kubeconfig="$FED_KARMADA_CONFIG" join "$cluster_name" \
      --cluster-kubeconfig="${HOME}/.kube/config" \
      --cluster-context="$kube_context" || return 1
  fi

  # Re-resolve and re-patch on every call, not only right after joining: a
  # kind container can be assigned a new Docker-network IP across a
  # docker/host restart even though the cluster name and Karmada
  # registration are unchanged, and a stale patch is as broken as none.
  # Guarded with `|| ip=""` rather than left bare: callers (bin/fed-infra-up)
  # source this library under `set -euo pipefail`, and this pipeline can
  # legitimately fail (both docker inspect attempts miss). Left unguarded,
  # errexit would abort the whole script right here, before the "empty ip
  # -> warn and return 0" branch below ever runs -- turning a deliberately
  # soft fallback into a hard, unexplained bootstrap failure. Same idiom
  # already used in fed_kind_load_image for the same reason.
  local ip
  ip=$( (docker inspect "${cluster_name}-control-plane" --format '{{ .NetworkSettings.Networks.kind.IPAddress }}' 2>/dev/null \
    || docker inspect "kind-${cluster_name}-control-plane" --format '{{ .NetworkSettings.Networks.kind.IPAddress }}' 2>/dev/null) | tr -d '\n') || ip=""
  if [ -z "$ip" ]; then
    fed_warn "could not determine the Docker-network IP for ${cluster_name}; leaving its Karmada endpoint unpatched"
    return 0
  fi

  fed_log "patching ${cluster_name} to internal IP ${ip}"
  kubectl --kubeconfig="$FED_KARMADA_CONFIG" patch cluster "$cluster_name" --type=merge \
    -p "{\"spec\":{\"apiEndpoint\":\"https://${ip}:6443\"}}" || return 1

  local secret_name secret_ns
  secret_name=$(kubectl --kubeconfig="$FED_KARMADA_CONFIG" get cluster "$cluster_name" -o jsonpath='{.spec.secretRef.name}') || return 1
  secret_ns=$(kubectl --kubeconfig="$FED_KARMADA_CONFIG" get cluster "$cluster_name" -o jsonpath='{.spec.secretRef.namespace}') || return 1
  [ -n "$secret_name" ] || return 0

  # Karmada stores the member's kubeconfig base64-encoded inside this
  # Secret, still pointing at 127.0.0.1/localhost from when it was joined.
  # sed on base64 content is unreliable (wrapping, padding), so decode,
  # rewrite, and re-encode with python3 instead.
  local tmp_kubeconfig b64_kubeconfig new_kubeconfig rc=0
  tmp_kubeconfig=$(mktemp) || return 1

  b64_kubeconfig=$(kubectl --kubeconfig="$FED_KARMADA_CONFIG" get secret "$secret_name" -n "$secret_ns" -o jsonpath='{.data.kubeconfig}') || rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '%s' "$b64_kubeconfig" \
      | python3 -c "import sys, base64; sys.stdout.buffer.write(base64.b64decode(sys.stdin.read()))" > "$tmp_kubeconfig" || rc=$?
  fi
  if [ "$rc" -eq 0 ]; then
    python3 -c "import sys; c=open('$tmp_kubeconfig').read(); open('$tmp_kubeconfig', 'w').write(c.replace('127.0.0.1', '$ip').replace('localhost', '$ip'))" || rc=$?
  fi
  if [ "$rc" -eq 0 ]; then
    new_kubeconfig=$(python3 -c "import sys, base64; print(base64.b64encode(open('$tmp_kubeconfig', 'rb').read()).decode('utf-8'))") || rc=$?
  fi
  if [ "$rc" -eq 0 ]; then
    kubectl --kubeconfig="$FED_KARMADA_CONFIG" patch secret "$secret_name" -n "$secret_ns" \
      -p "{\"data\":{\"kubeconfig\":\"${new_kubeconfig}\"}}" || rc=$?
  fi
  rm -f "$tmp_kubeconfig"
  return "$rc"
}

fed_karmada_wait_cluster() {
  local cluster_name=$1
  if [ "${FED_DRY_RUN:-0}" = "1" ]; then
    fed_log "dry-run: would wait for ${cluster_name} to report Ready in Karmada"
    return 0
  fi
  fed_log "waiting for ${cluster_name} to report Ready in the Karmada control plane"
  kubectl --kubeconfig="$FED_KARMADA_CONFIG" wait --for=condition=Ready "cluster/${cluster_name}" --timeout=120s || return 1
}
