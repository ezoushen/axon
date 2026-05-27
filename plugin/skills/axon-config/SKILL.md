---
name: axon-config
description: Use when creating, editing, validating, or troubleshooting an AXON deployment config (axon.config.yml) — choosing docker vs static mode, wiring registry/server/nginx/environment settings, or interpreting `axon config validate` errors. Covers the full schema, required-vs-optional fields per mode, env-var expansion, and per-environment overrides.
---

# AXON Config (axon.config.yml)

`axon.config.yml` is the single source of truth for an AXON deployment — no docker-compose, no scattered settings. One file defines product, registry, servers, nginx, environments, and runtime tuning. Two deployment modes (`product.type`): **docker** and **static**, which gate different required fields.

To scaffold one interactively, use the `/axon:config` command. To check a file, run `axon config validate` (add `--strict` to fail on warnings).

## Field requiredness depends on mode

`product.type` decides what is required. Read [references/schema.md](references/schema.md) for the full annotated schema; the high-level gates:

| Section | docker mode | static mode |
|---|---|---|
| `product.name`, `product.type` | required | required |
| `registry.*` | required | not used |
| `docker.*` | optional (tuning) | not used |
| `servers.system` | required | required |
| `servers.application` (host, private_ip, user, ssh_key) | required | not used |
| `environments.<env>.env_path` | required | not used |
| `environments.<env>.build_command` / `build_output_dir` / `deploy_path` / `domain` | not used | required |
| `nginx.domain.<env>` | optional | optional (static also takes env-level `domain`) |
| `health_check`, `deployment` | optional | optional |
| `static.*` (keep_releases, shared_dirs, …) | not used | optional |

## Hard rules

1. **`product.type` first.** Pick `docker` or `static` before anything else — it determines which sections are mandatory.
2. **SSH keys must exist locally.** `servers.*.ssh_key` paths are read on the local machine. `~` is expanded.
3. **`application.private_ip` is the nginx upstream target**, distinct from `application.host` (the SSH endpoint). Both required in docker mode.
4. **Env-var expansion** is supported in values: `${VAR}` and `${VAR:-default}`. Use it for secrets (registry creds, account IDs) — do not hardcode them. See [references/schema.md](references/schema.md#env-var-expansion).
5. **Validate before deploying.** `axon config validate` (or `--strict`) after any edit.

## Reference

- Full annotated schema, every section, defaults, and per-provider registry blocks: [references/schema.md](references/schema.md).

## Anti-patterns

- **Filling docker fields in a static config (or vice-versa)** — wrong-mode fields are ignored and the required ones get missed. Branch on `product.type`.
- **Hardcoding secrets** — use `${ENV_VAR}` expansion; keep account IDs/tokens out of the committed file.
- **Confusing `host` and `private_ip`** — `host` is for SSH, `private_ip` is what nginx proxies to.
