#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
load helper

setup() {
  setup_stubs
  source "$FED_INFRA_ROOT/lib/common.sh"
}

@test "sourcing common.sh does not leak shell options into the caller" {
  run bash -c "set +eu; source '$FED_INFRA_ROOT/lib/common.sh'; case \"\$-\" in *e*|*u*) echo LEAKED ;; *) echo CLEAN ;; esac"
  [ "$status" -eq 0 ]
  [ "$output" = "CLEAN" ]
}

@test "fed_log writes to stderr, not stdout" {
  run --separate-stderr bash -c "source '$FED_INFRA_ROOT/lib/common.sh'; fed_log hello"
  [ "$output" = "" ]
  [[ "$stderr" == *"hello"* ]]
}

@test "fed_die exits 1 with the message on stderr" {
  run bash -c "source '$FED_INFRA_ROOT/lib/common.sh'; fed_die boom"
  [ "$status" -eq 1 ]
  [[ "$output" == *"boom"* ]]
}

@test "fed_require_cmd succeeds when all commands exist" {
  run fed_require_cmd kubectl kind
  [ "$status" -eq 0 ]
  # The assertion above passes even without the stub PATH prepend, because a
  # real kubectl/kind usually exist on the host running the tests -- it
  # proves nothing about setup_stubs actually working. Pin down that
  # fed_require_cmd is resolving the stub binaries specifically, which only
  # happens if tests/stubs was actually prepended onto PATH.
  [ "$(command -v kubectl)" = "$FED_INFRA_ROOT/tests/stubs/kubectl" ]
  [ "$(command -v kind)" = "$FED_INFRA_ROOT/tests/stubs/kind" ]
}

@test "fed_require_cmd dies naming the missing command" {
  run bash -c "source '$FED_INFRA_ROOT/lib/common.sh'; fed_require_cmd definitely_not_a_real_cmd"
  [ "$status" -eq 1 ]
  [[ "$output" == *"definitely_not_a_real_cmd"* ]]
}

@test "fed_retry returns 0 as soon as the command succeeds" {
  run fed_retry 3 0 true
  [ "$status" -eq 0 ]
}

@test "fed_retry gives up after the requested attempts" {
  run fed_retry 3 0 false
  [ "$status" -eq 1 ]
}
