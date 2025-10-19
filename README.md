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
- ✅ **Flexible workflows** - Separate or combined build/push/deploy steps

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
axon setup local
```

**Auto-install missing tools:**
```bash
axon setup local --auto-install
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

**Quick start (copy example):**
```bash
axon init-config
# Then edit deploy.config.yml with your product settings
```

**Interactive mode (recommended for first-time setup):**
```bash
axon init-config --interactive
# Follow the prompts to configure step-by-step
```

**Custom filename:**
```bash
axon init-config --file production.yml
axon init-config --interactive --file staging.yml
```

### 4. Validate Configuration

```bash
axon validate
axon validate --config my-config.yml
axon validate --strict  # Treat warnings as errors
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
# Full pipeline (recommended)
axon run production
axon run staging --config my-config.yml

# Individual steps (if needed)
axon build production
axon push production
axon deploy production

# Convenience commands
axon build-and-push staging         # Build + Push (CI/CD)
axon validate                        # Validate config first
```

## Directory Structure

```
axon/
├── README.md                    # This file
├── axon                      # Main entry point: build → push → deploy
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

**Key configurables:**
- Dockerfile path (supports custom locations like `docker/Dockerfile.prod`)
- Container ports, networking, health checks
- Environment variables, logging, restart policies
- AWS ECR settings, SSH keys, server hosts

See `deploy/config.example.yml` for all available options with `[REQUIRED]` and `[OPTIONAL]` markings.

## Usage

AXON uses a subcommand interface: `axon <command> [environment] [options]`

### Core Commands

```bash
# Full deployment pipeline (build → push → deploy)
axon run production                     # Auto-detect git SHA
axon run staging --skip-git             # Skip git SHA tagging
axon run production --sha abc123        # Use specific git SHA
axon run staging --config custom.yml    # Custom config

# Individual steps
axon build production                   # Build image only
axon push staging                       # Push to ECR only
axon deploy production                  # Deploy only (pulls from ECR)
```

### Convenience Commands

```bash
# Build and push (skip deploy) - great for CI/CD
axon build-and-push production
```

### Monitoring & Utilities

```bash
# Status and health
axon status                             # All environments
axon status production                  # Specific environment
axon health                             # Check all health
axon health staging                     # Check specific health

# Logs
axon logs production                    # View logs
axon logs staging --follow              # Follow logs in real-time
axon logs production --lines 100        # Last 100 lines

# Operations
axon restart production                 # Restart container
axon validate                           # Validate config file
axon validate --strict                  # Strict validation

# Configuration
axon init-config                        # Generate deploy.config.yml
axon init-config --interactive          # Interactive config generation
axon init-config --file custom.yml      # Custom filename
```

### Setup Commands

```bash
# Setup local machine (check/install tools)
axon setup local                        # Check what's missing
axon setup local --auto-install         # Auto-install missing tools

# Setup servers (via SSH, requires config)
axon setup app-server                   # Setup Application Server
axon setup system-server                # Setup System Server (nginx)
axon setup app-server --config custom.yml
```

### Global Options

```bash
-c, --config FILE      # Config file (default: deploy.config.yml)
-v, --verbose          # Verbose output
--dry-run              # Show what would be done
-h, --help             # Show help
--version              # Show AXON version
```

### Command-Specific Help

```bash
axon --help                    # Show all commands
axon build --help              # Show build options
axon deploy --help             # Show deploy options
```

### Examples

```bash
# Production deployment
axon run production

# Staging with custom config and no git SHA
axon run staging --config custom.yml --skip-git

# Build production image without cache
axon build production --no-cache

# Force deploy (cleanup existing containers)
axon deploy staging --force

# View verbose output during build
axon build production --verbose

# Check what would happen (dry-run)
axon run staging --dry-run
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
