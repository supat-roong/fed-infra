#!/usr/bin/env bash
# components.sh — ordered component dispatch for fed-infra-up / fed-infra-down.

fed_up() {
  fed_require_cmd kind kubectl docker envsubst

  fed_kind_ensure_cluster "$FED_CLUSTER_NAME" "${FED_INFRA_ROOT}/kind/single-cluster.yaml.tpl"
  if [ "${FED_DRY_RUN:-0}" != "1" ]; then
    kubectl config use-context "kind-${FED_CLUSTER_NAME}"
  fi

  if fed_has_component kfp; then
    fed_kfp_install "$FED_KFP_VERSION"
    fed_kfp_patch_arm "$FED_KFP_VERSION"
    fed_kfp_patch_minio
  fi

  if fed_has_component minio; then
    fed_minio_install
  fi

  if fed_has_component mlflow; then
    fed_mlflow_build_image "$FED_MLFLOW_IMAGE" "$FED_MLFLOW_VERSION"
    fed_kind_load_image "$FED_MLFLOW_IMAGE" "$FED_CLUSTER_NAME"
    fed_mlflow_install
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

  if fed_has_component mlflow; then
    fed_minio_ensure_bucket "$FED_NAMESPACE" "$FED_S3_ENDPOINT" \
      "$FED_S3_ACCESS_KEY" "$FED_S3_SECRET_KEY" "$FED_S3_BUCKET"
  fi

  if fed_has_component minio; then
    fed_expose_nodeport minio-service "$FED_NAMESPACE" \
      "[{\"name\":\"api\",\"port\":9000,\"targetPort\":9000,\"nodePort\":${FED_NODEPORT_MINIO_API}},{\"name\":\"console\",\"port\":9001,\"targetPort\":9001,\"nodePort\":${FED_NODEPORT_MINIO_CONSOLE}}]"
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
  if fed_has_component minio; then
    fed_log "  MinIO Console      : http://localhost:${FED_HOSTPORT_MINIO_CONSOLE}"
  fi
}

fed_down() {
  fed_require_cmd kind
  pkill -f "kubectl port-forward" 2>/dev/null || true
  fed_kind_delete_cluster "$FED_CLUSTER_NAME"
}
