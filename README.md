# AXON

Zero-downtime deployment orchestration for Docker + nginx. Deploy instantly, switch seamlessly.

A reusable, config-driven deployment system for achieving zero-downtime deployments across multiple products using Docker, nginx, and any major container registry.

## Features

- ✅ **Zero-downtime deployments** - Docker auto-port assignment with rolling updates
- ✅ **Config-driven** - All settings in `axon.config.yml` (no docker-compose files)
- ✅ **Multi-environment support** - Production, staging, and custom environments
- ✅ **Product-agnostic** - Reusable across multiple projects
- ✅ **Multi-registry support** - Docker Hub, AWS ECR, Google GCR, Azure ACR
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
- **Config-driven**: Single `axon.config.yml` defines all Docker runtime settings

**Note:** The System Server and Application Server can be the same physical instance. In this configuration, nginx and Docker run on the same machine, simplifying infrastructure management. The deployment scripts still run from your local machine and SSH to the combined server - you'll just configure the same host for both server settings in `axon.config.yml`. This setup is ideal for smaller deployments while maintaining the same zero-downtime deployment process.

## Installation

### Quick Install (Recommended)

```bash
# macOS / Linux
curl -fsSL https://raw.githubusercontent.com/ezoushen/axon/main/install.sh | bash

# Or with wget
wget -qO- https://raw.githubusercontent.com/ezoushen/axon/main/install.sh | bash
```

### Homebrew

```bash
# Add tap and install
brew tap ezoushen/axon
brew install axon

# Or install directly
brew install https://raw.githubusercontent.com/ezoushen/axon/main/homebrew/axon.rb
```

### Manual Installation

```bash
# Clone repository
git clone https://github.com/ezoushen/axon.git ~/.axon

# Create symlink
sudo ln -s ~/.axon/axon /usr/local/bin/axon

# Verify
axon --version
```

See [INSTALL.md](INSTALL.md) for detailed installation instructions, including custom locations, prerequisites, and troubleshooting.

## Quick Start

### 1. Install Prerequisites

**Check what's missing:**
```bash
axon install local
```

**Auto-install missing tools:**
```bash
axon install local --auto-install
```

**Manual installation:**
```bash
# macOS - core tools
brew install yq gettext docker node
brew link --force gettext  # For envsubst
npm install -g decomposerize

# Registry-specific CLI (install based on your registry choice)
brew install awscli                      # For AWS ECR
brew install --cask google-cloud-sdk     # For Google GCR
brew install azure-cli                   # For Azure ACR
# Docker Hub: no additional CLI needed

# Linux
# See setup-local-machine.sh for detailed instructions
```

### 2. Add as Git Submodule

```bash
cd your-product
git submodule add git@github.com:ezoushen/axon.git deploy
git submodule update --init --recursive
```

### 3. Create Product Configuration

**Quick start (copy example):**
```bash
axon init-config
# Then edit axon.config.yml with your product settings
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
├── axon                         # Main CLI entry point
├── VERSION                      # Current version number
├── config.example.yml           # Example configuration (copy to axon.config.yml)
├── .github/
│   └── workflows/
│       └── release.yml          # Automated release workflow
├── setup/
│   └── setup-local-machine.sh  # Install required tools on local machine
├── tools/
│   ├── build.sh                # Build Docker image locally
│   ├── push.sh                 # Push Docker image to ECR
│   ├── deploy.sh               # Deploy with zero-downtime
│   ├── validate-config.sh      # Validate configuration file
│   ├── init-config.sh          # Generate axon.config.yml
│   ├── health-check.sh         # Health check verification (via SSH)
│   ├── logs.sh                 # View container logs (via SSH)
│   ├── restart.sh              # Restart containers (via SSH)
│   └── status.sh               # Check container status (via SSH)
├── release/
│   ├── create-release.sh       # Create new version release
│   └── update-homebrew-sha.sh  # Manual Homebrew formula update
├── lib/
│   └── command-parser.sh       # Command parsing and help system
├── homebrew-tap/               # Homebrew tap repository (submodule)
│   └── Formula/
│       └── axon.rb             # Homebrew formula (single source of truth)
└── docs/
    ├── integration.md          # Integration guide
    ├── setup.md                # Server setup guide
    └── RELEASE.md              # Release process documentation
```

**Note**: All scripts run from your **local machine** and use SSH to manage remote servers.

## Configuration

All deployment settings are in `axon.config.yml` (product root). The system auto-generates docker commands from config - no docker-compose files needed.

**Key configurables:**
- Dockerfile path (supports custom locations like `docker/Dockerfile.prod`)
- Container ports, networking, health checks
- Environment variables, logging, restart policies
- Container registry settings (Docker Hub, AWS ECR, GCP, Azure), SSH keys, server hosts

See `deploy/config.example.yml` for all available options with `[REQUIRED]` and `[OPTIONAL]` markings.

## Context Management

AXON provides kubectl-like context management for seamless project switching. Instead of navigating to each project directory, save project configurations as contexts and access them globally.

### Quick Start

```bash
# Add current project as a context
cd ~/projects/my-app
axon context add my-app

# Switch to a context (sets it as active)
axon context use my-app

# Deploy from anywhere without cd
axon deploy production

# Or use one-off override without changing active context
axon --context my-app deploy staging
```

### Context Commands

```bash
# Manage contexts
axon context add <name> [config]       # Add new context
axon context use <name>                # Switch to context
axon context list                      # List all contexts
axon context current                   # Show current context
axon context show <name>               # Show detailed info
axon context validate <name>           # Validate configuration
axon context remove <name>             # Remove context

# Import/export (for team sharing or backup)
axon context export <name>             # Export to YAML file
axon context import <file> --name <name>  # Import from file
```

### Context Resolution

AXON resolves which configuration to use in this order:

1. **Explicit `-c` flag** (highest priority)
   ```bash
   axon -c custom.yml deploy production
   ```

2. **One-off `--context` override**
   ```bash
   axon --context backend deploy staging
   ```

3. **Local `axon.config.yml`** in current directory
   ```bash
   cd ~/projects/my-app && axon deploy production
   ```

4. **Active context** (via `axon context use`)
   ```bash
   axon context use my-app
   axon deploy production  # Uses my-app context
   ```

5. **Error** if none found

### Use Cases

**Multiple Projects:**
```bash
# Set up contexts once
axon context add frontend ~/projects/frontend/axon.config.yml
axon context add backend ~/projects/backend/axon.config.yml
axon context add mobile ~/projects/mobile/axon.config.yml

# Switch between projects instantly
axon context use frontend
axon deploy production

axon context use backend
axon deploy staging
```

**Team Sharing:**
```bash
# Developer A exports context
axon context export my-app -o team-context.yml

# Developer B imports on their machine
axon context import team-context.yml --name my-app --root ~/dev/my-app
```

**Temporary Override:**
```bash
# Active context is frontend
axon context use frontend

# Quickly check backend status without switching
axon --context backend status

# Active context remains frontend
axon context current  # Shows: frontend
```

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
axon push staging                       # Push to registry only
axon deploy production                  # Deploy only (pulls from registry)
```

### Convenience Commands

```bash
# Build and push (skip deploy) - great for CI/CD
axon build-and-push production
```

### Monitoring & Utilities

```bash
# Status and health
axon status --all                       # All environments (requires --all)
axon status production                  # Specific environment
axon health --all                       # Check all health (requires --all)
axon health staging                     # Check specific health

# Logs
axon logs production                    # View logs
axon logs --all                         # View logs from all environments
axon logs staging --follow              # Follow logs in real-time
axon logs production --lines 100        # Last 100 lines
axon logs --all --lines 50              # Last 50 lines from each environment

# Operations
axon restart production                 # Restart container
axon restart --all                      # Restart all environments (with confirmation)
axon restart --all --force              # Restart all without confirmation
axon delete staging                     # Delete environment (Docker + nginx)
axon delete production --force          # Delete without confirmation
axon delete --all                       # Delete all environments
axon delete --all --force               # Delete all without confirmations
axon validate                           # Validate config file
axon validate --strict                  # Strict validation

# Configuration
axon init-config                        # Generate axon.config.yml
axon init-config --interactive          # Interactive config generation
axon init-config --file custom.yml      # Custom filename
```

### Installation & Uninstallation Commands

```bash
# Install on servers (check/install tools and setup)
axon install                            # Install on all servers
axon install local                      # Check what's missing on local
axon install local --auto-install       # Auto-install missing tools
axon install app-server                 # Install on Application Server
axon install system-server              # Install on System Server (nginx)
axon install app-server --config custom.yml

# Uninstall from servers (cleanup)
axon uninstall                          # Uninstall from all servers
axon uninstall local                    # Remove from local machine
axon uninstall app-server               # Remove from Application Server
axon uninstall system-server            # Remove from System Server
axon uninstall local --force            # Skip confirmations
```

### Global Options

```bash
-c, --config FILE      # Config file (default: axon.config.yml)
--context NAME         # Use context for this command (one-off override)
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

# Use context for one-off command
axon --context backend status
axon --context frontend deploy production
```

## Requirements

### System Server
- nginx installed
- SSH access
- sudo permissions for nginx reload
- `/etc/nginx/upstreams/` directory

### Application Server
- Docker and Docker Compose installed
- Registry-specific CLI (AWS CLI, gcloud, az CLI, or none for Docker Hub)
- SSH access to System Server
- Network access to System Server

### Local Machine
- **yq** (YAML processor)
- **envsubst** (environment variable substitution - from gettext package)
- **Docker** (container runtime)
- **Registry CLI** (AWS CLI / gcloud / Azure CLI - depending on provider, optional for Docker Hub)
- **Node.js and npm** (for decomposerize)
- **decomposerize** (docker-compose to docker run converter)
- **SSH client** (for server access)

**Quick install:** Run `axon install local --auto-install` to install all tools automatically.

## How It Works

1. Pull image from container registry → Start new container (auto-assigned port) → Wait for health check
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
axon build staging --skip-git          # Or skip git SHA
```

**4. Health check fails**
- Check logs: `axon logs production`
- Verify health endpoint is exposed at configured path
- Test locally: `curl http://localhost:3000/api/health`

## Contributing

This module is designed to be product-agnostic and reusable. When contributing:

1. Keep scripts generic (use configuration, not hardcoded values)
2. Update documentation
3. Test with multiple products
4. Follow existing code style

### Releasing New Versions

AXON uses a fully automated release process. To create a new release:

```bash
./release/create-release.sh
```

This will guide you through creating a version tag. Once pushed, GitHub Actions automatically:
- Creates the GitHub release
- Generates changelog
- Calculates SHA256 for Homebrew formula
- Updates and commits the Homebrew formula

See [docs/RELEASE.md](docs/RELEASE.md) for detailed release documentation.

## License

ISC

## Support

For issues and questions, please open an issue in the repository.
