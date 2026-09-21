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
  # karmadactl init defaults --port to 32443; the host kind cluster must map
  # a hostPort of the same value or the Karmada apiserver is unreachable from
  # the machine running this script. See kind/multi-host.yaml.tpl and
  # fed_karmada_init's --port flag, both driven by this same variable.
  [ "$FED_KARMADA_APISERVER_PORT" = "32443" ]
}

@test "fed_config_load applies documented dashboard defaults" {
  fed_config_load "$ENVFILE"
  [ "$FED_K8S_DASHBOARD_VERSION" = "v2.7.0" ]
  [ "$FED_NODEPORT_K8S_DASHBOARD" = "30443" ]
  [ "$FED_HOSTPORT_K8S_DASHBOARD" = "8443" ]
  [ "$FED_NODEPORT_KARMADA_DASHBOARD" = "32000" ]
  [ "$FED_HOSTPORT_KARMADA_DASHBOARD" = "32000" ]
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

@test "fed_config_validate dies when the multi profile omits the karmada component" {
  sed -i.bak 's/FED_PROFILE=single/FED_PROFILE=multi/' "$ENVFILE"
  run bash -c "source '$FED_INFRA_ROOT/lib/common.sh'; source '$FED_INFRA_ROOT/lib/config.sh'; fed_config_load '$ENVFILE'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"karmada"* ]]
}

@test "fed_config_validate passes when the multi profile declares karmada" {
  sed -i.bak 's/FED_PROFILE=single/FED_PROFILE=multi/' "$ENVFILE"
  sed -i.bak 's/FED_COMPONENTS=kfp,minio,mlflow/FED_COMPONENTS=kfp,minio,mlflow,karmada/' "$ENVFILE"
  run bash -c "source '$FED_INFRA_ROOT/lib/common.sh'; source '$FED_INFRA_ROOT/lib/config.sh'; fed_config_load '$ENVFILE'"
  [ "$status" -eq 0 ]
}

@test "fed_config_load defaults FED_DEPLOY_MODE and the minio channel" {
  fed_config_load "$ENVFILE"
  [ "$FED_DEPLOY_MODE" = "auto" ]
  [ "$FED_MINIO_CHANNEL" = "ckf-1.9/stable" ]
}

@test "fed_config_load defaults the mlflow and mysql channels" {
  fed_config_load "$ENVFILE"
  [ "$FED_MLFLOW_CHANNEL" = "2.15/stable" ]
  [ "$FED_MYSQL_CHANNEL" = "8.0/stable" ]
  [ "$FED_MYSQL_PROFILE" = "testing" ]
}

@test "fed_config_load defaults the temporal and postgresql channels" {
  fed_config_load "$ENVFILE"
  [ "$FED_TEMPORAL_CHANNEL" = "1.23/stable" ]
  [ "$FED_TEMPORAL_ADMIN_CHANNEL" = "1.23/stable" ]
  [ "$FED_TEMPORAL_UI_CHANNEL" = "1.23/stable" ]
  [ "$FED_POSTGRESQL_CHANNEL" = "14/stable" ]
}

@test "fed_config_load defaults the training channel" {
  fed_config_load "$ENVFILE"
  [ "$FED_TRAINING_CHANNEL" = "1.8/stable" ]
}

@test "fed_config_load defaults the kfp charm-family channels" {
  fed_config_load "$ENVFILE"
  [ "$FED_KFP_CHANNEL" = "2.15/stable" ]
  [ "$FED_MLMD_CHANNEL" = "ckf-1.10/stable" ]
  [ "$FED_ENVOY_CHANNEL" = "2.4/stable" ]
  [ "$FED_ARGO_CHANNEL" = "3.7/stable" ]
}

@test "fed_config_load pins every charm revision on the default channels" {
  fed_config_load "$ENVFILE"
  [ "$FED_MINIO_REVISION" = "383" ]
  [ "$FED_MLFLOW_REVISION" = "762" ]
  [ "$FED_MYSQL_REVISION" = "423" ]
  [ "$FED_TEMPORAL_REVISION" = "68" ]
  [ "$FED_TEMPORAL_ADMIN_REVISION" = "28" ]
  [ "$FED_TEMPORAL_UI_REVISION" = "31" ]
  [ "$FED_POSTGRESQL_REVISION" = "925" ]
  [ "$FED_TRAINING_REVISION" = "545" ]
  [ "$FED_KFP_API_REVISION" = "2557" ]
  [ "$FED_KFP_PERSISTENCE_REVISION" = "2568" ]
  [ "$FED_KFP_SCHEDWF_REVISION" = "2575" ]
  [ "$FED_KFP_VIEWER_REVISION" = "2598" ]
  [ "$FED_KFP_VIZ_REVISION" = "2513" ]
  [ "$FED_KFP_UI_REVISION" = "2575" ]
  [ "$FED_KFP_METADATA_WRITER_REVISION" = "1623" ]
  [ "$FED_MLMD_REVISION" = "441" ]
  [ "$FED_ENVOY_REVISION" = "576" ]
  [ "$FED_ARGO_REVISION" = "939" ]
}

@test "fed_config_load drops the pinned revision when the channel is overridden" {
  echo "FED_KFP_CHANNEL=2.16/stable" >> "$ENVFILE"
  fed_config_load "$ENVFILE"
  [ -z "$FED_KFP_API_REVISION" ]
  [ -z "$FED_KFP_VIZ_REVISION" ]
  [ "$FED_MLMD_REVISION" = "441" ]
}

@test "fed_config_load keeps an explicitly empty revision floating" {
  echo "FED_MYSQL_REVISION=" >> "$ENVFILE"
  fed_config_load "$ENVFILE"
  [ -z "$FED_MYSQL_REVISION" ]
}

@test "fed_config_load keeps a consumer-supplied revision" {
  echo "FED_MYSQL_REVISION=400" >> "$ENVFILE"
  fed_config_load "$ENVFILE"
  [ "$FED_MYSQL_REVISION" = "400" ]
}
