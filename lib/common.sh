#!/usr/bin/env bash
# common.sh — logging, fatal errors, command checks, retry.
# All output goes to stderr so stdout stays clean for rendered manifests.
#
# Deliberately NOT `set -euo pipefail` here: this file is sourced, not
# executed, and shell options set via `source` leak into the caller's shell.
# Every fed-infra *script* (bin/*, tests/stubs/*) sets its own strict mode;
# a sourced library must not impose one on whatever sources it. Do not add
# `set -euo pipefail` to this file — add a regression test instead if you
# think it's missing.

fed_log()  { printf '\033[0;34m[fed-infra]\033[0m %s\n' "$*" >&2; }
fed_warn() { printf '\033[0;33m[fed-infra]\033[0m %s\n' "$*" >&2; }
fed_die()  { printf '\033[0;31m[fed-infra]\033[0m %s\n' "$*" >&2; exit 1; }

fed_require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || fed_die "required command not found: $c"
  done
}

fed_retry() {
  local attempts=$1 delay=$2
  shift 2
  local i=1
  while [ "$i" -le "$attempts" ]; do
    if "$@"; then return 0; fi
    if [ "$i" -lt "$attempts" ]; then
      fed_warn "attempt $i/$attempts failed: $* (retrying in ${delay}s)"
      sleep "$delay"
    fi
    i=$((i + 1))
  done
  return 1
}
