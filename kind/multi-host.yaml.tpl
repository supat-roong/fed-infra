kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${FED_CLUSTER_NAME}
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: ${FED_NODEPORT_KFP}
        hostPort: ${FED_HOSTPORT_KFP}
        protocol: TCP
      - containerPort: ${FED_NODEPORT_MLFLOW}
        hostPort: ${FED_HOSTPORT_MLFLOW}
        protocol: TCP
      - containerPort: ${FED_NODEPORT_MINIO_API}
        hostPort: ${FED_HOSTPORT_MINIO_API}
        protocol: TCP
      - containerPort: ${FED_NODEPORT_MINIO_CONSOLE}
        hostPort: ${FED_HOSTPORT_MINIO_CONSOLE}
        protocol: TCP
      - containerPort: ${FED_NODEPORT_TEMPORAL_UI}
        hostPort: ${FED_HOSTPORT_TEMPORAL_UI}
        protocol: TCP
