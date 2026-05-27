---
name: axon-ops
description: Use when the user wants to operate a deployment managed by AXON — deploy/ship/release, roll back or revert, check status, tail or view logs, test health, restart, fix nginx pointing at a stale port, tear down an environment, or diagnose "why is prod/staging down". Maps the operational intent to the right `axon` subcommand and drives it safely. Applies to projects with an axon.config.yml.
---

# AXON Operations

Drive deployments and day-2 operations through the `axon` CLI. AXON manages **Docker containers** and **static sites** (no Kubernetes, no pods) with zero-downtime switching. All commands run locally and act on remote servers over SSH.

**Precondition:** the project has an `axon.config.yml`. If not, route to `/axon:config`. If `axon` is not installed, route to `/axon:install`.

Most commands take `<environment>` (e.g. `production`, `staging`) or `--all`. Pass `-c <file>` for a non-default config, `-v` for verbose. Read [references/commands.md](references/commands.md) for full flags before running anything unfamiliar.

## Intent → command

| User intent | Command |
|---|---|
| Deploy / ship / release (full build→push→deploy) | `axon run <env>` |
| Deploy an already-built image | `axon deploy <env>` |
| Just build / just push | `axon build <env>` / `axon push <env>` |
| Roll back / revert to a previous version | **No rollback subcommand** — see [Rollback](#rollback) |
| Is it up? container state, ports, resource usage | `axon status <env>` (or `--all`) |
| Is the app actually responding? (HTTP endpoint) | `axon health <env>` |
| View / tail logs | `axon logs <env>` (`-f` follow, `-n` lines, `--since`) |
| Restart the container | `axon restart <env>` |
| nginx serving old/dead port after reboot | `axon sync <env>` |
| Tear down an environment (containers + nginx config) | `axon delete <env>` |
| Edit the remote `.env` (docker) | `axon env edit <env>` |

## status vs health — do not confuse

- `axon status` = **Docker-level** state: container running?, ports, resource usage, Dockerfile `HEALTHCHECK` history. No request to your app. Add `--detailed`, `--configuration`, or `--health`.
- `axon health` = **application-level**: makes real HTTP requests to the configured endpoint (e.g. `/api/health`) to verify the service responds.

Diagnosing "down": run `axon status <env>` first (is the container even up?), then `axon health <env>` (is it serving?). If status is healthy but nginx serves a stale port, `axon sync <env>`.

## Rollback

AXON has **no manual rollback command**. Two facts to apply:

1. **Automatic** (docker): a failed health check during deploy triggers auto-rollback — new container stopped, nginx upstream restored to the old container. Controlled by `deployment.enable_auto_rollback` (default true). Nothing to run.
2. **Manual reversion**: redeploy a known-good version. Rebuild+deploy a specific commit with `axon run <env> --sha <good-sha>`, or deploy the previously-pushed image tag with `axon deploy <env>`. Confirm the target SHA/tag with the user before running.

## Safety rules

1. **Confirm destructive ops before running**: `delete` (irreversible — removes containers, images, nginx configs), `restart --all`, and any `--force`/`deploy --force`. State exactly what will be affected, then proceed only on confirmation. `--force` skips the CLI's own confirmation prompt — do not add it to bypass the user.
2. **Production gets an explicit confirm.** Treat `production` as higher-stakes than `staging`.
3. **Read before acting on failures.** On a failed deploy or "down" report, gather `axon status`/`axon logs`/`axon health` output and report findings before mutating anything.
4. **Report faithfully.** Quote the actual command output. If a deploy failed, say so with the error — do not declare success.

## Anti-patterns

- **Reaching for a "rollback" command** — none exists; use auto-rollback behavior or redeploy a prior SHA/tag.
- **Using `axon health` to check if the container is running** — it tests the HTTP endpoint; a down container needs `axon status`.
- **Adding `--force` to skip prompts** — it suppresses the user's confirmation; only use when the user explicitly asked to skip it.
- **Running `delete` to "restart fresh"** — it's destructive and unrecoverable; `restart` or `run` is almost always what's meant.
