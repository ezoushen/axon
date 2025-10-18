# Zero-Downtime Deployment Module

A reusable deployment module for achieving zero-downtime deployments across multiple products using Docker, nginx, and AWS ECR.

## Features

- ✅ **Zero-downtime deployments** - Blue-green deployment strategy with nginx atomic reload
- ✅ **Multi-environment support** - Production, staging, and custom environments with full isolation
- ✅ **Product-agnostic** - Reusable across multiple projects via configuration
- ✅ **AWS ECR integration** - Automatic authentication and image pulling
- ✅ **Automatic rollback** - Reverts on health check or nginx configuration failures
- ✅ **VPC-optimized** - nginx uses private IPs for internal routing
- ✅ **Environment isolation** - Separate Docker Compose projects prevent cross-contamination
- ✅ **Auto-file sync** - Docker-compose files copied automatically from local machine
- ✅ **Direct health checks** - Container testing via localhost, bypassing nginx/SSL complexity
- ✅ **Force cleanup** - Optional flag to remove blocking containers

## Architecture

```
Internet → System Server (nginx + SSL)  →  Application Server (Docker)
           ├─ Port 443                      ├─ Product containers
           └─ Proxies to apps               └─ Blue-green ports
```

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

### 3. Deploy

```bash
./deploy/deploy.sh production
```

## Directory Structure

```
deployment-module/
├── README.md                         # This file
├── config.example.yml                # Example configuration (copy to product root)
├── deploy.sh                         # Main deployment script
├── lib/
│   └── config-parser.sh              # YAML parsing utilities
├── setup/
│   ├── setup-application-server.sh   # One-time Application Server setup
│   └── setup-system-server.sh        # One-time System Server setup
├── scripts/
│   ├── build-and-push.sh             # Build Docker image and push to ECR
│   ├── health-check.sh               # Health check verification (localhost)
│   ├── logs.sh                       # View container logs
│   ├── restart.sh                    # Restart containers
│   └── status.sh                     # Check container status
└── docs/
    └── ...                           # Additional documentation
```

## Product Integration

### Configuration File (`deploy.config.yml`)

Each product creates a `deploy.config.yml` in their repository root:

```yaml
# Product information
product:
  name: "my-product"
  description: "My Application"

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
    host: "system-server.example.com"      # System Server IP or hostname
    user: "ubuntu"                          # SSH user (must exist, SSH key required)
    ssh_key: "~/.ssh/system_server_key"    # SSH private key (must exist)

  # Application Server (Docker containers)
  application:
    host: "app-server.example.com"         # Application Server public IP/hostname (for SSH)
    private_ip: "10.0.1.10"                # Private IP within VPC (for nginx upstream)
    user: "ubuntu"                          # SSH user (must exist, SSH key required)
    ssh_key: "~/.ssh/app_server_key"       # SSH private key (must exist)
    deploy_path: "/home/ubuntu/apps/my-product"  # Deployment directory on Application Server

# Environments
environments:
  production:
    blue_port: 5100
    green_port: 5102
    nginx_upstream_file: "/etc/nginx/upstreams/my-product-production.conf"
    nginx_upstream_name: "my_product_production_backend"
    env_file: ".env.production"
    image_tag: "production"
    docker_compose_file: "docker-compose.production.yml"

  staging:
    blue_port: 5101
    green_port: 5103
    nginx_upstream_file: "/etc/nginx/upstreams/my-product-staging.conf"
    nginx_upstream_name: "my_product_staging_backend"
    env_file: ".env.staging"
    image_tag: "staging"
    docker_compose_file: "docker-compose.staging.yml"

# Health check configuration
health_check:
  endpoint: "/api/health"
  max_retries: 30
  retry_interval: 2
  timeout: 10

# Deployment options
deployment:
  connection_drain_time: 5
  enable_auto_rollback: true
  keep_old_images: 3
```

### Docker Compose Requirements

Products must use environment variables for dynamic port assignment and unique container naming:

```yaml
# docker-compose.production.yml
services:
  app:
    # Container name uses port number (not blue/green)
    container_name: ${PRODUCT_NAME:-my-product}-production-${APP_PORT:-5100}

    # Image from AWS ECR
    image: ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPOSITORY}:production

    # Dynamic port mapping
    ports:
      - "${APP_PORT:-5100}:3000"

    # Load environment variables from .env file
    env_file:
      - .env.production

    # ... rest of your config
```

**Important Notes:**
- Container names use **port numbers** as suffixes (e.g., `my-product-production-5100`)
- The deployment script sets `COMPOSE_PROJECT_NAME="${PRODUCT_NAME}_${ENVIRONMENT}"` to prevent cross-environment interference
- AWS environment variables (AWS_ACCOUNT_ID, AWS_REGION, ECR_REPOSITORY) must be in your `.env` file

### File Locations

**On Local Machine (your repository):**
```
my-product/
├── deploy.config.yml                    # Deployment configuration
├── docker-compose.production.yml        # Copied to server during deployment
├── docker-compose.staging.yml           # Copied to server during deployment
├── .env.production.example              # Template only (DO NOT commit real .env)
├── .env.staging.example                 # Template only (DO NOT commit real .env)
└── deploy/                              # Git submodule (this deployment module)
```

**On Application Server (after deployment):**
```
/home/ubuntu/apps/my-product/
├── docker-compose.production.yml        # Auto-copied from local
├── docker-compose.staging.yml           # Auto-copied from local
├── .env.production                      # Manually created (contains secrets)
└── .env.staging                         # Manually created (contains secrets)
```

**On System Server (after setup):**
```
/etc/nginx/upstreams/
├── my-product-production.conf           # Auto-generated by deployment
└── my-product-staging.conf              # Auto-generated by deployment
```

**Important:**
- ✅ Docker-compose files are **auto-copied** from local machine during each deployment
- ⚠️ `.env` files must be **manually created** on Application Server (one-time setup)
- ❌ Never commit actual `.env` files to git (use `.env.*.example` as templates)
- ✅ No source code needs to exist on Application Server (all code is in Docker images)

## Setup Guide

### Prerequisites

**SSH Keys:**
You must have SSH keys set up before running deployment scripts:

1. **System Server SSH Key** - For accessing nginx server
2. **Application Server SSH Key** - For accessing Docker host

The scripts do NOT generate keys automatically. If keys don't exist, setup scripts will exit with instructions.

**Create keys if needed:**
```bash
# Create System Server key
ssh-keygen -t ed25519 -C 'system-server-key' -f ~/.ssh/system_server_key

# Create Application Server key
ssh-keygen -t ed25519 -C 'app-server-key' -f ~/.ssh/app_server_key

# Copy keys to servers
ssh-copy-id -i ~/.ssh/system_server_key.pub user@system-server
ssh-copy-id -i ~/.ssh/app_server_key.pub user@app-server
```

### Automated Setup

**1. Update Configuration:**
Edit `deploy.config.yml` with your server details and SSH key paths.

**2. Run Setup Scripts:**

```bash
# Setup Application Server (Docker, AWS CLI)
./deploy/setup/setup-application-server.sh

# Setup System Server (nginx upstreams)
./deploy/setup/setup-system-server.sh
```

Both scripts are **idempotent** (safe to re-run) and validate prerequisites before making changes.

See [Setup Guide](docs/setup.md) for detailed instructions.

## Usage

### Deploy to Environment

```bash
./deploy/deploy.sh <environment> [--force]
```

**Options:**
- `--force, -f` - Force cleanup of existing containers blocking the target port

**Examples:**
```bash
# Normal deployment
./deploy/deploy.sh production

# Deploy with forced cleanup
./deploy/deploy.sh staging --force

# Short form
./deploy/deploy.sh production -f
```

**What happens during deployment:**
1. Detects current active port from nginx
2. Determines target deployment slot (toggles between blue/green ports)
3. Pulls latest image from AWS ECR
4. **(Optional with --force)** Removes any containers blocking the target port
5. Starts new container on target port
6. Waits for health check to pass
7. Updates nginx upstream to point to new container
8. Reloads nginx (zero-downtime)
9. Waits for connection draining
10. Stops old container

### Build and Push Image

```bash
./deploy/scripts/build-and-push.sh <environment>
```

### View Logs

```bash
./deploy/scripts/logs.sh <environment> [follow]
```

### Check Status

```bash
./deploy/scripts/status.sh
```

### Manual Rollback

```bash
./deploy/scripts/rollback.sh <environment>
```

See [Usage Guide](docs/usage.md) for detailed usage.

## Requirements

### Local Machine (where you run deployments)
- Docker installed (for building images)
- AWS CLI configured with ECR access
- SSH access to both servers
- `yq` tool (recommended for YAML parsing, falls back to grep/awk if not available)
- SSH keys configured for both servers

### System Server (nginx + SSL)
- nginx installed and running
- SSH access with sudo permissions
- `/etc/nginx/upstreams/` directory (created by setup script)
- User account with sudo access for nginx operations

### Application Server (Docker host)
- Docker and Docker Compose installed
- AWS CLI configured with ECR pull permissions
- SSH access
- User account with Docker permissions
- `.env` files must be created manually (not in git, contains secrets)
- Docker-compose files are auto-copied from local machine during deployment

## How It Works

### Deployment Flow

1. **Configuration Loading**: Parses `deploy.config.yml` for environment-specific settings
2. **Port Detection**: Queries nginx upstream file on System Server to detect active port
3. **Slot Toggle**: Determines target deployment slot (toggles between blue/green ports)
4. **File Preparation**: Auto-copies docker-compose file from local machine to Application Server
5. **Image Pull**: Authenticates with AWS ECR and pulls latest image
6. **Force Cleanup** (if `--force`): Removes any containers blocking the target port
7. **Container Start**: Starts new container with `COMPOSE_PROJECT_NAME` isolation
8. **Health Check**: Tests container directly via localhost (not through nginx)
9. **nginx Update**: Updates upstream file on System Server to point to new port
10. **nginx Test**: Validates nginx configuration before reload
11. **nginx Reload**: Atomic reload with zero downtime
12. **Connection Drain**: Waits for existing connections to complete
13. **Cleanup**: Stops and removes the specific old container (by port-based name)

**Key Features:**
- ✅ **Zero Downtime**: nginx atomic reload ensures uninterrupted service
- ✅ **Environment Isolation**: `COMPOSE_PROJECT_NAME` prevents cross-environment interference
- ✅ **Direct Container Testing**: Health checks bypass nginx/DNS/SSL complexity
- ✅ **VPC-Optimized**: nginx uses private IPs for upstream connections
- ✅ **Automatic Rollback**: Reverts nginx and stops new container on failure

## Troubleshooting

See [Troubleshooting Guide](docs/troubleshooting.md) for common issues and solutions.

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
