# Zero-Downtime Deployment Module

A reusable, config-driven deployment module for achieving zero-downtime deployments across multiple products using Docker, nginx, and AWS ECR.

## Features

- ✅ **Zero-downtime deployments** - Docker auto-port assignment with rolling updates
- ✅ **Config-driven** - All settings in `deploy.config.yml` (no docker-compose files)
- ✅ **Multi-environment support** - Production, staging, and custom environments
- ✅ **Product-agnostic** - Reusable across multiple projects
- ✅ **AWS ECR integration** - Build, push, and pull images from ECR
- ✅ **Docker native health checks** - Leverages Docker's built-in health status
- ✅ **Git SHA tagging** - Automatic commit tagging with uncommitted change detection
- ✅ **Automatic rollback** - On health check failures
- ✅ **SSH-based coordination** - Updates System Server nginx automatically

## Architecture

```
Internet → System Server (nginx + SSL)  →  Application Server (Docker)
           ├─ Port 443 (HTTPS)              ├─ Timestamp-based containers
           └─ Proxies to apps               └─ Auto-assigned ports (32768-60999)
```

**Key Concepts:**
- **Auto-assigned Ports**: Docker assigns random ephemeral ports (no manual port management)
- **Timestamp-based Naming**: Containers named `{product}-{env}-{timestamp}` for uniqueness
- **Rolling Updates**: New container starts → health check passes → nginx switches → old container stops
- **Config-driven**: Single `deploy.config.yml` defines all Docker runtime settings

**Note:** The System Server and Application Server can be the same physical instance. In this configuration, nginx and Docker run on the same machine, simplifying infrastructure management. The deployment scripts still run from your local machine and SSH to the combined server - you'll just configure the same host for both server settings in `deploy.config.yml`. This setup is ideal for smaller deployments while maintaining the same zero-downtime deployment process.

## Quick Start

### 1. Add as Git Submodule

```bash
cd your-product
git submodule add git@github.com:your-org/deployment-module.git deploy
git submodule update --init --recursive
```

### 2. Create Product Configuration

```bash
cp deploy/config.example.yml deploy.config.yml
# Edit deploy.config.yml with your product settings
```

### 3. Set Up Environment Files

Create environment-specific `.env` files on your Application Server:

```bash
# SSH to Application Server
ssh ubuntu@your-app-server

# Create .env files in deploy path
cat > /home/ubuntu/apps/your-product/.env.production <<EOF
DATABASE_URL=your-production-db-url
API_KEY=your-production-api-key
EOF

cat > /home/ubuntu/apps/your-product/.env.staging <<EOF
DATABASE_URL=your-staging-db-url
API_KEY=your-staging-api-key
EOF
```

### 4. Build, Push, and Deploy

```bash
# Full pipeline: build → push → deploy
./deploy/deploy-full.sh production

# Or run steps separately:
./deploy/scripts/build-and-push.sh production  # Build and push image
./deploy/deploy.sh production                  # Deploy with zero downtime
```

## Directory Structure

```
deployment-module/
├── README.md                    # This file
├── deploy.sh                    # Main deployment script (zero-downtime)
├── deploy-full.sh               # Full pipeline: build → push → deploy
├── config.example.yml           # Example configuration (copy to deploy.config.yml)
├── scripts/
│   ├── build-and-push.sh       # Build Docker image and push to ECR
│   ├── health-check.sh         # Health check verification (via SSH)
│   ├── logs.sh                 # View container logs (via SSH)
│   ├── restart.sh              # Restart containers (via SSH)
│   └── status.sh               # Check container status (via SSH)
└── lib/
    └── config-parser.sh        # YAML configuration parser
```

**Note**: All scripts run from your **local machine** and use SSH to manage remote servers.

## Product Integration

### Configuration File (`deploy.config.yml`)

Each product creates a `deploy.config.yml` in their repository root. This is the **single source of truth** for all deployment settings

### No Docker Compose Files Needed!

The deployment system **automatically generates** docker run commands from `deploy.config.yml`. You don't need to maintain docker-compose files - all Docker settings are in the config.

## Setup Guide

### One-Time Setup

1. **System Server Setup** (30 min)
   ```bash
   ./deploy/setup/setup-system-server.sh
   ```

2. **Application Server Setup** (15 min)
   ```bash
   ./deploy/setup/setup-app-server.sh
   ```

3. **SSH Configuration** (15 min)
   ```bash
   ./deploy/setup/setup-ssh.sh
   ```

See [Setup Guide](docs/setup.md) for detailed instructions.

## Usage

### Full Deployment Pipeline

Build, push to ECR, and deploy with zero downtime:

```bash
# Auto-detect git SHA (aborts if uncommitted changes)
./deploy/deploy-full.sh production

# Use specific git SHA (ignores uncommitted changes)
./deploy/deploy-full.sh production abc123

# Skip git SHA tagging
./deploy/deploy-full.sh production --skip-git

# Skip build, only deploy (use existing image)
./deploy/deploy-full.sh staging --skip-build
```

### Separate Steps

**Build and Push Image:**
```bash
# Auto-detect git SHA
./deploy/scripts/build-and-push.sh staging

# Use specific git SHA
./deploy/scripts/build-and-push.sh staging abc123

# Skip git SHA
./deploy/scripts/build-and-push.sh staging --skip-git
```

This creates two image tags:
- `linebot-nextjs:staging` (environment tag)
- `linebot-nextjs:abc123` (git SHA tag)

**Deploy Only:**
```bash
./deploy/deploy.sh production
./deploy/deploy.sh staging
```

### Monitoring

**View Logs:**
```bash
./deploy/scripts/logs.sh production           # Last 50 lines
./deploy/scripts/logs.sh staging follow       # Follow in real-time
./deploy/scripts/logs.sh all                  # All environments
```

**Check Status:**
```bash
./deploy/scripts/status.sh                    # All environments
./deploy/scripts/status.sh production         # Specific environment
```

**Health Check:**
```bash
./deploy/scripts/health-check.sh              # Check all environments
./deploy/scripts/health-check.sh staging      # Check specific environment
```

**Restart Container:**
```bash
./deploy/scripts/restart.sh production
./deploy/scripts/restart.sh all
```

## Requirements

### System Server
- nginx installed
- SSH access
- sudo permissions for nginx reload
- `/etc/nginx/upstreams/` directory

### Application Server
- Docker and Docker Compose installed
- AWS CLI configured
- SSH access to System Server
- Network access to System Server

### Local Machine
- Docker installed
- AWS CLI configured
- SSH access to Application Server

## How It Works

### Deployment Flow

1. **Detect Current Deployment**: Query nginx on System Server for active port
2. **Generate Container Name**: Create timestamp-based name (`{product}-{env}-{timestamp}`)
3. **Pull Image**: Pull latest image from ECR on Application Server
4. **Start New Container**:
   - Docker auto-assigns port (32768-60999)
   - Container starts with health check configured
5. **Wait for Health Check**: Query Docker's health status (not manual curl)
6. **Update nginx**: Update upstream on System Server to point to new port
7. **Test nginx Config**: Validate before reloading
8. **Reload nginx**: Zero-downtime reload
9. **Graceful Shutdown**: Old containers shut down gracefully (see [Graceful Shutdown Guide](docs/graceful-shutdown.md))

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
  - `{repository}:{environment}` (e.g., `linebot-nextjs:production`)
  - `{repository}:{git-sha}` (e.g., `linebot-nextjs:a1b2c3d`)
- Git SHA tag is code-specific, not environment-specific (promotes image reuse)

## Advanced Topics

- **[Network Aliases](docs/network-aliases.md)** - Stable DNS names for container-to-container communication
- **[Graceful Shutdown](docs/graceful-shutdown.md)** - Proper shutdown handling for zero data loss

## Troubleshooting

### Common Issues

**1. "No environments found in config"**
- Install `yq` for accurate YAML parsing: `brew install yq`
- Or ensure environment names are properly indented (2 spaces) in config

**2. "Container not found on Application Server"**
- Check if container exists: `ssh app-server "docker ps -a | grep {product}"`
- Verify env_path in config points to the correct .env file location

**3. "Image Tag shows wrong environment"**
- Install `yq`: `brew install yq`
- Without yq, the fallback parser may pick the first `image_tag` it finds

**4. "Uncommitted changes" error when building**
```bash
# Commit your changes first:
git add .
git commit -m "Your changes"

# Or use specific git SHA:
./deploy/scripts/build-and-push.sh staging abc123

# Or skip git SHA tagging:
./deploy/scripts/build-and-push.sh staging --skip-git
```

**5. Health check fails**
- Verify your app exposes the health endpoint configured in `deploy.config.yml`
- Check container logs: `./deploy/scripts/logs.sh {environment}`
- Test health endpoint locally: `curl http://localhost:3000/api/health`

## Contributing

This module is designed to be product-agnostic and reusable. When contributing:

1. Keep scripts generic (use configuration, not hardcoded values)
2. Update documentation
3. Test with multiple products
4. Follow existing code style

## License

ISC

## Support

For issues and questions, please open an issue in the repository.
