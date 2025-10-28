# Integration Guide

How to integrate AXON into your product.

## Prerequisites

- Docker installed
- Registry-specific CLI configured (AWS CLI, gcloud, Azure CLI, or none for Docker Hub)
- SSH access between Application Server and System Server
- nginx running on System Server

## Step 1: Add AXON to Your Product

### Option A: As a Git Submodule (Recommended)

```bash
cd your-product
git submodule add <axon-repo-url> deploy
git submodule update --init --recursive
```

### Option B: Copy Files Directly

```bash
cd your-product
cp -r /path/to/axon deploy
```

## Step 2: Create Product Configuration

Create `axon.config.yml` in your product root:

```bash
cd your-product
cp config.example.yml axon.config.yml
```

Edit `axon.config.yml` with your product's settings:

```yaml
# Product Information
product:
  name: "my-product"
  description: "My Product"

# Container Registry Configuration
# Choose ONE registry provider: docker_hub, aws_ecr, google_gcr, azure_acr
registry:
  provider: "aws_ecr"  # Active provider

  # Docker Hub Configuration (Uncomment to use)
  # docker_hub:
  #   username: "myuser"
  #   access_token: "${DOCKER_HUB_TOKEN}"  # Use env var for security
  #   namespace: "myuser"
  #   repository: "my-product"

  # AWS ECR Configuration (Currently Active)
  aws_ecr:
    profile: "default"
    region: "ap-northeast-1"
    account_id: "123456789012"
    repository: "my-product"

  # Google Container Registry Configuration (Uncomment to use)
  # google_gcr:
  #   project_id: "my-gcp-project"
  #   location: "us"  # us, eu, asia
  #   service_account_key: "~/gcp-service-account.json"  # Optional: uses gcloud CLI if omitted
  #   use_artifact_registry: false  # true for Artifact Registry, false for GCR

  # Azure Container Registry Configuration (Uncomment to use)
  # azure_acr:
  #   registry_name: "myregistry"
  #   service_principal_id: "sp-app-id"  # Optional: uses Azure CLI if omitted
  #   service_principal_password: "${AZURE_SP_PASSWORD}"  # Use env var

# Server Configuration
servers:
  # System Server (nginx + SSL)
  system:
    host: "system.example.com"
    user: "ubuntu"
    ssh_key: "~/.ssh/system_server_key"

  # Application Server (Docker containers)
  application:
    host: "app.example.com"              # Public IP/hostname for SSH
    private_ip: "10.0.1.10"              # Private IP for nginx upstream
    user: "ubuntu"
    ssh_key: "~/.ssh/app_server_key"

# Environment Configurations
environments:
  production:
    env_path: "/home/ubuntu/apps/my-product/.env.production"
    image_tag: "production"

  staging:
    env_path: "/home/ubuntu/apps/my-product/.env.staging"
    image_tag: "staging"

# Health Check Configuration
health_check:
  endpoint: "/api/health"
  interval: "30s"
  timeout: "10s"
  retries: 3
  start_period: "40s"
  max_retries: 30
  retry_interval: 2

# Deployment Options
deployment:
  graceful_shutdown_timeout: 30  # Seconds to wait for old container to shutdown gracefully
  enable_auto_rollback: true

# Docker Configuration
docker:
  # Note: Image URI is auto-generated from registry config
  # No need to specify image_template manually
  container_port: 3000
  restart_policy: "unless-stopped"
  network_name: "${PRODUCT_NAME}-${ENVIRONMENT}-network"
  network_driver: "bridge"
  network_alias: "app"  # Stable DNS name for container-to-container communication
  env_vars:
    NODE_ENV: "production"
    PORT: "3000"
  extra_hosts:
    - "host.docker.internal:host-gateway"
  logging:
    driver: "json-file"
    max_size: "10m"
    max_file: 3
```

**Key Concepts:**
- **Auto-assigned Ports**: Docker automatically assigns random ephemeral ports (no manual port configuration)
- **Network Aliases**: Stable DNS names (e.g., `app`) for container-to-container communication
- **Timestamp-based Naming**: Containers named `{product}-{env}-{timestamp}` for uniqueness
- **Config-driven**: All Docker runtime settings in this file (no docker-compose files needed)

## Step 3: Set Up Environment Files

Create environment-specific `.env` files on your **Application Server**:

```bash
# SSH to Application Server
ssh ubuntu@your-app-server

# Create .env files in deploy path
cat > /home/ubuntu/apps/my-product/.env.production <<EOF
DATABASE_URL=your-production-db-url
API_KEY=your-production-api-key
EOF

cat > /home/ubuntu/apps/my-product/.env.staging <<EOF
DATABASE_URL=your-staging-db-url
API_KEY=your-staging-api-key
EOF
```

**Important Notes:**
- `.env` files live on the Application Server, not in your repository
- No need for registry credentials in `.env` files (they're in `axon.config.yml`)
- These files contain runtime secrets and should never be committed to Git

## Step 4: Add to .gitignore

```bash
# .gitignore

# Deployment configuration (contains server IPs and secrets)
axon.config.yml

# Environment files (contain secrets)
.env.production
.env.staging

# But keep the example in Git
!config.example.yml
```

## Step 5: Build, Push, and Deploy

AXON uses subcommand interface: `axon <command> [environment] [options]`

### Full Pipeline (Build → Push → Deploy)

```bash
# Auto-detect git SHA (recommended)
axon run production

# Use custom config file
axon run production --config my-config.yml

# Use specific git SHA
axon run production --sha abc123

# Skip git SHA tagging
axon run production --skip-git

# With verbose output
axon run staging --verbose
```

### Individual Steps

**Build Image:**
```bash
# Auto-detect git SHA
axon build production

# Use custom config file
axon build staging --config my-config.yml

# Use specific git SHA
axon build production --sha abc123

# Skip git SHA
axon build production --skip-git

# Build without cache
axon build staging --no-cache
```

**Push to Registry:**
```bash
axon push production
axon push staging --config my-config.yml
axon push production --sha abc123
```

**Deploy Only:**
```bash
axon deploy production
axon deploy staging --config my-config.yml
axon deploy production --force
```

**Convenience Commands:**
```bash
# Build and push (skip deploy) - great for CI/CD
axon build-and-push production
```

### Monitoring & Management

```bash
# View logs
axon logs production
axon logs staging --follow
axon logs production --lines 100

# Check status
axon status                      # All environments
axon status production           # Specific environment

# Health check
axon health                      # All environments
axon health staging              # Specific environment

# Restart container
axon restart production

# Validate configuration
axon config validate
axon config validate --strict
```

### Global Options

All commands support these global options:
```bash
-c, --config FILE      # Config file (default: axon.config.yml)
-v, --verbose          # Verbose output
--dry-run              # Show what would be done
-h, --help             # Show help
```

## Directory Structure After Integration

```
your-product/
├── deploy/                        # AXON (git submodule)
│   ├── README.md                  # Module documentation
│   ├── axon                       # Main CLI entry point
│   ├── config.example.yml         # Example configuration
│   ├── cmd/
│   │   ├── build.sh              # Build Docker image
│   │   ├── push.sh               # Push to registry
│   │   ├── deploy.sh             # Deploy (zero-downtime)
│   │   ├── logs.sh               # View logs
│   │   ├── status.sh             # Check status
│   │   ├── restart.sh            # Restart containers
│   │   ├── health-check.sh       # Health check
│   │   └── validate-config.sh    # Config validation
│   ├── lib/
│   │   ├── config-parser.sh      # YAML parser
│   │   └── command-parser.sh     # CLI command parser
│   └── docs/
│       ├── integration.md        # This file
│       ├── setup.md              # Server setup guide
│       ├── graceful-shutdown.md  # Graceful shutdown details
│       └── network-aliases.md    # Network alias guide
│
├── axon.config.yml              # Your product configuration (gitignored)
├── .env.production                # On Application Server (gitignored)
├── .env.staging                   # On Application Server (gitignored)
└── ... (rest of your product files)
```

**Note:** No docker-compose files needed! All Docker configuration is in `axon.config.yml`.

## Updating AXON

If AXON gets updates:

```bash
cd your-product/deploy
git pull origin main
cd ..
git add deploy
git commit -m "Update AXON"
```

## How It Works

### Deployment Flow

1. **Pull Image**: Pull latest image from container registry on Application Server
2. **Generate Container Name**: Create timestamp-based name (`{product}-{env}-{timestamp}`)
3. **Start New Container**: Docker auto-assigns port from ephemeral range (32768-60999)
4. **Wait for Health Check**: Query Docker's health status (native health check)
5. **Update nginx**: Update upstream on System Server to point to new port
6. **Test & Reload nginx**: Zero-downtime reload
7. **Graceful Shutdown**: Shutdown old containers with configurable timeout (SIGTERM → SIGKILL)

### Health Check Approach

The deployment leverages **Docker's native health check**:
- Docker continuously checks container health using `wget` to test your health endpoint
- Deployment script queries Docker's health status with `docker inspect`
- Benefits:
  - ✅ Single source of truth (Docker's health status)
  - ✅ No manual URL construction or port management
  - ✅ More reliable (Docker handles retries internally)
  - ✅ Works even if port assignment changes

### Git SHA Tagging

When building images:
- Script auto-detects current git commit SHA
- Checks for uncommitted changes (aborts if found)
- Creates two image tags:
  - `{repository}:{environment}` (e.g., `my-product:production`)
  - `{repository}:{git-sha}` (e.g., `my-product:a1b2c3d`)
- Git SHA tag is code-specific, not environment-specific (promotes image reuse)

### Network Aliases

**Problem:** Container names change on every deployment due to timestamps.

**Solution:** Configure a stable DNS name via `network_alias`:

```yaml
# axon.config.yml
docker:
  network_alias: "app"
```

**Usage from other containers:**
```bash
# Other containers on the same network can use the alias
curl http://app:3000/api/health

# Instead of the changing container name
curl http://my-product-production-1760809226:3000/api/health
```

**Benefits:**
- Stable DNS name across deployments
- Perfect for multi-container setups (app + database, app + redis)
- Network-isolated (production/staging separate)

## Troubleshooting

### "Configuration file not found"
Ensure `axon.config.yml` exists in your product root, not in the `deploy/` directory.

### "Container not found on Application Server"
- Check if container exists: `ssh app-server "docker ps -a | grep {product}"`
- Verify env_path in config points to the correct .env file location

### "Image Tag shows wrong environment"
- Install `yq`: `brew install yq` (macOS) or `sudo apt install yq` (Ubuntu)
- Without yq, the fallback parser may pick the first `image_tag` it finds

### "Uncommitted changes" error when building
```bash
# Commit your changes first:
git add .
git commit -m "Your changes"

# Or use specific git SHA:
axon build staging --sha abc123
axon push staging --sha abc123

# Or skip git SHA tagging:
axon build staging --skip-git
```

### "Health check failed"
- Verify your app exposes the health endpoint configured in `axon.config.yml`
- Check container logs: `axon logs {environment}`
- Test health endpoint locally: `curl http://localhost:3000/api/health`

### "SSH connection failed"
Check SSH key path in `axon.config.yml` and ensure you have access to Application Server and System Server.

## Best Practices

1. **Keep axon.config.yml out of Git** - It contains server IPs and paths
2. **Test in staging first** - Always deploy to staging before production
3. **Let git SHA auto-detect** - It validates uncommitted changes automatically
4. **Monitor deployments** - Watch logs during deployment: `axon logs production --follow`
5. **Health checks** - Ensure your app has the configured health endpoint that returns HTTP 200
6. **Use full pipeline** - `axon run <env>` handles everything (build → push → deploy)
7. **Validate configuration** - Run `axon config validate` before deploying to catch config issues early

## Example Deployment Workflow

```bash
# 1. Make code changes
git add .
git commit -m "Add new feature"

# 2. Validate configuration (optional but recommended)
axon config validate

# 3. Full pipeline: build, push, and deploy to staging
axon run staging

# 4. Verify staging deployment
axon health staging
axon logs staging

# 5. If staging looks good, deploy to production
axon run production

# 6. Monitor production
axon status production
axon health production

# With custom config
axon status production --config custom.yml
```

## Advanced Usage

### Deploy Existing Image (Deploy Only)

```bash
# Build and push to staging
axon build staging
axon push staging

# Deploy to staging
axon deploy staging

# Or use build-and-push for CI/CD
axon build-and-push staging

# Deploy existing image to production
# (pulls from registry, doesn't rebuild)
axon deploy production
```

### Multiple Products on Same Servers

Each product gets its own:
- `axon.config.yml` in its repository root
- Environment files on Application Server
- Upstream files on System Server (`/etc/nginx/upstreams/{product}-{env}.conf`)

Just ensure each product has a unique `product.name` in its config.

## Support

If you encounter issues with AXON, check:
1. Module documentation: `README.md`
2. Configuration example: `config.example.yml`
3. Server setup guide: `docs/setup.md`
4. Your product configuration: `axon.config.yml`
