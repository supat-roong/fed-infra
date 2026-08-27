#!/usr/bin/env bats
load helper

@test "fed-infra contains no consumer-specific identifiers" {
  # --exclude=agnostic.bats: this file's own grep patterns are the literal
  # forbidden strings, so without excluding itself it would always match.
  # --exclude-dir=superpowers/.superpowers: design/plan process docs and the
  # git-ignored SDD scratch workspace legitimately discuss consumer repos
  # (e.g. migration follow-ups); the guard protects the library surface --
  # lib/, bin/, manifests/, kind/, tests/, README -- not project planning
  # prose. Note grep walks the working tree, so gitignored scratch would
  # trip an unexcluded guard even though git never ships it.
  run grep -rIl --exclude-dir=.git --exclude-dir=superpowers \
    --exclude-dir=.superpowers --exclude=agnostic.bats \
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

@test "no bats assertion is silently inert (mid-test [[ ]] without a guard)" {
  # In bats, a `[[ ]]` that is NOT the final statement of a test can fail
  # without failing the test -- only `[ ]` aborts. Verified directly:
  #   [[ 1 -eq 2 ]] mid-test  -> ok      (silently passes)
  #   [  1 -eq 2  ] mid-test  -> not ok
  #   [[ 1 -eq 2 ]] last      -> not ok
  # So every non-final `[[ ]]` needs an explicit `|| return 1`.
  #
  # Test boundaries are found by scanning @test line to @test line, NOT by
  # counting braces: a stray brace inside a comment or quoted string would
  # silently corrupt brace counting and blind this guard -- the exact
  # failure mode it exists to prevent.
  run python3 "$FED_INFRA_ROOT/tests/lint_inert_assertions.py" "$FED_INFRA_ROOT"
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
}
