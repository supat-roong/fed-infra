#!/usr/bin/env bats
load helper

setup() {
  setup_stubs
  ENVFILE="$BATS_TEST_TMPDIR/infra.env"
  RENDER="$BATS_TEST_TMPDIR/render"
}

write_env() {
  cat > "$ENVFILE" <<EOF
FED_CLUSTER_NAME=demo
FED_NAMESPACE=demo-ns
FED_PROFILE=single
FED_COMPONENTS=$1
FED_S3_ENDPOINT=minio-service.demo-ns.svc.cluster.local:9000
FED_S3_ACCESS_KEY=ak
FED_S3_SECRET_KEY=sk
EOF
}

@test "fed-infra-up with all components installs kfp, minio, and mlflow" {
  write_env "kfp,minio,mlflow"
  run "$FED_INFRA_ROOT/bin/fed-infra-up" --env "$ENVFILE" --dry-run --render-dir "$RENDER"
  [ "$status" -eq 0 ]
  [ -f "$RENDER/minio.yaml" ]
  [ -f "$RENDER/mlflow-server.yaml" ]
}

@test "fed-infra-up omits minio when the component is not listed" {
  write_env "kfp,mlflow"
  run "$FED_INFRA_ROOT/bin/fed-infra-up" --env "$ENVFILE" --dry-run --render-dir "$RENDER"
  [ "$status" -eq 0 ]
  [ ! -f "$RENDER/minio.yaml" ]
  [ -f "$RENDER/mlflow-server.yaml" ]
}

@test "fed-infra-up fails with a clear message when --env is missing" {
  run "$FED_INFRA_ROOT/bin/fed-infra-up"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--env"* ]]
}

@test "fed-infra-down deletes the configured cluster" {
  write_env "kfp"
  run "$FED_INFRA_ROOT/bin/fed-infra-down" --env "$ENVFILE"
  [ "$status" -eq 0 ]
  assert_called "kind delete cluster --name demo"
}

@test "fed_expose_nodeport patches a service to NodePort with the given ports" {
  source "$FED_INFRA_ROOT/lib/common.sh"
  source "$FED_INFRA_ROOT/lib/nodeport.sh"
  fed_expose_nodeport mysvc myns '[{"port":80,"targetPort":3000,"nodePort":30080}]'
  assert_called "kubectl patch service mysvc -n myns"
  assert_called '"type":"NodePort"'
}
