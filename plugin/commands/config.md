---
name: "axon:config"
description: Interactively create or repair an axon.config.yml — detect the project, ask only the questions that matter, write the file, and validate
args: "[--file <path>] [--mode docker|static]"
---

Set up an **axon.config.yml** for the user interactively. Load the `axon-config` skill first for the full schema and per-mode requirements, then drive the flow below. Honor `--file` (default `axon.config.yml`) and `--mode` if provided.

## Flow

1. **Inspect the project first** so you can pre-fill and ask fewer questions:
   - Existing config? If `axon.config.yml` (or `--file`) exists, read it and offer to **repair/extend** instead of overwrite. Never clobber without confirmation.
   - Detect mode signal: a `Dockerfile` → likely `docker`; a static build setup (`package.json` with a `build` script, `dist/`/`build/` output) → likely `static`. Confirm with the user.
   - Detect `container_port` from the Dockerfile `EXPOSE`, framework defaults, or `package.json`.

2. **Confirm `product.type`** (`docker` or `static`) — this gates every other question. Use `--mode` if given.

3. **Ask only mode-relevant questions** (see the `axon-config` skill's mode table). Group them; don't ask one-at-a-time where a batch is natural:
   - **Both:** product name; System Server host/user/ssh_key.
   - **docker:** registry provider + that provider's required fields (e.g. ECR region+account_id); Application Server host/private_ip/user/ssh_key; per-env `env_path` + `image_tag`; nginx domain per env; container_port.
   - **static:** per-env `build_command`, `build_output_dir`, `deploy_path`, `domain`; optional `keep_releases`, `shared_dirs`.
   - Which environments to define (default `production`, optionally `staging`).

4. **Prefer env-var placeholders for secrets.** Write `${AWS_ACCOUNT_ID}`, `${DOCKER_HUB_TOKEN}`, etc. rather than literal secrets, and tell the user which env vars to export. Use the `${VAR:-default}` form where a sensible default exists.

5. **Write the file.** Two paths:
   - If the AXON CLI is installed (`command -v axon`), you may run `axon config init --interactive` and let the CLI drive — but only if the user prefers the CLI's own prompts. Otherwise write the YAML directly from the answers (more control, can pre-fill from detection).
   - Match `config.example.yml` ordering and keep `[REQUIRED]`/`[OPTIONAL]` intent. Only emit sections relevant to the chosen mode.

6. **Validate.** Run `axon config validate` (or `--strict`). If `axon` is not installed, say so and recommend `/axon:install`, then do a manual schema check against the `axon-config` skill.

7. **Report** what was written, which env vars the user must set, and next steps:
   ```bash
   axon env edit production        # (docker) edit the remote .env
   axon run production             # build → push → deploy
   ```

## Rules

- Confirm before overwriting an existing config.
- Never write real secrets into the file — use `${ENV_VAR}` and list them for the user.
- Keep the file mode-pure: don't emit docker sections for a static product or vice-versa.
