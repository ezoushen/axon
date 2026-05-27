---
name: axon-development
description: Use when contributing to or maintaining the AXON deployment CLI (a Bash 3.2 zero-downtime deploy orchestrator) — adding/editing subcommands, touching cmd/ or lib/ scripts, writing tests, parsing config, SSH/nginx/Docker deploy logic, or cutting a release. Encodes AXON's dispatch model, script anatomy, Bash 3.2 hard constraints, test framework, and release flow.
---

# AXON Development

AXON is a config-driven, zero-downtime deployment CLI written in pure Bash (3.2+). It runs from the local machine and drives remote servers over SSH. Two deploy modes: Docker containers and static sites. Single source of truth: `axon.config.yml`.

## Non-negotiable constraints

1. **Bash 3.2 only.** macOS ships Bash 3.2. No `declare -A` (associative arrays), no `${var//a/b}`/`${var,,}` (use `sed`/`tr`), no `mapfile`/`readarray`, no `declare -n`. See [references/conventions.md](references/conventions.md).
2. **No heavy deps.** Allowed runtime tools: `bash`, `yq`, `docker`, `git`, `ssh`, `curl`, `envsubst`. No `jq`, no Python in the hot path. YAML via `yq` with `grep`/`awk` fallback.
3. **`set -e` everywhere.** Every script fails on first error. No try/catch, no silent recovery. Wrap nothing that should fail.
4. **Config is the only source of truth.** No docker-compose, no hardcoded product values. Read everything from `axon.config.yml`.
5. **All scripts run locally, act remotely.** Use the SSH helpers, not ad-hoc `ssh` calls. Batch where possible to cut round-trips.

## Layout

| Dir | Holds | Rule |
|---|---|---|
| `axon` | Entry router + `cmd_*()` dispatch functions | Top-level CLI logic |
| `cmd/` | One `<name>.sh` per user subcommand | If user runs `axon <name>`, it lives here |
| `lib/` | Sourced helpers (config, ssh, deploy, nginx, port) | Called BY scripts, never directly by users |
| `setup/` | Local + remote machine provisioning | Run once at install |
| `release/` | `create-release.sh`, homebrew SHA update | Maintainer-only |
| `tests/` | Custom Bash test framework + suites | See [references/testing.md](references/testing.md) |
| `docs/` | Guides beyond README | Keep in sync with behavior changes |

## Common tasks → reference

- **Add or edit a subcommand** (the 4 mandatory edit points): [references/conventions.md](references/conventions.md#adding-a-subcommand).
- **Script anatomy, output helpers, SSH/config patterns, Bash 3.2 rules**: [references/conventions.md](references/conventions.md).
- **lib/ catalog — which file owns what; read the file for exact signatures**: [references/libraries.md](references/libraries.md).
- **Write/run tests with the custom framework**: [references/testing.md](references/testing.md).
- **Cut a release (VERSION, tag, homebrew-tap CI)**: [references/testing.md](references/testing.md#release).

## Before you finish

- Run the test suite: `./tests/run-all-tests.sh`.
- Sanity-check Bash 3.2: avoid the banned constructs above; if unsure, test under `/bin/bash` on macOS.
- Update `docs/` and `config.example.yml` if behavior or config schema changed.
- Keep new code's color/output style identical to surrounding scripts — there is no central logger by design.
