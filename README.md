# AXON

Zero-downtime deployment orchestration for Docker + nginx. Deploy instantly, switch seamlessly.

A reusable, config-driven deployment system for achieving zero-downtime deployments across multiple products using Docker, nginx, and AWS ECR.

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

### 1. Install Prerequisites

**Check what's missing:**
```bash
./deploy/setup/setup-local-machine.sh
```

**Auto-install missing tools:**
```bash
./deploy/setup/setup-local-machine.sh --auto-install
```

**Manual installation:**
```bash
# macOS
brew install yq awscli docker node
npm install -g decomposerize

# Linux
# See setup-local-machine.sh for detailed instructions
```

### 2. Add as Git Submodule

```bash
cd your-product
git submodule add git@github.com:your-org/axon.git deploy
git submodule update --init --recursive
```

### 3. Create Product Configuration

```bash
cp config.example.yml deploy.config.yml
# Edit deploy.config.yml with your product settings
```

### 4. Set Up Environment Files

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

### 5. Build, Push, and Deploy

```bash
# Full pipeline: build → push → deploy (uses deploy.config.yml by default)
./axon.sh production

# Use custom config file
./axon.sh --config my-config.yml production

# Or run steps separately:
./tools/build-and-push.sh production  # Build and push image
./tools/deploy.sh production          # Deploy with zero downtime

# With custom config
./tools/build-and-push.sh --config my-config.yml production
./tools/deploy.sh --config my-config.yml production
```

## Directory Structure

```
axon/
├── README.md                    # This file
├── axon.sh                      # Main entry point: build → push → deploy
├── config.example.yml           # Example configuration (copy to deploy.config.yml)
├── setup/
│   └── setup-local-machine.sh  # Install required tools on local machine
├── tools/
│   ├── deploy.sh               # Deployment script (zero-downtime)
│   ├── build.sh                # Build Docker image locally
│   ├── push.sh                 # Push Docker image to ECR
│   ├── build-and-push.sh       # Build and push combined (legacy, calls build.sh + push.sh)
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

1. **Application Server Setup** (15 min)
   ```bash
   ./setup/setup-application-server.sh
   # Or with custom config:
   ./setup/setup-application-server.sh --config custom.yml
   ```

2. **System Server Setup** (30 min)
   ```bash
   ./setup/setup-system-server.sh
   # Or with custom config:
   ./setup/setup-system-server.sh --config custom.yml
   ```

See [Setup Guide](docs/setup.md) for detailed instructions.

## Usage

### Full Deployment Pipeline

Build, push to ECR, and deploy with zero downtime:

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

# Combine multiple flags (order doesn't matter)
./axon.sh --config my-config.yml --skip-git production
```

### Separate Steps

**Build Image Locally:**
```bash
# Build with auto-detected git SHA
./tools/build.sh production

# Build with custom config
./tools/build.sh --config my-config.yml staging

# Build with specific git SHA
./tools/build.sh production abc123

# Build without git SHA tag
./tools/build.sh --skip-git staging
```

**Push Image to ECR:**
```bash
# Push environment tag
./tools/push.sh production

# Push with git SHA tag
./tools/push.sh production abc123

# Push with custom config
./tools/push.sh --config my-config.yml staging
```

**Build and Push Combined:**
```bash
# All-in-one: build + push
./tools/build-and-push.sh production
./tools/build-and-push.sh --config my-config.yml staging abc123
```

**Deploy Only:**
```bash
./tools/deploy.sh production
./tools/deploy.sh --config my-config.yml staging
```

### Monitoring

**View Logs:**
```bash
./tools/logs.sh production           # Last 50 lines
./tools/logs.sh staging follow       # Follow in real-time
./tools/logs.sh all                  # All environments
```

**Check Status:**
```bash
./tools/status.sh                    # All environments
./tools/status.sh production         # Specific environment
./tools/status.sh --config custom.yml staging  # With custom config
```

**Health Check:**
```bash
./tools/health-check.sh              # Check all environments
./tools/health-check.sh staging      # Check specific environment
./tools/health-check.sh --config custom.yml production  # With custom config
```

**Restart Container:**
```bash
./tools/restart.sh production
./tools/restart.sh all
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
- **yq** (YAML processor)
- **Docker** (container runtime)
- **AWS CLI** (for ECR access)
- **Node.js and npm** (for decomposerize)
- **decomposerize** (docker-compose to docker run converter)
- **SSH client** (for server access)

**Quick setup:** Run `./deploy/setup/setup-local-machine.sh` to install all tools automatically.

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

**1. "yq is not installed" error**
- Install `yq` for YAML parsing: `brew install yq` (macOS)
- Linux: See https://github.com/mikefarah/yq#install

**2. "Container not found on Application Server"**
- Check if container exists: `ssh app-server "docker ps -a | grep {product}"`
- Verify env_path in config points to the correct .env file location

**3. "Uncommitted changes" error when building**
```bash
# Commit your changes first:
git add .
git commit -m "Your changes"

# Or use specific git SHA:
./tools/build-and-push.sh staging abc123

# Or skip git SHA tagging:
./tools/build-and-push.sh --skip-git staging
```

**4. Health check fails**
- Verify your app exposes the health endpoint configured in `deploy.config.yml`
- Check container logs: `./tools/logs.sh {environment}`
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
