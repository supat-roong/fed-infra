#!/usr/bin/env bats
load helper

@test "fed-infra contains no consumer-specific identifiers" {
  # --exclude=agnostic.bats: this file's own grep patterns are the literal
  # forbidden strings, so without excluding itself it would always match.
  run grep -rIl --exclude-dir=.git --exclude=agnostic.bats \
    -e 'active-fed' -e 'fed-twin' "$FED_INFRA_ROOT"
  [ "$status" -ne 0 ] || {
    echo "consumer-specific strings found in: $output" >&2
    return 1
  }
}

@test "no library uses the set -e hostile '[ test ] && return' idiom" {
  # Under `set -e`, `[ cond ] && return 0` aborts the whole script whenever
  # cond is false, because the && compound evaluates to non-zero.
  run grep -nE '^\s*\[.*\]\s*&&\s*return' "$FED_INFRA_ROOT"/lib/*.sh
  [ "$status" -ne 0 ] || {
    echo "use 'if ...; then return 0; fi' instead:" >&2
    echo "$output" >&2
    return 1
  }
}
