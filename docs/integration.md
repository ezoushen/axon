# Integration Guide

How to integrate AXON into your product.

## Prerequisites

- Docker installed
- AWS CLI configured with appropriate profile
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

Create `deploy.config.yml` in your product root:

```bash
cd your-product
cp config.example.yml deploy.config.yml
```

Edit `deploy.config.yml` with your product's settings:

```yaml
# Product Information
product:
  name: "my-product"
  description: "My Product"

# AWS Configuration
aws:
  profile: "default"
  region: "ap-northeast-1"
  account_id: "123456789012"
  ecr_repository: "my-product"

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
  image_template: "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPOSITORY}:${IMAGE_TAG}"
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
- No need for AWS variables in `.env` files (they're in `deploy.config.yml`)
- These files contain runtime secrets and should never be committed to Git

## Step 4: Add to .gitignore

```bash
# .gitignore

# Deployment configuration (contains server IPs and secrets)
deploy.config.yml

# Environment files (contain secrets)
.env.production
.env.staging

# But keep the example in Git
!config.example.yml
```

## Step 5: Build, Push, and Deploy

### Full Pipeline (Build → Push → Deploy)

```bash
# Auto-detect git SHA (aborts if uncommitted changes)
./axon.sh production

# Use custom config file
./axon.sh --config my-config.yml production

# Use specific git SHA (ignores uncommitted changes)
./axon.sh production abc123

# Skip git SHA tagging
./axon.sh --skip-git production

# Skip build, only deploy (use existing image)
./axon.sh --skip-build staging
```

### Separate Steps

**Build and Push:**
```bash
# Auto-detect git SHA
./tools/build-and-push.sh production

# Use custom config file
./tools/build-and-push.sh --config my-config.yml staging

# Use specific git SHA
./tools/build-and-push.sh production abc123

# Skip git SHA
./tools/build-and-push.sh --skip-git production
```

**Deploy Only:**
```bash
./tools/deploy.sh production
./tools/deploy.sh --config my-config.yml staging
```

### Monitoring

```bash
# View logs
./tools/logs.sh production
./tools/logs.sh staging follow

# Check status
./tools/status.sh
./tools/status.sh production
./tools/status.sh --config custom.yml staging

# Health check
./tools/health-check.sh
./tools/health-check.sh staging
./tools/health-check.sh --config custom.yml production

# Restart container
./tools/restart.sh production
```

## Directory Structure After Integration

```
your-product/
├──                          # AXON (git submodule)
│   ├── README.md                  # Module documentation
│   ├── axon.sh                    # Main entry point: build → push → deploy
│   ├── config.example.yml         # Example configuration
│   ├── tools/
│   │   ├── deploy.sh             # Deployment script (zero-downtime)
│   │   ├── build-and-push.sh     # Build and push to ECR
│   │   ├── logs.sh               # View logs
│   │   ├── status.sh             # Check status
│   │   ├── restart.sh            # Restart containers
│   │   └── health-check.sh       # Health check
│   ├── lib/
│   │   └── config-parser.sh      # YAML parser
│   └── docs/
│       ├── integration.md        # This file
│       └── setup.md              # Server setup guide
│
├── deploy.config.yml              # Your product configuration (gitignored)
├── .env.production                # On Application Server (gitignored)
├── .env.staging                   # On Application Server (gitignored)
└── ... (rest of your product files)
```

**Note:** No docker-compose files needed! All Docker configuration is in `deploy.config.yml`.

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

1. **Pull Image**: Pull latest image from ECR on Application Server
2. **Generate Container Name**: Create timestamp-based name (`{product}-{env}-{timestamp}`)
3. **Start New Container**: Docker auto-assigns port from ephemeral range (32768-60999)
4. **Wait for Health Check**: Query Docker's health status (native health check)
5. **Update nginx**: Update upstream on System Server to point to new port
6. **Test & Reload nginx**: Zero-downtime reload
7. **Graceful Shutdown**: Shutdown old containers with configurable timeout (SIGTERM → SIGKILL)

**Total Downtime: 0 seconds** ⚡

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
# deploy.config.yml
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
Ensure `deploy.config.yml` exists in your product root, not in the `` directory.

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
./tools/build-and-push.sh staging abc123

# Or skip git SHA tagging:
./tools/build-and-push.sh --skip-git staging
```

### "Health check failed"
- Verify your app exposes the health endpoint configured in `deploy.config.yml`
- Check container logs: `./tools/logs.sh {environment}`
- Test health endpoint locally: `curl http://localhost:3000/api/health`

### "SSH connection failed"
Check SSH key path in `deploy.config.yml` and ensure you have access to Application Server and System Server.

## Best Practices

1. **Keep deploy.config.yml out of Git** - It contains server IPs and paths
2. **Test in staging first** - Always deploy to staging before production
3. **Let git SHA auto-detect** - It validates uncommitted changes automatically
4. **Monitor deployments** - Watch logs during deployment: `./tools/logs.sh production follow`
5. **Health checks** - Ensure your app has the configured health endpoint that returns HTTP 200
6. **Use full pipeline** - `./axon.sh` handles everything (build → push → deploy)

## Example Deployment Workflow

```bash
# 1. Make code changes
git add .
git commit -m "Add new feature"

# 2. Full pipeline: build, push, and deploy to staging
./axon.sh staging

# 3. Verify staging deployment
./tools/health-check.sh staging
./tools/logs.sh staging

# 4. If staging looks good, deploy to production
./axon.sh production

# 5. Monitor production
./tools/status.sh production
./tools/health-check.sh production

# With custom config
./tools/status.sh --config custom.yml production
```

## Advanced Usage

### Deploy Existing Image (Skip Build)

```bash
# Build and push to staging
./tools/build-and-push.sh staging

# Deploy to staging
./tools/deploy.sh staging

# Deploy same image to production without rebuilding
# (manually tag the staging image as production in ECR first)
./axon.sh --skip-build production
```

### Multiple Products on Same Servers

Each product gets its own:
- `deploy.config.yml` in its repository root
- Environment files on Application Server
- Upstream files on System Server (`/etc/nginx/upstreams/{product}-{env}.conf`)

Just ensure each product has a unique `product.name` in its config.

## Support

If you encounter issues with AXON, check:
1. Module documentation: `README.md`
2. Configuration example: `config.example.yml`
3. Server setup guide: `docs/setup.md`
4. Your product configuration: `deploy.config.yml`
