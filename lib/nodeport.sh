#!/usr/bin/env bash
# nodeport.sh — expose a Service as NodePort with a caller-supplied ports array.

# fed_expose_nodeport <svc> <ns> <ports_json> [patch_type]
#
# patch_type is passed straight to `kubectl patch --type=` and defaults to
# omitting the flag entirely, i.e. kubectl's own default (strategic), which is
# what every manifests-mode caller has always used and continues to use
# byte-for-byte.
#
# juju-mode callers pass `merge`, and must. `spec.ports` has a strategic-merge
# key of `port`, so a strategic patch MERGES our entry into the existing list
# instead of replacing it. Charm Services carry a `placeholder:65535` port that
# Juju creates before the charm opens any port of its own (it survives even
# after real ports appear -- temporal-k8s serves 65535 alongside 7233 &c). A
# strategic patch therefore leaves that placeholder in place and the Service
# becomes multi-port, at which point Kubernetes requires every port to be
# named and rejects the whole patch:
#
#   The Service "temporal-ui-k8s" is invalid: spec.ports[0].name: Required value
#
# That aborts fed-infra-up under `set -e`. A `merge` patch replaces the ports
# list wholesale, dropping the placeholder and leaving exactly the port(s) the
# caller asked for. Verified live on the x86_64 e2e for temporal-ui-k8s.
fed_expose_nodeport() {
  local svc=$1 ns=$2 ports_json=$3 patch_type=${4:-}
  if [ "${FED_DRY_RUN:-0}" = "1" ]; then
    fed_log "dry-run: would expose ${svc} in ${ns} as NodePort"
    return 0
  fi
  fed_log "exposing ${svc} in ${ns} as NodePort"
  if [ -n "$patch_type" ]; then
    kubectl patch service "$svc" -n "$ns" --type="$patch_type" \
      -p "{\"spec\":{\"type\":\"NodePort\",\"ports\":${ports_json}}}"
  else
    kubectl patch service "$svc" -n "$ns" \
      -p "{\"spec\":{\"type\":\"NodePort\",\"ports\":${ports_json}}}"
  fi
}
