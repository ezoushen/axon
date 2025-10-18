# Integration Guide

How to integrate the deployment module into your product.

## Prerequisites

- Docker and Docker Compose installed
- AWS CLI configured with appropriate profile
- SSH access between Application Server and System Server
- nginx running on System Server

## Step 1: Add Deployment Module to Your Product

### Option A: As a Git Submodule (Recommended)

```bash
cd your-product
git submodule add <deployment-module-repo-url> deploy
git submodule update --init --recursive
```

### Option B: Copy Files Directly

```bash
cd your-product
cp -r /path/to/deployment-module deploy
```

## Step 2: Create Product Configuration

Create `deploy.config.yml` in your product root:

```bash
cd your-product
cp deploy/config.example.yml deploy.config.yml
```

Edit `deploy.config.yml` with your product's settings:

```yaml
product:
  name: "my-product"              # Change to your product name
  description: "My Product"

aws:
  profile: "default"               # Your AWS CLI profile
  region: "ap-northeast-1"        # Your AWS region
  account_id: "123456789012"      # Your AWS account ID
  ecr_repository: "my-product"    # Your ECR repository name

servers:
  system:
    host: "system-server-ip"      # System Server IP
    user: "deploy"                # SSH user
    ssh_key: "~/.ssh/deployment_key"

  application:
    host: "app-server-ip"         # Application Server IP

environments:
  production:
    blue_port: 5100
    green_port: 5102
    domain: "production.example.com"
    nginx_upstream_file: "/etc/nginx/upstreams/myproduct-production.conf"
    nginx_upstream_name: "myproduct_production_backend"
    env_file: ".env.production"
    image_tag: "production"
    docker_compose_file: "docker-compose.production.yml"

  staging:
    blue_port: 5101
    green_port: 5103
    domain: "staging.example.com"
    nginx_upstream_file: "/etc/nginx/upstreams/myproduct-staging.conf"
    nginx_upstream_name: "myproduct_staging_backend"
    env_file: ".env.staging"
    image_tag: "staging"
    docker_compose_file: "docker-compose.staging.yml"
```

## Step 3: Update Docker Compose Files

Add environment variables for blue-green deployment:

```yaml
# docker-compose.production.yml
services:
  app:
    container_name: ${PRODUCT_NAME}-production-${DEPLOYMENT_SLOT:-blue}
    ports:
      - "${APP_PORT:-5100}:3000"
    # ... rest of your config
```

```yaml
# docker-compose.staging.yml
services:
  app:
    container_name: ${PRODUCT_NAME}-staging-${DEPLOYMENT_SLOT:-blue}
    ports:
      - "${APP_PORT:-5101}:3000"
    # ... rest of your config
```

**Important:** Only change:
- `container_name`: Add `${PRODUCT_NAME}-` prefix and `-${DEPLOYMENT_SLOT:-blue}` suffix
- `ports`: Wrap port in `${APP_PORT:-XXXX}`

Everything else stays the same!

## Step 4: Update Environment Files

Ensure your `.env.production` and `.env.staging` files have required AWS variables:

```env
# .env.production
AWS_ACCOUNT_ID=123456789012
AWS_REGION=ap-northeast-1
ECR_REPOSITORY=my-product
IMAGE_TAG=production
AWS_PROFILE=default

# Your other product-specific variables
NEXT_PUBLIC_LIFF_ID=...
API_SERVER_URL=...
```

## Step 5: Add to .gitignore

```bash
# .gitignore

# Deployment configuration (contains secrets)
deploy.config.yml

# But keep the example in Git
!deploy/config.example.yml
```

## Step 6: Deploy!

```bash
# Deploy production
./deploy/deploy.sh production

# Deploy staging
./deploy/deploy.sh staging

# Build and push new image
./deploy/scripts/build-and-push.sh production

# View logs
./deploy/scripts/logs.sh production

# Check status
./deploy/scripts/status.sh

# Health check
./deploy/scripts/health-check.sh all
```

## Directory Structure After Integration

```
your-product/
├── deploy/                         # Deployment module (git submodule)
│   ├── deploy.sh                  # Main deployment script
│   ├── scripts/
│   │   ├── build-and-push.sh
│   │   ├── logs.sh
│   │   ├── status.sh
│   │   ├── restart.sh
│   │   └── health-check.sh
│   ├── lib/
│   │   └── config-parser.sh
│   ├── docs/
│   └── config.example.yml
│
├── deploy.config.yml              # Your product configuration (gitignored)
├── docker-compose.production.yml  # Updated with env vars
├── docker-compose.staging.yml     # Updated with env vars
├── .env.production                # With AWS variables
├── .env.staging                   # With AWS variables
└── ... (rest of your product files)
```

## Updating the Deployment Module

If the deployment module gets updates:

```bash
cd your-product/deploy
git pull origin main
cd ..
git add deploy
git commit -m "Update deployment module"
```

## Troubleshooting

### "Configuration file not found"
Ensure `deploy.config.yml` exists in your product root, not in the `deploy/` directory.

### "Container name not found"
Make sure you've updated docker-compose files with `${PRODUCT_NAME}` and `${DEPLOYMENT_SLOT}` variables.

### "SSH connection failed"
Check SSH key path in `deploy.config.yml` and ensure you have access to System Server.

### "Health check failed"
Verify the health check endpoint in your application responds with HTTP 200.

## Best Practices

1. **Keep deploy.config.yml out of Git** - It contains server IPs and paths
2. **Test in staging first** - Always deploy to staging before production
3. **Use Git SHA tags** - `./deploy/scripts/build-and-push.sh production $(git rev-parse --short HEAD)`
4. **Monitor deployments** - Watch logs during deployment: `./deploy/scripts/logs.sh production follow`
5. **Health checks** - Ensure your app has a `/api/health` endpoint that returns 200

## Example Deployment Workflow

```bash
# 1. Make code changes
git add .
git commit -m "Add new feature"

# 2. Build and push image
./deploy/scripts/build-and-push.sh production $(git rev-parse --short HEAD)

# 3. Deploy to production (zero-downtime)
./deploy/deploy.sh production

# 4. Verify deployment
./deploy/scripts/health-check.sh production
./deploy/scripts/logs.sh production

# 5. Monitor
./deploy/scripts/status.sh
```

## Support

If you encounter issues with the deployment module, check:
1. Module documentation: `deploy/README.md`
2. Configuration example: `deploy/config.example.yml`
3. Your product configuration: `deploy.config.yml`
