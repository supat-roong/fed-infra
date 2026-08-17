#!/usr/bin/env bats
load helper

setup() {
  setup_stubs
  source "$FED_INFRA_ROOT/lib/common.sh"
  source "$FED_INFRA_ROOT/lib/config.sh"
  ENVFILE="$BATS_TEST_TMPDIR/infra.env"
  cat > "$ENVFILE" <<'EOF'
FED_CLUSTER_NAME=demo
FED_NAMESPACE=demo-ns
FED_PROFILE=single
FED_COMPONENTS=kfp,minio,mlflow
FED_S3_ENDPOINT=minio-service.demo-ns.svc.cluster.local:9000
FED_S3_ACCESS_KEY=minio
FED_S3_SECRET_KEY=minio123
EOF
}

@test "fed_config_load exports variables from the env file" {
  fed_config_load "$ENVFILE"
  [ "$FED_CLUSTER_NAME" = "demo" ]
  [ "$FED_NAMESPACE" = "demo-ns" ]
}

@test "fed_config_load applies documented defaults" {
  fed_config_load "$ENVFILE"
  [ "$FED_KFP_VERSION" = "2.4.0" ]
  [ "$FED_NODEPORT_KFP" = "30080" ]
  [ "$FED_HOSTPORT_MLFLOW" = "5050" ]
  [ "$FED_KIND_WORKERS" = "0" ]
  [ "$FED_DRY_RUN" = "0" ]
}

@test "fed_config_load applies documented Karmada/member defaults" {
  fed_config_load "$ENVFILE"
  [ "$FED_MEMBER_COUNT" = "2" ]
  [ "$FED_MEMBER_PREFIX" = "member" ]
  [ "$FED_KARMADA_VERSION" = "v1.17.0" ]
  [ "$FED_KARMADA_CONFIG" = "${HOME}/.karmada/karmada-apiserver.config" ]
}

@test "fed_config_load does not override values already set in the env file" {
  echo "FED_KFP_VERSION=9.9.9" >> "$ENVFILE"
  fed_config_load "$ENVFILE"
  [ "$FED_KFP_VERSION" = "9.9.9" ]
}

@test "fed_config_load dies when the env file is missing" {
  run bash -c "source '$FED_INFRA_ROOT/lib/common.sh'; source '$FED_INFRA_ROOT/lib/config.sh'; fed_config_load /nope/infra.env"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not found"* ]]
}

@test "fed_config_validate dies naming a missing required variable" {
  echo "FED_NAMESPACE=" > "$ENVFILE"
  echo "FED_CLUSTER_NAME=demo" >> "$ENVFILE"
  echo "FED_PROFILE=single" >> "$ENVFILE"
  echo "FED_COMPONENTS=kfp" >> "$ENVFILE"
  run bash -c "source '$FED_INFRA_ROOT/lib/common.sh'; source '$FED_INFRA_ROOT/lib/config.sh'; fed_config_load '$ENVFILE'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FED_NAMESPACE"* ]]
}

@test "fed_config_validate rejects an invalid profile" {
  sed -i.bak 's/FED_PROFILE=single/FED_PROFILE=sideways/' "$ENVFILE"
  run bash -c "source '$FED_INFRA_ROOT/lib/common.sh'; source '$FED_INFRA_ROOT/lib/config.sh'; fed_config_load '$ENVFILE'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FED_PROFILE"* ]]
}

@test "fed_config_validate dies naming the missing FED_S3_* variable when mlflow is enabled" {
  echo "FED_COMPONENTS=kfp,mlflow" >> "$ENVFILE"
  echo "FED_S3_ENDPOINT=" >> "$ENVFILE"
  run bash -c "source '$FED_INFRA_ROOT/lib/common.sh'; source '$FED_INFRA_ROOT/lib/config.sh'; fed_config_load '$ENVFILE'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FED_S3_ENDPOINT"* ]]
}

@test "fed_config_validate passes when FED_S3_* are set and mlflow is enabled" {
  echo "FED_COMPONENTS=kfp,mlflow" >> "$ENVFILE"
  fed_config_load "$ENVFILE"
  [ "$FED_S3_ENDPOINT" = "minio-service.demo-ns.svc.cluster.local:9000" ]
}

@test "fed_config_validate does not require FED_S3_* when mlflow is disabled" {
  {
    echo "FED_COMPONENTS=kfp,minio"
    echo "FED_S3_ENDPOINT="
    echo "FED_S3_ACCESS_KEY="
    echo "FED_S3_SECRET_KEY="
  } >> "$ENVFILE"
  fed_config_load "$ENVFILE"
  [ "$FED_CLUSTER_NAME" = "demo" ]
}

@test "fed_has_component matches only whole component names" {
  fed_config_load "$ENVFILE"
  run fed_has_component minio
  [ "$status" -eq 0 ]
  run fed_has_component temporal
  [ "$status" -eq 1 ]
  run fed_has_component mini
  [ "$status" -eq 1 ]
}
