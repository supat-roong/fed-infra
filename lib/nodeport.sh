#!/usr/bin/env bash
# nodeport.sh — expose a Service as NodePort with a caller-supplied ports array.

# fed_expose_nodeport <svc> <ns> <ports_json>
# Manifests-mode Services: this library applied them, so patching them in
# place is safe. Juju charms own their Services -- use
# fed_expose_charm_nodeport for those.
fed_expose_nodeport() {
  local svc=$1 ns=$2 ports_json=$3
  if [ "${FED_DRY_RUN:-0}" = "1" ]; then
    fed_log "dry-run: would expose ${svc} in ${ns} as NodePort"
    return 0
  fi
  fed_log "exposing ${svc} in ${ns} as NodePort"
  kubectl patch service "$svc" -n "$ns" \
    -p "{\"spec\":{\"type\":\"NodePort\",\"ports\":${ports_json}}}"
}

# fed_expose_charm_nodeport <app> <ns> <ports_json>
#
# Exposes a juju app through a separate `<app>-nodeport` Service selecting
# its pods (Juju labels them app.kubernetes.io/name=<app>), never by
# patching the charm's own Service. Charms reconcile that Service: kfp-ui
# re-patches it on every ~5-minute update-status, which silently dropped the
# NodePort again and left localhost:8080 answering "Connection reset by peer"
# (runs 35664500658, 35669915395) -- a pass or fail that depended only on
# whether a check landed before the next hook. A Service the charm does not
# know about is never touched, and it also sidesteps the placeholder:65535
# port Juju puts on charm Services.
#
# Releases before this one patched the charm Service itself, which may still
# hold the nodePort; returning it to ClusterIP releases the port (the API
# server clears nodePorts on that type change) before the new Service claims
# it.
fed_expose_charm_nodeport() {
  local app=$1 ns=$2 ports_json=$3 svc="${1}-nodeport" type
  if [ "${FED_DRY_RUN:-0}" = "1" ]; then
    fed_log "dry-run: would expose ${app} in ${ns} as NodePort via ${svc}"
    return 0
  fi
  type=$(kubectl get service "$app" -n "$ns" -o 'jsonpath={.spec.type}' 2>/dev/null) || type=""
  if [ "$type" = "NodePort" ]; then
    fed_log "returning ${app} in ${ns} to ClusterIP; its NodePort moves to ${svc}"
    kubectl patch service "$app" -n "$ns" --type=merge -p '{"spec":{"type":"ClusterIP"}}' || return 1
  fi
  fed_log "exposing ${app} in ${ns} as NodePort via ${svc}"
  printf '{"apiVersion":"v1","kind":"Service","metadata":{"name":"%s","namespace":"%s","labels":{"app.kubernetes.io/managed-by":"fed-infra"}},"spec":{"type":"NodePort","selector":{"app.kubernetes.io/name":"%s"},"ports":%s}}\n' \
    "$svc" "$ns" "$app" "$ports_json" | kubectl apply -f -
}
