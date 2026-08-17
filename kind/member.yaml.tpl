kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
# This intentionally omits the cluster-identifying field kind's config
# schema supports: fed_kind_ensure_cluster always passes --name explicitly,
# and the omitted field here would otherwise have to be a per-call member
# identifier that fed_render has no way to substitute (FED_TEMPLATE_VARS is
# a static whitelist of consumer-wide FED_ vars, not something a caller can
# parameterize per invocation). Omitting it and relying on --name is exactly
# what kind does when a config lacks that field.
nodes:
  - role: control-plane
# Deliberately no host port bindings here: members only run worker pods and
# are reached over the host's NodePorts from inside the shared `kind` Docker
# network, never from the machine's own localhost. Multiple members run on
# the same machine, so any such binding here would collide across them.
