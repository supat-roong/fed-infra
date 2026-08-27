#!/usr/bin/env bash
# components.sh — ordered component dispatch for fed-infra-up / fed-infra-down.

fed_up() {
  # A dry run renders manifests via envsubst and touches no cluster, so it
  # must not hard-require kind/kubectl/docker -- that would force every CI
  # runner that only renders contracts (no cluster tooling installed) to
  # fail before it ever reaches the FED_DRY_RUN guards further down that
  # make it a no-op. See tests/components.bats's "only envsubst is on PATH"
  # (this branch) and "still requires the full command set" (the else)
  # tests for the sibling regression each half guards against.
  if [ "${FED_DRY_RUN:-0}" = "1" ]; then
    fed_require_cmd envsubst
  else
    fed_require_cmd kind kubectl docker envsubst
  fi

  # Resolved once here so both the single and multi paths below inherit it
  # via fed_up_install_components. juju is only required outside a dry run --
  # a dry run never shells out to it (fed_juju_ensure/deploy/config/wait_active
  # all log-and-record instead), so requiring the binary here would break the
  # "renders manifests, touches nothing real" dry-run contract for a consumer
  # who doesn't have the juju CLI installed at all.
  FED_DEPLOY_MODE_RESOLVED=$(fed_deploy_mode)
  export FED_DEPLOY_MODE_RESOLVED
  if [ "$FED_DEPLOY_MODE_RESOLVED" = "juju" ] && fed_juju_components_enabled \
     && [ "${FED_DRY_RUN:-0}" != "1" ]; then
    fed_juju_require
  fi

  # multi is the only other profile fed_config_validate accepts, so this
  # single check covers both branches; the single-profile body below is
  # untouched from before this branch existed.
  if [ "$FED_PROFILE" = "multi" ]; then
    fed_up_multi
    return 0
  fi

  fed_kind_ensure_cluster "$FED_CLUSTER_NAME" "${FED_INFRA_ROOT}/kind/single-cluster.yaml.tpl"
  if [ "${FED_DRY_RUN:-0}" != "1" ]; then
    kubectl config use-context "kind-${FED_CLUSTER_NAME}"
  fi

  fed_up_install_components
}

# Host + N member kind clusters federated by Karmada. Workers run on members
# only; every shared service (kfp/training/temporal/minio/mlflow) runs on the
# host only, so fed_up_install_components below (identical for both
# profiles) executes with the host as the current kubectl context.
fed_up_multi() {
  fed_kind_ensure_cluster "$FED_CLUSTER_NAME" "${FED_INFRA_ROOT}/kind/multi-host.yaml.tpl"

  local i=1
  while [ "$i" -le "${FED_MEMBER_COUNT}" ]; do
    fed_kind_ensure_cluster "${FED_MEMBER_PREFIX}${i}" "${FED_INFRA_ROOT}/kind/member.yaml.tpl"
    i=$((i + 1))
  done

  fed_karmada_init "$FED_CLUSTER_NAME"
  fed_karmada_join "$FED_CLUSTER_NAME" "kind-${FED_CLUSTER_NAME}"
  fed_karmada_wait_cluster "$FED_CLUSTER_NAME"

  i=1
  while [ "$i" -le "${FED_MEMBER_COUNT}" ]; do
    fed_karmada_join "${FED_MEMBER_PREFIX}${i}" "kind-${FED_MEMBER_PREFIX}${i}"
    fed_karmada_wait_cluster "${FED_MEMBER_PREFIX}${i}"
    i=$((i + 1))
  done

  # Workers run on members, so every cluster -- host included -- needs
  # FED_IMAGES, not just the one fed_up_install_components loads its own
  # copy into below. Loading the host's copy again there is a harmless,
  # digest-checked no-op (fed_kind_load_image skips an already-current
  # image), not a second real load.
  local img
  for img in $FED_IMAGES; do
    fed_kind_load_image "$img" "$FED_CLUSTER_NAME"
  done
  i=1
  while [ "$i" -le "${FED_MEMBER_COUNT}" ]; do
    for img in $FED_IMAGES; do
      fed_kind_load_image "$img" "${FED_MEMBER_PREFIX}${i}"
    done
    i=$((i + 1))
  done

  if [ "${FED_DRY_RUN:-0}" != "1" ]; then
    kubectl config use-context "kind-${FED_CLUSTER_NAME}"
  fi

  fed_up_install_components
}

fed_up_install_components() {
  if [ "${FED_DEPLOY_MODE_RESOLVED:-manifests}" = "juju" ] && fed_juju_components_enabled; then
    fed_juju_ensure
  fi

  if fed_has_component kfp; then
    fed_kfp_install "$FED_KFP_VERSION"
    fed_kfp_patch_arm "$FED_KFP_VERSION"
    fed_kfp_patch_minio
  fi

  if fed_has_component training; then
    fed_training_install "$FED_TRAINING_OPERATOR_VERSION"
  fi

  if fed_has_component temporal; then
    fed_temporal_install "$FED_TEMPORAL_NAMESPACE" "$FED_TEMPORAL_VERSION"
  fi

  if fed_has_component minio; then
    if [ "${FED_DEPLOY_MODE_RESOLVED:-manifests}" = "juju" ]; then
      fed_minio_install_juju
    else
      fed_minio_install
    fi
  fi

  if fed_has_component mlflow; then
    fed_mlflow_build_image "$FED_MLFLOW_IMAGE" "$FED_MLFLOW_VERSION"
    fed_kind_load_image "$FED_MLFLOW_IMAGE" "$FED_CLUSTER_NAME"
    fed_mlflow_install
  fi

  if fed_has_component k8s-dashboard; then
    fed_k8s_dashboard_install "$FED_K8S_DASHBOARD_VERSION"
  fi

  if fed_has_component karmada-dashboard; then
    fed_karmada_dashboard_install "$FED_KARMADA_CONFIG"
  fi

  local img
  for img in $FED_IMAGES; do
    fed_kind_load_image "$img" "$FED_CLUSTER_NAME"
  done

  if fed_has_component kfp; then
    fed_kfp_wait
    fed_minio_ensure_bucket "$FED_KFP_NAMESPACE" \
      "minio-service.${FED_KFP_NAMESPACE}.svc.cluster.local:9000" \
      minio minio123 mlpipeline
    fed_expose_nodeport ml-pipeline-ui "$FED_KFP_NAMESPACE" \
      "[{\"port\":80,\"targetPort\":3000,\"nodePort\":${FED_NODEPORT_KFP}}]"
  fi

  if fed_has_component temporal; then
    fed_expose_nodeport temporal-web "$FED_TEMPORAL_NAMESPACE" \
      "[{\"port\":8080,\"targetPort\":8080,\"nodePort\":${FED_NODEPORT_TEMPORAL_UI}}]"
  fi

  if fed_has_component mlflow; then
    fed_minio_ensure_bucket "$FED_NAMESPACE" "$FED_S3_ENDPOINT" \
      "$FED_S3_ACCESS_KEY" "$FED_S3_SECRET_KEY" "$FED_S3_BUCKET"
  fi

  if fed_has_component minio; then
    if [ "${FED_DEPLOY_MODE_RESOLVED:-manifests}" = "juju" ]; then
      fed_expose_nodeport minio "$FED_NAMESPACE" \
        "[{\"name\":\"api\",\"port\":9000,\"targetPort\":9000,\"nodePort\":${FED_NODEPORT_MINIO_API}},{\"name\":\"console\",\"port\":9001,\"targetPort\":9001,\"nodePort\":${FED_NODEPORT_MINIO_CONSOLE}}]"
    else
      fed_expose_nodeport minio-service "$FED_NAMESPACE" \
        "[{\"name\":\"api\",\"port\":9000,\"targetPort\":9000,\"nodePort\":${FED_NODEPORT_MINIO_API}},{\"name\":\"console\",\"port\":9001,\"targetPort\":9001,\"nodePort\":${FED_NODEPORT_MINIO_CONSOLE}}]"
    fi
  fi

  # karmada-dashboard patches its own Service NodePort inside
  # fed_karmada_dashboard_install itself (it needs the Karmada-apiserver
  # kubeconfig secrets in place first); k8s-dashboard has no such ordering
  # requirement, so it's exposed here, alongside every other component's
  # post-install NodePort step.
  if fed_has_component k8s-dashboard; then
    fed_expose_nodeport kubernetes-dashboard "$FED_K8S_DASHBOARD_NAMESPACE" \
      "[{\"port\":443,\"targetPort\":8443,\"nodePort\":${FED_NODEPORT_K8S_DASHBOARD}}]"
  fi

  fed_up_summary
}

fed_up_summary() {
  fed_log ""
  fed_log "Setup complete. Services:"
  if fed_has_component kfp; then
    fed_log "  Kubeflow Pipelines : http://localhost:${FED_HOSTPORT_KFP}"
  fi
  if fed_has_component mlflow; then
    fed_log "  MLflow             : http://localhost:${FED_HOSTPORT_MLFLOW}"
  fi
  if fed_has_component temporal; then
    fed_log "  Temporal UI        : http://localhost:${FED_HOSTPORT_TEMPORAL_UI}"
  fi
  if fed_has_component minio; then
    fed_log "  MinIO Console      : http://localhost:${FED_HOSTPORT_MINIO_CONSOLE}"
  fi
  if fed_has_component k8s-dashboard; then
    fed_log "  Kubernetes Dashboard : https://localhost:${FED_HOSTPORT_K8S_DASHBOARD}"
  fi
  if fed_has_component karmada-dashboard; then
    fed_log "  Karmada Dashboard    : http://localhost:${FED_HOSTPORT_KARMADA_DASHBOARD}"
  fi
}

fed_down() {
  fed_require_cmd kind
  pkill -f "kubectl port-forward" 2>/dev/null || true
  fed_juju_teardown

  # Members first: the host runs the Karmada control plane the members are
  # registered against, so deleting it first would orphan them.
  if [ "$FED_PROFILE" = "multi" ]; then
    local i=1
    while [ "$i" -le "${FED_MEMBER_COUNT}" ]; do
      fed_kind_delete_cluster "${FED_MEMBER_PREFIX}${i}"
      i=$((i + 1))
    done
  fi

  fed_kind_delete_cluster "$FED_CLUSTER_NAME"
}
