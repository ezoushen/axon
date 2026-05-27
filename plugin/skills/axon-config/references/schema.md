# axon.config.yml Schema

> Source: `config.example.yml` and `cmd/config.sh` in the AXON repo.

## Contents
- [product](#product)
- [registry (docker)](#registry-docker)
- [servers](#servers)
- [nginx](#nginx)
- [environments](#environments)
- [docker (tuning)](#docker-tuning)
- [health_check](#health_check)
- [deployment](#deployment)
- [static](#static)
- [Env-var expansion](#env-var-expansion)
- [Validation](#validation)

Legend: **[R]** required, **[O]** optional (default shown). Mode gates noted as `[R docker]` / `[R static]`.

## product

```yaml
product:
  name: "my-product"       # [R] used for image/container naming
  type: "docker"           # [R] "docker" | "static" (default docker)
  description: "My App"    # [O] documentation only
```

## registry (docker)

Only for `type: docker`. `provider` selects the block to read.

```yaml
registry:
  provider: "aws_ecr"   # [R] docker_hub | aws_ecr | google_gcr | azure_acr
  aws_ecr:
    region: "${AWS_REGION:-ap-northeast-1}"  # [R] env-var w/ default ok
    account_id: "${AWS_ACCOUNT_ID}"          # [R]
    repository: "my-product"                 # [O] default product.name
    profile: "default"                       # [O] AWS CLI profile
```

Other providers (uncomment the matching block):
- `docker_hub`: `username`, `access_token` [O, env-var], `namespace` [O default username], `repository` [O].
- `google_gcr`: `project_id` [R], `location` [O us/eu/asia], `use_artifact_registry` [O false], `service_account_key` [O], `repository` [O].
- `azure_acr`: `registry_name` [R, without `.azurecr.io`], `service_principal_id`/`service_principal_password` [O env-var], `repository` [O].

## servers

```yaml
servers:
  system:                              # [R] both modes — nginx + (static) files
    host: "system.example.com"         # [R]
    user: "ubuntu"                     # [R] SSH user
    ssh_key: "~/.ssh/system_key"       # [R] local path, must exist (~ expanded)
  application:                         # [R docker] — runs containers
    host: "app.example.com"            # [R docker] SSH endpoint
    private_ip: "10.0.1.10"            # [R docker] nginx upstream target (VPC IP)
    user: "ubuntu"                     # [R docker]
    ssh_key: "~/.ssh/app_key"          # [R docker]
```

System Server and Application Server may be the same host (set both to the same values).

## nginx

```yaml
nginx:
  domain:
    production: "example.com"          # [O] per-env domain
    staging: "staging.example.com"     # [O]
  ssl:
    production:
      certificate: "/etc/ssl/certs/example.com.crt"        # [R for HTTPS]
      certificate_key: "/etc/ssl/private/example.com.key"  # [R for HTTPS]
  proxy:
    timeout: 60            # [O] seconds (default 60)
    buffer_size: "128k"    # [O] default 128k
    buffers: "4 256k"      # [O] default 4 256k
    busy_buffers_size: "256k"  # [O] default 256k
  # custom_properties: |   # [O] raw nginx directives injected into server block
  paths:
    config: "/etc/nginx/nginx.conf"  # [O] default /etc/nginx/nginx.conf
    axon_dir: "/etc/nginx/axon.d"    # [O] default /etc/nginx/axon.d
```

## environments

Keyed by environment name (`production`, `staging`, custom). Fields differ by mode.

```yaml
environments:
  production:
    # docker mode:
    env_path: "/home/ubuntu/apps/my-product/.env.production"  # [R docker] remote .env on App Server
    image_tag: "production"                                   # [O docker] default = env name
    # build_args: { KEY: value }                              # [O docker] build-time vars

    # static mode:
    build_command: "npm run build:production"  # [R static]
    build_output_dir: "dist"                   # [R static] relative to project root
    deploy_path: "/var/www/my-product-prod"    # [R static] on System Server
    domain: "example.com"                      # [R static] nginx domain
```

## docker (tuning)

`type: docker` only; all optional.

```yaml
docker:
  dockerfile: "Dockerfile"          # [O]
  container_port: 3000              # [O] internal app port (default 3000)
  restart_policy: "unless-stopped"  # [O]
  shutdown_timeout: 30              # [O] seconds
  network_driver: "bridge"          # [O]
  network_name: "application"       # [O] supports template vars
  network_alias: "app"              # [O] stable DNS; ${PRODUCT_NAME}, ${ENVIRONMENT} vars
  env_vars: { KEY: value }          # [O]
  extra_hosts: ["host:ip"]          # [O]
  logging:
    driver: "json-file"  # [O]
    max_size: "10m"      # [O]
    max_file: 3          # [O]
  # compose_override: |  # [O] raw docker-compose YAML override
```

## health_check

All optional.

```yaml
health_check:
  enabled: true            # [O] default true
  endpoint: "/api/health"  # [O] default /api/health
  # command: [...]         # [O] custom check (default wget-based)
  # Docker native check tuning:
  interval: "30s"          # [O]
  timeout: "10s"           # [O]
  retries: 3               # [O]
  start_period: "40s"      # [O]
  # AXON polling after start:
  max_retries: 30          # [O]
  retry_interval: 2        # [O] seconds
```

## deployment

```yaml
deployment:
  graceful_shutdown_timeout: 30  # [O] seconds (default 30)
  enable_auto_rollback: true     # [O] rollback on failed deploy (default true)
```

## static

`type: static` only; all optional.

```yaml
static:
  deploy_user: "www-data"   # [O] file owner (default www-data)
  keep_releases: 5          # [O] releases to retain (default 5)
  shared_dirs: ["uploads"]  # [O] persisted across deployments
  required_files: ["index.html"]  # [O] must exist in build output
```

## Env-var expansion

Any value supports `${VAR}` (must be set) and `${VAR:-default}` (fallback). Resolved at config-load time from the local environment. Use for secrets and per-machine values — registry credentials, account IDs, regions. Keep secrets out of the committed file.

## Validation

```bash
axon config validate            # report errors (exit 1) + warnings (exit 0)
axon config validate --strict   # warnings also fail (exit 1)
```

## Anti-patterns

- **Putting `domain` only in `environments.<env>` for docker mode** — docker reads `nginx.domain.<env>`; the env-level `domain` is the static-mode field.
- **Omitting `application.private_ip`** — nginx then has no upstream to proxy to. Required in docker mode even if it equals `host`.
- **Committing resolved secrets** — leave `${VAR}` placeholders; resolve from the environment.
