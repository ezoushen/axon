# Contributing to AXON

Thanks for your interest in contributing! AXON is a config-driven, zero-downtime deployment orchestrator written in Bash 3.2+.

## Quick Start

```bash
# Clone and install
git clone https://github.com/ezoushen/axon.git ~/.axon
sudo mkdir -p /usr/local/bin && sudo ln -s ~/.axon/axon /usr/local/bin/axon

# Run tests
cd ~/.axon && ./tests/run-all-tests.sh
```

## How to Contribute

1. **Fork** the repository
2. **Create a branch**: `git checkout -b feat/my-feature`
3. **Make your changes** (see [Conventions](#conventions))
4. **Run tests**: `./tests/run-all-tests.sh`
5. **Commit** using [semantic commit messages](#commit-guidelines)
6. **Push** and open a Pull Request

## Conventions

- **Bash 3.2** — macOS ships Bash 3.2. No associative arrays, `declare -A`, `mapfile`, or `readarray`. See `docs/conventions.md`.
- **No heavy deps** — Allowed: `bash`, `yq`, `docker`, `git`, `ssh`, `curl`, `envsubst`. No `jq` or Python in hot paths.
- **`set -e` everywhere** — Scripts fail hard on first error.
- **Config is the source of truth** — Everything reads from `axon.config.yml`. No docker-compose files.

## Commit Guidelines

Use semantic commit messages:

```
feat: add zero-downtime rollback for Docker deployments
fix: resolve SSH timeout on slow connections
docs: add environment variable reference
refactor: extract health check logic into shared lib
test: add port manager edge case coverage
```

## Development Setup

Run the full test suite before submitting:

```bash
./tests/run-all-tests.sh
```

## Pull Request Process

1. Ensure all tests pass
2. Update docs if you change behavior or config schema
3. Keep changes focused — one PR per feature/fix
4. PRs require at least one review before merging

## Reporting Issues

Open a [GitHub Issue](https://github.com/ezoushen/axon/issues/new/choose) using the appropriate template.
