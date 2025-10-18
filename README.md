# Zero-Downtime Deployment Module

A reusable deployment module for achieving zero-downtime deployments across multiple products using Docker, nginx, and AWS ECR.

## Features

- ✅ **Zero-downtime deployments** - Blue-green deployment strategy
- ✅ **Multi-environment support** - Production, staging, and custom environments
- ✅ **Product-agnostic** - Reusable across multiple projects
- ✅ **AWS ECR integration** - Pull images from ECR
- ✅ **Automatic rollback** - On health check failures
- ✅ **SSH-based coordination** - Updates System Server nginx automatically

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
├── README.md                    # This file
├── deploy.sh                    # Main deployment script
├── scripts/
│   ├── build-and-push.sh       # Build and push to ECR
│   ├── health-check.sh         # Health check verification
│   ├── logs.sh                 # View container logs
│   ├── restart.sh              # Restart containers
│   ├── status.sh               # Check container status
│   └── rollback.sh             # Manual rollback utility
├── setup/
│   ├── setup-system-server.sh  # One-time System Server setup
│   ├── setup-app-server.sh     # One-time Application Server setup
│   └── setup-ssh.sh            # SSH key generation and setup
├── templates/
│   ├── nginx-upstream.conf     # nginx upstream template
│   └── docker-compose.tpl.yml  # Docker compose template
├── config.example.yml          # Example configuration
└── docs/
    ├── setup.md                # Setup instructions
    ├── usage.md                # Usage guide
    └── troubleshooting.md      # Common issues
```

## Product Integration

### Configuration File (`deploy.config.yml`)

Each product creates a `deploy.config.yml` in their repository root:

```yaml
# Product information
product:
  name: "linebot-nextjs"
  description: "LINE Bot Next.js Application"

# AWS Configuration
aws:
  profile: "lastlonger"
  region: "ap-northeast-1"
  account_id: "123456789012"
  ecr_repository: "linebot-nextjs"

# Server Configuration
servers:
  system:
    host: "system-server-ip"
    user: "deploy"
    ssh_key: "~/.ssh/deployment_key"
  application:
    host: "application-server-ip"
    user: "ubuntu"

# Environments
environments:
  production:
    blue_port: 5100
    green_port: 5102
    domain: "production.yourdomain.com"
    nginx_upstream_file: "/etc/nginx/upstreams/linebot-production.conf"
    nginx_upstream_name: "linebot_production_backend"
    env_file: ".env.production"
    image_tag: "production"

  staging:
    blue_port: 5101
    green_port: 5103
    domain: "staging.yourdomain.com"
    nginx_upstream_file: "/etc/nginx/upstreams/linebot-staging.conf"
    nginx_upstream_name: "linebot_staging_backend"
    env_file: ".env.staging"
    image_tag: "staging"

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

Products must use environment variables for dynamic port/slot assignment:

```yaml
# docker-compose.production.yml
services:
  app:
    container_name: ${PRODUCT_NAME}-production-${DEPLOYMENT_SLOT:-blue}
    ports:
      - "${APP_PORT:-5100}:3000"
    # ... rest of your config
```

## Setup Guide

### Automated Setup (Recommended)

**Application Server:**
```bash
cd your-product/deploy
./setup/setup-application-server.sh
```

**System Server:**
```bash
# Copy to System Server and run
scp setup/setup-system-server.sh user@system-server:/tmp/
ssh user@system-server
sudo PRODUCT_NAME=myapp APPLICATION_SERVER_IP=10.0.1.100 /tmp/setup-system-server.sh
```

Both scripts are **idempotent** (safe to re-run) and check existing configuration before making changes.

See [Setup Guide](docs/setup.md) for detailed instructions.

## Usage

### Deploy to Environment

```bash
./deploy/deploy.sh <environment>
```

Examples:
```bash
./deploy/deploy.sh production
./deploy/deploy.sh staging
```

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

1. **Port Detection**: Script queries System Server nginx to detect active port
2. **Slot Toggle**: Determines target slot (blue ↔ green)
3. **Image Pull**: Pulls latest image from ECR
4. **Container Start**: Starts new container on target port
5. **Health Check**: Waits for container to pass health checks
6. **nginx Update**: Updates System Server nginx upstream via SSH
7. **nginx Reload**: Reloads nginx (zero-downtime)
8. **Cleanup**: Stops old container after connection draining

**Total Downtime: 0 seconds** ⚡

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
