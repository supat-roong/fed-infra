# fed-infra

Shared Bash library for bootstrapping local Kubernetes-based development
clusters (kind, Kubeflow, MLflow, MinIO). Designed to be consumed as a git
submodule by other repositories; it holds no knowledge of any specific
consumer.

## Layout

- `lib/` — sourceable Bash modules (`fed_`-prefixed functions).
- `bin/` — executable entry points.
- `manifests/`, `kind/` — Kubernetes and kind cluster configuration.
- `tests/` — bats test suite, with command stubs under `tests/stubs/`.

## Requirements

- Bash (targets macOS system Bash 3.2 — no associative arrays, no `${var,,}`,
  no `mapfile`).
- [bats-core](https://github.com/bats-core/bats-core) and
  [shellcheck](https://www.shellcheck.net/) for development.

## Development

```bash
make check   # lint (shellcheck) + test (bats)
make lint    # shellcheck only
make test    # bats only
```

Every function is prefixed `fed_` and must be idempotent — safe to run
repeatedly. Environment variables use the `FED_` prefix.
