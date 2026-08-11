#!/usr/bin/env bash
# nodeport.sh — expose a Service as NodePort with a caller-supplied ports array.

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
