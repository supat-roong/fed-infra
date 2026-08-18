# Local-development convenience: this ServiceAccount is bound to
# cluster-admin so fed_dashboard_token can hand out a token that fully
# authenticates to the Kubernetes Dashboard, which otherwise carries no
# usable RBAC of its own. Do this nowhere else -- a leaked token grants
# unrestricted control over the whole cluster. Appropriate here only
# because the cluster in question is an ephemeral local kind cluster.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: dashboard-admin
  namespace: ${FED_NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: dashboard-admin-binding
subjects:
  - kind: ServiceAccount
    name: dashboard-admin
    namespace: ${FED_NAMESPACE}
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
