# AXON

Zero-downtime deployment orchestration for Docker containers and static sites. Deploy instantly, switch seamlessly.

A reusable, config-driven deployment system for achieving zero-downtime deployments across multiple products using Docker, nginx, static site hosting, and any major container registry.

## Features

- ✅ **Zero-downtime deployments** - Atomic symlink switching for static sites, Docker auto-port assignment with rolling updates
- ✅ **Dual deployment modes** - Docker containers and static site hosting
- ✅ **Config-driven** - All settings in `axon.config.yml` (no docker-compose files)
- ✅ **Multi-environment support** - Production, staging, and custom environments
- ✅ **Product-agnostic** - Reusable across multiple projects
- ✅ **Multi-registry support** - Docker Hub, AWS ECR, Google GCR, Azure ACR
- ✅ **Git SHA tagging** - Automatic commit tagging with release name tracking for static sites
- ✅ **Health checks** - Docker native health checks and application HTTP endpoint testing
- ✅ **Automatic rollback** - On health check failures (Docker deployments)
- ✅ **SSH-based coordination** - Updates nginx configurations automatically
- ✅ **Flexible workflows** - Separate or combined build/push/deploy steps

## Architecture

AXON supports two deployment modes with zero-downtime guarantees:

### Docker Container Deployments
```
Internet → System Server (nginx + SSL)  →  Application Server (Docker)
           ├─ Port 443 (HTTPS)              ├─ Timestamp-based containers
           └─ Proxies to apps               └─ Auto-assigned ports (32768-60999)
```
- **Auto-assigned Ports**: Docker assigns random ephemeral ports
- **Timestamp-based Naming**: `{product}-{env}-{timestamp}`
- **Rolling Updates**: New container → health check → nginx switch → old container stops

### Static Site Deployments
```
Internet → System Server (nginx + SSL + static files)
           ├─ Port 443 (HTTPS)
           ├─ Serves from /path/{env}/current → /path/{env}/releases/{timestamp}-{sha}/
           └─ Atomic symlink switching
```
- **Release Management**: Timestamp + git SHA naming (e.g., `20241028135535-abc1234`)
- **Atomic Switching**: Symlink updated atomically for zero-downtime
- **Release History**: Keeps last N releases for quick rollback

**Config-driven**: Single `axon.config.yml` defines all deployment settings for both modes

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

## Quick Start

### 1. Install Prerequisites

```bash
# Check what's missing
axon install local

# Auto-install (recommended)
axon install local --auto-install
```

### 2. Add as Git Submodule

```bash
cd your-product
git submodule add git@github.com:ezoushen/axon.git deploy
git submodule update --init --recursive
```

### 3. Create Product Configuration

```bash
# Interactive setup (recommended)
axon config init --interactive

# Or copy example and edit manually
axon config init

# Validate when done
axon config validate
```

### 4. Set Up Environment Files (Docker deployments)

For Docker deployments, create `.env` files on Application Server using the built-in editor:

```bash
# Edit environment file directly on Application Server
axon env edit production

# Or edit staging environment
axon env edit staging
```

This opens your configured `$EDITOR` (vim/nano) via SSH to edit `.env.production` or `.env.staging` at the path configured in `axon.config.yml`.

For static sites, environment variables are typically injected during build time.

### 5. Build, Push, and Deploy

```bash
# Full pipeline (recommended)
axon run production

# Or individual steps
axon build production
axon push production
axon deploy production
```

## Directory Structure

```
axon/
├── axon                    # Main CLI entry point
├── VERSION                 # Current version number
├── config.example.yml      # Example configuration template
├── cmd/                    # Subcommand implementations (one script per subcommand)
├── lib/                    # Shared libraries and utilities
├── setup/                  # Installation and setup scripts
├── release/                # Release management tools
├── docs/                   # Documentation
└── homebrew-tap/           # Homebrew formula (submodule)
```

### Organization Logic

**`cmd/` - Subcommand Scripts**
- Contains executable scripts for top-level CLI subcommands
- Script naming: matches subcommand name exactly (e.g., `health.sh` for `axon health`)
- Examples: `build.sh`, `deploy.sh`, `status.sh`, `config.sh`, `context.sh`
- Rule: If users can run `axon <name>`, it belongs here

**`lib/` - Shared Libraries & Utilities**
- Reusable functions, parsers, and support code
- Scripts called by multiple subcommands
- Deployment logic, configuration utilities, SSH helpers
- Examples: config-parser.sh, deploy-docker.sh, nginx-config.sh, init-config.sh
- Rule: If it's called BY other scripts (not directly by users), it belongs here

**`setup/` - Installation & Setup**
- Scripts for setting up AXON on local and remote machines
- Server configuration and prerequisite installation
- Run once during initial setup

**`release/` - Release Management**
- Version tagging, changelog generation
- Homebrew formula updates
- Used by maintainers for creating releases

**`docs/` - Documentation**
- Integration guides, setup instructions, release notes
- Detailed explanations beyond the README

**Note**: All scripts run from your **local machine** and use SSH to manage remote servers.

## Configuration

All settings in `axon.config.yml` - no docker-compose files needed. Config defines:
- Product metadata and deployment mode (docker/static)
- Server connection details (SSH keys, hosts)
- Container/build settings (ports, health checks, registry)
- Per-environment overrides (domains, deploy paths)

See `deploy/config.example.yml` for complete reference with `[REQUIRED]` and `[OPTIONAL]` markings, or use `axon config init --interactive` for guided setup.

## Context Management

AXON provides kubectl-like context management for working with multiple projects. Save project configurations as contexts and access them from anywhere without navigating directories.

**Why contexts?** Manage multiple products/environments without cd-ing between directories or specifying config files repeatedly.

**Key concepts:**
- One context per project (stores config path and project root)
- Switch active context globally or override per-command
- Share contexts with team via export/import

```bash
# Basic workflow
axon context add my-app                 # Save current project
axon context use my-app                 # Set as active
axon deploy production                  # Works from anywhere

# Override without switching
axon --context other-app status         # One-off command

# Priority: -c flag > --context > local axon.config.yml > active context
```

Run `axon context --help` for complete command reference.

## Usage

AXON follows a simple pattern: `axon <command> [environment] [options]`

**Command categories:**
- **Deployment**: `build`, `push`, `deploy`, `run` (full pipeline), `build-and-push` (CI/CD)
- **Operations**: `status`, `health`, `logs`, `restart`, `delete`
- **Configuration**: `config init/validate`, `env edit`
- **Context**: `context add/use/list` (multi-project management)
- **Setup**: `install`, `uninstall` (server prerequisites)

**Key patterns:**
```bash
# Most commands work on single environment or --all
axon status production          # Single environment
axon status --all               # All environments

# Git SHA tracking (automatic or manual)
axon run production             # Auto-detect from git
axon run staging --skip-git     # Skip git tagging

# Override config resolution
axon -c custom.yml deploy       # Explicit config file
axon --context app deploy       # Use saved context
```

**Getting help:**
```bash
axon --help                     # List all commands
axon <command> --help           # Command-specific options
```

See [Quick Start](#quick-start) for complete workflow. All commands support `--help` for detailed usage.

## Requirements

**System Server:** nginx, SSH access, sudo for nginx reload
**Application Server** (Docker mode): Docker, registry CLI (aws/gcloud/az), SSH access
**Local Machine:** yq, envsubst, Docker, SSH client, Node.js (for decomposerize)

Use `axon install local` to check missing tools, or `axon install local --auto-install` to install automatically.

## How It Works

### Docker Container Deployments
1. Pull image from registry → Start new container (auto-assigned port) → Wait for health check
2. Update nginx upstream → Test config → Reload nginx (zero downtime)
3. Gracefully shutdown old container

### Static Site Deployments
1. Build static site → Create archive with git SHA → Upload to System Server
2. Extract to new release directory (`{timestamp}-{sha}`)
3. Update `current` symlink atomically → Reload nginx → Cleanup old releases

**Key Features:**
- Git SHA tracking (Docker tags and static release names)
- Health checks (Docker native + HTTP endpoint testing)
- Automatic rollback on deployment failures
- SSH multiplexing for optimized performance

## Troubleshooting

**Missing tools:** Run `axon install local` to check prerequisites
**Uncommitted changes:** Commit first or use `--skip-git` flag
**Health check fails:** Check `axon logs <env>` and verify health endpoint configuration
**Container not found:** Verify config environment name matches deployment

Use `axon <command> --help` for command-specific troubleshooting. Enable verbose mode with `--verbose` or `-v` for detailed execution logs.

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

GPL-3.0 - See [LICENSE](LICENSE) for details.

AXON is free and open source software. You are free to use, modify, and distribute it under the terms of the GNU General Public License v3.0.

## Support

For issues and questions, please open an issue in the repository.
