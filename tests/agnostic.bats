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

@test "no bats assertion is silently inert (mid-test [[ ]] without a guard)" {
  # In bats, a `[[ ]]` that is NOT the final statement of a test can fail
  # without failing the test -- only `[ ]` aborts. Verified directly:
  #   [[ 1 -eq 2 ]] mid-test  -> ok      (silently passes)
  #   [  1 -eq 2  ] mid-test  -> not ok
  #   [[ 1 -eq 2 ]] last      -> not ok
  # So every non-final `[[ ]]` needs an explicit `|| return 1`, or the
  # assertion is decorative. This guard finds any that lack one.
  run python3 - "$FED_INFRA_ROOT" <<'PY'
import re, sys, glob, os
root = sys.argv[1]
bad = []
for f in sorted(glob.glob(os.path.join(root, 'tests', '*.bats'))):
    lines = open(f).read().split('\n')
    i = 0
    while i < len(lines):
        if re.match(r'\s*@test ', lines[i]):
            depth = lines[i].count('{') - lines[i].count('}')
            body, j = [], i + 1
            while j < len(lines) and depth > 0:
                depth += lines[j].count('{') - lines[j].count('}')
                if depth > 0: body.append(j)
                j += 1
            stmts = [n for n in body if lines[n].strip()
                     and not lines[n].strip().startswith('#')]
            last = stmts[-1] if stmts else None
            for n in stmts:
                if (re.match(r'\s*\[\[', lines[n]) and n != last
                        and '|| return 1' not in lines[n]):
                    bad.append(f"{os.path.basename(f)}:{n+1}")
            i = j
        else:
            i += 1
if bad:
    print("inert assertions (add '|| return 1'):")
    for b in bad: print(" ", b)
    sys.exit(1)
PY
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
}
