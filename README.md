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
- **Network Aliases**: Stable DNS names for container-to-container communication (e.g., `http://app:3000`)
- **Rolling Updates**: New container starts → health check passes → nginx switches → old container stops
- **Config-driven**: Single `deploy.config.yml` defines all Docker runtime settings

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
9. **Graceful Shutdown**: Shutdown old containers gracefully
   - Send SIGTERM to old container (graceful shutdown signal)
   - Wait up to `graceful_shutdown_timeout` seconds (default: 30s)
   - Application can finish current requests, close connections, cleanup resources
   - Send SIGKILL if still running after timeout

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

### Network Aliases for Container Communication

Each container gets a **stable DNS name** within its network, solving the dynamic container naming problem:

**The Problem:**
- Container names include timestamps: `linebot-nextjs-production-1760809226`
- Names change on every deployment
- Hard to reference from other containers

**The Solution:**
- Configure a network alias in `deploy.config.yml`:
  ```yaml
  docker:
    network_alias: "app"  # Stable DNS name
  ```

**How to Use:**
- Containers on the same network can communicate using the alias:
  ```bash
  # From another container on the same network:
  curl http://app:3000/api/health

  # Works even though actual container name is:
  # linebot-nextjs-production-1760809226
  ```

**Benefits:**
- ✅ No need to know the dynamic container name
- ✅ Works across deployments (name stays the same)
- ✅ Network-isolated (production and staging have separate networks)
- ✅ Perfect for multi-container setups (app + database, app + redis, etc.)

**Example Multi-Container Setup:**
```yaml
# deploy.config.yml
docker:
  network_alias: "web"  # Your app is accessible as "web"

# Another container on the same network can:
# - Connect to database: postgres:5432
# - Connect to your app: web:3000
# - Connect to redis: redis:6379
```

**Note:** This only works for container-to-container communication on the same Docker network. External access still uses the exposed port managed by nginx.

### Graceful Shutdown

When deploying a new container, the old container is shut down gracefully to ensure:
- Current requests finish processing
- Database connections are closed properly
- Resources are cleaned up
- Logs are flushed

**How it works:**
1. After nginx switches to the new container, the deployment script sends **SIGTERM** to the old container
2. The application receives the signal and can handle it (e.g., stop accepting new requests, finish current work)
3. Docker waits up to `graceful_shutdown_timeout` seconds (default: 30s)
4. If the container is still running after timeout, Docker sends **SIGKILL** (force kill)

**Configuration:**
```yaml
# deploy.config.yml
deployment:
  graceful_shutdown_timeout: 30  # Seconds to wait before force kill
```

**Application Support:**

For Node.js apps, handle SIGTERM gracefully:
```javascript
// Handle graceful shutdown
process.on('SIGTERM', () => {
  console.log('SIGTERM received, starting graceful shutdown...');

  server.close(() => {
    console.log('HTTP server closed');

    // Close database connections, etc.
    process.exit(0);
  });

  // Force exit if graceful shutdown takes too long
  setTimeout(() => {
    console.error('Forced shutdown due to timeout');
    process.exit(1);
  }, 28000); // Slightly less than Docker's timeout
});
```

**Benefits:**
- ✅ No abrupt connection terminations
- ✅ Prevents data loss or corruption
- ✅ Clean resource cleanup
- ✅ Configurable timeout for different application needs

## Troubleshooting

### Common Issues

**1. "No environments found in config"**
- Install `yq` for accurate YAML parsing: `brew install yq`
- Or ensure environment names are properly indented (2 spaces) in config

**2. "Container not found on Application Server"**
- Check if container exists: `ssh app-server "docker ps -a | grep {product}"`
- Verify deploy_path in config matches actual path on server

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
