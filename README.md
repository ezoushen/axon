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
./setup/setup-local-machine.sh
```

**Auto-install missing tools:**
```bash
./setup/setup-local-machine.sh --auto-install
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
cp deploy/config.example.yml deploy.config.yml
# Edit deploy.config.yml with your product settings
```

### 4. Validate Configuration

```bash
./tools/validate-config.sh
./tools/validate-config.sh --config my-config.yml
./tools/validate-config.sh --strict  # Treat warnings as errors
```

### 5. Set Up Environment Files

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

### 6. Build, Push, and Deploy

```bash
# Full pipeline
./axon.sh production
./axon.sh --config my-config.yml staging

# Individual steps
./tools/build.sh production
./tools/push.sh production
./tools/deploy.sh production
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
│   ├── build.sh                # Build Docker image locally
│   ├── push.sh                 # Push Docker image to ECR
│   ├── deploy.sh               # Deploy with zero-downtime
│   ├── validate-config.sh      # Validate configuration file
│   ├── health-check.sh         # Health check verification (via SSH)
│   ├── logs.sh                 # View container logs (via SSH)
│   ├── restart.sh              # Restart containers (via SSH)
│   └── status.sh               # Check container status (via SSH)
└── lib/
    └── config-parser.sh        # YAML configuration parser
```

**Note**: All scripts run from your **local machine** and use SSH to manage remote servers.

## Configuration

All deployment settings are in `deploy.config.yml` (product root). The system auto-generates docker commands from config - no docker-compose files needed.

See `deploy/config.example.yml` for all available options with `[REQUIRED]` and `[OPTIONAL]` markings.

## Usage

### Deploy

```bash
./axon.sh production                    # Full pipeline with git SHA
./axon.sh --skip-git staging           # Skip git SHA tagging
./axon.sh --skip-build production      # Deploy only (use existing image)
./axon.sh --config custom.yml staging  # Custom config
```

### Build & Push

```bash
./tools/build.sh production        # Build with auto-detected git SHA
./tools/build.sh --skip-git staging
./tools/push.sh production         # Push to ECR
```

### Monitor

```bash
./tools/status.sh                  # Check all containers
./tools/logs.sh production         # View logs
./tools/logs.sh staging follow     # Follow logs in real-time
./tools/health-check.sh            # Health check all environments
./tools/restart.sh production      # Restart container
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

**Quick setup:** Run `./setup/setup-local-machine.sh` to install all tools automatically.

## How It Works

1. Pull image from ECR → Start new container (auto-assigned port) → Wait for health check
2. Update nginx upstream → Test config → Reload nginx (zero downtime)
3. Gracefully shutdown old container

**Key Features:**
- Docker auto-assigns ports (32768-60999)
- Timestamp-based container names: `{product}-{env}-{timestamp}`
- Docker native health checks (no manual curl)
- Git SHA auto-tagging with uncommitted change detection

## Troubleshooting

### Common Issues

**1. "yq is not installed" error**
- Install `yq` for YAML parsing: `brew install yq` (macOS)
- Linux: See https://github.com/mikefarah/yq#install

**2. "Container not found on Application Server"**
- Check if container exists: `ssh app-server "docker ps -a | grep {product}"`
- Verify env_path in config points to the correct .env file location

**3. "Uncommitted changes" error**
```bash
git add . && git commit -m "Your changes"      # Commit first
./tools/build.sh --skip-git staging    # Or skip git SHA
```

**4. Health check fails**
- Check logs: `./tools/logs.sh production`
- Verify health endpoint is exposed at configured path
- Test locally: `curl http://localhost:3000/api/health`

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
