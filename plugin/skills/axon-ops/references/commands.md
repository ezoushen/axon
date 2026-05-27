# AXON Operations Command Reference

> Source: `lib/command-parser.sh` help text and `cmd/*.sh` in the AXON repo.

## Contents
- [Deployment](#deployment)
- [Inspection](#inspection)
- [Lifecycle](#lifecycle)
- [Recovery & teardown](#recovery--teardown)
- [Common flags](#common-flags)
- [Diagnostic playbooks](#diagnostic-playbooks)

All commands: `axon <command> <environment|--all> [options]`. Global: `-c, --config FILE`, `-v, --verbose`. Env-required commands fail without an `<env>` or `--all`: build, push, deploy, run, build-and-push, logs, restart, sync.

## Deployment

| Command | Purpose | Key flags |
|---|---|---|
| `axon run <env>` | Full pipeline build → push → deploy (primary command) | `--skip-git`, `--sha <hash>`, `-f/--force` (force cleanup during deploy) |
| `axon deploy <env>` | Deploy using image already in registry, zero-downtime | `-f/--force` (cleanup existing containers), `--timeout <seconds>` (health check) |
| `axon build <env>` | Build Docker image locally | `--skip-git`, `--sha <hash>`, `--no-cache` |
| `axon push <env>` | Push built image to registry | `--sha <hash>` |
| `axon build-and-push <env>` | Combined build + push (CI/CD) | — |

`--sha <hash>` pins the git SHA used for image tagging — the lever for redeploying a specific known-good commit.

## Inspection

| Command | Purpose | Key flags |
|---|---|---|
| `axon status <env\|--all>` | Docker-level state: container state, ports, resource usage, Dockerfile HEALTHCHECK history. No HTTP request. | `--detailed`/`--inspect`, `--configuration`/`--env`, `--health` (combinable) |
| `axon health <env\|--all>` | Application-level: HTTP request to the configured endpoint (e.g. `/api/health`) | — |
| `axon logs <env\|--all>` | Container logs | `-f/--follow`, `-n/--lines <n>`, `--since <time>` |

`status --health` shows Docker's HEALTHCHECK config/history; `health` actively probes the app endpoint. Different layers.

## Lifecycle

| Command | Purpose | Key flags |
|---|---|---|
| `axon restart <env\|--all>` | Restart the container(s) | `-f/--force` (skip confirm when `--all`) |
| `axon env edit <env>` | Open `$EDITOR` over SSH on the remote `.env.<env>` (docker) | — |

## Recovery & teardown

| Command | Purpose | Key flags |
|---|---|---|
| `axon sync <env\|--all>` | Re-point nginx upstream at the container's current port. For stale-port recovery after a reboot. Rarely needed with AXON-managed stable ports. | `-f/--force` (sync even if ports already match) |
| `axon delete <env\|--all>` | **Destructive, unrecoverable.** Removes containers, env-tagged images, and nginx site + upstream configs for the environment; reloads nginx. Leaves AXON itself installed. | `-f/--force` (skip confirm), `--all` |

`delete` is not `uninstall` — it removes one environment's deployment, not the AXON install.

## Common flags

- `--all` — operate on every configured environment (status, health, logs, restart, sync, delete).
- `-f/--force` — skip the command's confirmation prompt or force cleanup. Use only when the user explicitly wants prompts skipped.
- `-c/--config FILE` — non-default config path. `--context <name>` / `-c` also resolve which project per the context-resolution order.

## Diagnostic playbooks

**"Production is down."**
1. `axon status production` — is the container running? Check state + ports.
2. `axon logs production -n 100` — recent errors.
3. `axon health production` — does the endpoint respond?
4. If status healthy but unreachable → `axon sync production` (stale nginx port).
5. Report findings with the actual output before mutating anything.

**"Deploy failed."**
- Docker deploys auto-rollback on health-check failure (`deployment.enable_auto_rollback`, default true) — the old container is restored. Read the deploy output to confirm rollback happened, then inspect `axon logs` for the cause before retrying.

**"Roll back to the last good version."**
- No rollback command. Identify the good git SHA/tag, confirm with the user, then `axon run <env> --sha <good-sha>` (rebuild+deploy) or `axon deploy <env>` (re-deploy the prior pushed image).

## Anti-patterns

- **`health` to check liveness** — it probes HTTP; a crashed container shows nothing useful there. Use `status`.
- **`delete` for a fresh start** — destructive and unrecoverable; use `restart`/`run`.
- **Silent `--force`** — it removes the user's confirmation gate; only pass when explicitly requested.
