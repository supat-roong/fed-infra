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
      - containerPort: ${FED_NODEPORT_K8S_DASHBOARD}
        hostPort: ${FED_HOSTPORT_K8S_DASHBOARD}
        protocol: TCP
      # The Kubernetes Dashboard mapping just above is identical to
      # single-cluster.yaml.tpl's (it can run under either profile), kept in
      # the same relative position so this template's rendered output stays
      # a strict prefix of single-cluster's, with only the Karmada-only
      # mappings below appended after.
      #
      # The Karmada control plane and dashboard run on the host only (see
      # lib/karmada.sh), so only this template -- not member.yaml.tpl --
      # needs them mapped. containerPort and hostPort are deliberately the
      # same variable, not a NODEPORT_*/HOSTPORT_* pair like the services
      # above: fed_karmada_init passes FED_KARMADA_APISERVER_PORT to
      # `karmadactl init --port`, so this mapping and that flag must always
      # agree, and a second, independently-settable hostPort would let them
      # drift again -- exactly the bug this template change fixes.
      - containerPort: ${FED_KARMADA_APISERVER_PORT}
        hostPort: ${FED_KARMADA_APISERVER_PORT}
        protocol: TCP
      # fed_karmada_dashboard_install (lib/dashboard.sh) patches the
      # Karmada Dashboard Service to FED_NODEPORT_KARMADA_DASHBOARD, but the
      # matching hostPort mapping must exist at kind cluster-creation time --
      # a consumer has no way to add one to a running kind node -- so it
      # belongs here, a genuine NODEPORT_*/HOSTPORT_* pair like every other
      # component (unlike the apiserver port above, nothing forces this
      # Service's NodePort to equal the host port it's mapped to).
      - containerPort: ${FED_NODEPORT_KARMADA_DASHBOARD}
        hostPort: ${FED_HOSTPORT_KARMADA_DASHBOARD}
        protocol: TCP
