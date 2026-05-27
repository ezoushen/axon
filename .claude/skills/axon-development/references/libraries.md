# AXON lib/ Catalog

> Source: `lib/*.sh` in the AXON repo.

Which `lib/` file owns what. **Read the file for exact function signatures before calling** — do not assume argument order. Source what you need at the top of a `cmd/` script (`source "$MODULE_DIR/lib/<file>"`).

| File | Owns | Source when you need to… |
|---|---|---|
| `command-parser.sh` | Command registry (`AXON_VALID_COMMANDS`, `AXON_ENV_REQUIRED_COMMANDS`), `show_help`, `show_command_help`, `validate_command` | Register a subcommand or change help text |
| `config-parser.sh` | `yq`-backed YAML reads with `grep` fallback, env-var expansion, registry URI/image building, product-type detection, per-env static getters | Read any config value or build an image URI |
| `defaults.sh` | `command_exists`, config-with-default getters, nginx domain/proxy getters, env-name normalization, upstream filename/name, release-path + release-name generation | Need a default-backed value or naming helper |
| `context-manager.sh` | Named context (config path + project root) add/use/list/switch | Touch `axon context` behavior |
| `ssh-batch.sh` | Batched SSH: queue commands, execute over one multiplexed connection with output markers, read per-label result/exit-code | Run several remote commands efficiently |
| `ssh-connection.sh` | SSH control-socket multiplexing, connection setup/teardown | Manage the underlying SSH connection |
| `validate-config.sh` | Required/optional field checks, error/warning counters, colored report helpers | Extend `axon config validate` |
| `deploy-docker.sh` | Docker deploy orchestration: pull→run→health-check→nginx switch→graceful stop, auto-rollback | Change Docker deploy flow |
| `deploy-static.sh` | Static build→archive→upload→extract→atomic symlink→cleanup old releases | Change static deploy flow |
| `docker-runtime.sh` | Container lifecycle: build run command, naming, run-with-output, find running container | Touch container run/stop logic |
| `port-manager.sh` | AXON-managed port allocation in 30000–32767, persisted under `/var/lib/axon/{product}/{env}/port` | Change port assignment/persistence |
| `nginx-config.sh` | Generate upstream/site config, write to nginx AXON dir, validate + graceful reload | Change generated nginx config |
| `registry-auth.sh` | Multi-registry auth: Docker Hub, AWS ECR, Google GCR, Azure ACR | Add/change a registry provider |
| `init-config.sh` | Interactive `axon config init` generator | Change guided setup |

## Anti-patterns

- **Calling a lib function from memory** — signatures vary (some take `config_file` as a trailing optional arg). Open the file and read the function first.
- **Re-implementing YAML reads inline** — use `config-parser.sh`/`defaults.sh` getters so the `yq`-then-`grep` fallback and `${VAR}` expansion stay consistent.
- **Bypassing `registry-auth.sh`** — provider auth has per-provider quirks; route through it instead of inlining `aws ecr get-login-password` etc.
