# Setup Guide

Complete setup instructions for AXON zero-downtime deployment system.

## Overview

This guide walks you through setting up both the Application Server and System Server for zero-downtime deployments with Docker auto-port assignment and timestamp-based containers.

**Time Required**: ~30 minutes total
- Application Server: ~15 minutes
- System Server: ~15 minutes

**Architecture:**
- **Application Server**: Runs Docker containers with auto-assigned ports
- **System Server**: Runs nginx with SSL, proxies to Application Server
- **Deployment**: Config-driven, no docker-compose files needed

## Prerequisites

- SSH access to both servers
- sudo permissions on both servers
- Basic knowledge of nginx configuration

---

## Quick Setup

### Application Server

```bash
cd your-product/deploy
./setup/setup-application-server.sh

# Or with custom config:
./setup/setup-application-server.sh --config custom.yml
```

### System Server

```bash
./setup/setup-system-server.sh

# Or with custom config:
./setup/setup-system-server.sh --config custom.yml
```

---

## Detailed Setup Instructions

### Part 1: Application Server Setup

#### What It Does

The Application Server setup script:
- ✅ Checks Docker installation
- ✅ Checks Docker Compose installation
- ✅ Checks AWS CLI installation
- ✅ Generates SSH deployment key
- ✅ Tests connection to System Server
- ✅ Verifies user permissions

#### Running the Script

```bash
cd /path/to/your-product/deploy
./setup/setup-application-server.sh
```

#### With Configuration

You can provide configuration via environment variables:

```bash
SYSTEM_SERVER_HOST=10.0.2.100 \
SYSTEM_SERVER_USER=deploy \
AWS_PROFILE=lastlonger \
AWS_REGION=ap-northeast-1 \
./setup/setup-application-server.sh
```

#### Expected Output

```
==================================================
Application Server Setup
Zero-Downtime Deployment Prerequisites
==================================================

Step 1/8: Checking operating system...
  OS: Linux

Step 2/8: Checking Docker installation...
  ✓ Docker is installed (version: 24.0.7)
  ✓ Docker daemon is running

Step 3/8: Checking Docker Compose installation...
  ✓ Docker Compose is installed (version: 2.23.0)

Step 4/8: Checking AWS CLI installation...
  ✓ AWS CLI is installed (version: 2.13.5)
  ✓ AWS credentials configured (profile: lastlonger, account: 123456789012)

Step 5/8: Checking deployment SSH key...
  ✓ Deployment SSH key exists
  Location: /home/ubuntu/.ssh/deployment_key
  ✓ Correct permissions (600)

  Public key (add this to System Server):
  ssh-ed25519 AAAA...xyz deployment-key

Step 6/8: Testing SSH connection to System Server...
  Testing connection to: deploy@10.0.2.100
  ✓ SSH connection successful

Step 7/8: Checking user permissions...
  ✓ User is in docker group

Step 8/8: Verifying setup...
  ✓ Docker daemon running
  ✓ Docker Compose available
  ✓ AWS CLI installed
  ✓ SSH key exists

==================================================
✓ Application Server setup complete!
==================================================
```

#### Troubleshooting Application Server

**Docker not installed:**
```bash
# Ubuntu/Debian
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
sudo usermod -aG docker $USER
# Log out and log back in
```

**Docker Compose not installed:**
```bash
# Install as Docker plugin (recommended)
DOCKER_CONFIG=${DOCKER_CONFIG:-$HOME/.docker}
mkdir -p $DOCKER_CONFIG/cli-plugins
curl -SL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 \
  -o $DOCKER_CONFIG/cli-plugins/docker-compose
chmod +x $DOCKER_CONFIG/cli-plugins/docker-compose
```

**AWS CLI not installed:**
```bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
aws configure --profile lastlonger
```

**User not in docker group:**
```bash
sudo usermod -aG docker $USER
# Log out and log back in
```

---

### Part 2: System Server Setup

#### What It Does

The System Server setup script:
- ✅ Checks nginx installation
- ✅ Creates upstream directory (`/etc/nginx/upstreams/`)
- ✅ Creates deploy user
- ✅ Configures SSH access for deploy user
- ✅ Sets sudo permissions (nginx reload only)
- ✅ Creates example upstream files
- ✅ Tests nginx configuration

#### Running the Script

**Basic (manual upstream creation):**
```bash
sudo ./setup-system-server.sh
```

**With product configuration (auto-creates upstreams):**
```bash
sudo PRODUCT_NAME=my-product \
     APPLICATION_SERVER_IP=10.0.1.100 \
     ./setup-system-server.sh
```

#### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `DEPLOY_USER` | `deploy` | User for deployment SSH access |
| `UPSTREAM_DIR` | `/etc/nginx/upstreams` | Directory for upstream configs |
| `PRODUCT_NAME` | _(optional)_ | Product name for auto-config |
| `APPLICATION_SERVER_IP` | _(optional)_ | Application Server IP |

#### Expected Output

```
==================================================
System Server Setup
nginx Configuration for Zero-Downtime Deployments
==================================================

Running with sudo

Step 1/7: Checking nginx installation...
  ✓ nginx is installed (version: 1.18.0)
  ✓ nginx is running

Step 2/7: Creating upstream directory...
  ✓ Upstream directory created
  Location: /etc/nginx/upstreams

Step 3/7: Creating deploy user...
  ✓ User 'deploy' created
  ✓ .ssh directory created
  SSH authorized_keys: /home/.ssh/authorized_keys

Step 4/7: Configuring sudo permissions...
  ✓ Sudoers file created and validated
  Location: /etc/sudoers.d/deploy

Step 5/7: Setting upstream directory ownership...
  ✓ Ownership updated

Step 6/7: Creating upstream configuration files...
  ✓ Created: /etc/nginx/upstreams/my-product-production.conf
  ✓ Created: /etc/nginx/upstreams/my-product-staging.conf

Step 7/7: Testing nginx configuration...
  ✓ nginx configuration is valid
Reload nginx now? (y/n): y
  ✓ nginx reloaded

==================================================
✓ System Server setup complete!
==================================================
```

#### Troubleshooting System Server

**nginx not installed:**
```bash
# Ubuntu/Debian
sudo apt update && sudo apt install -y nginx

# CentOS/RHEL
sudo yum install -y nginx

# Start nginx
sudo systemctl start nginx
sudo systemctl enable nginx
```

**Permission denied errors:**
Make sure you're running the script with sudo:
```bash
sudo ./setup-system-server.sh
```

**Sudoers syntax error:**
The script validates sudoers syntax automatically. If it fails, it removes the invalid file.

---

## Post-Setup Configuration

### 1. Add SSH Public Key

On **Application Server**, get the public key:
```bash
cat ~/.ssh/deployment_key.pub
```

On **System Server**, add it to deploy user:
```bash
echo "ssh-ed25519 AAAA...xyz deployment-key" >> /home/.ssh/authorized_keys
chmod 600 /home/.ssh/authorized_keys
chown deploy:deploy /home/.ssh/authorized_keys
```

### 2. Update nginx Site Configuration

Edit your nginx site config to include the upstream:

```nginx
# /etc/nginx/sites-available/your-site.conf

# Include upstream file (will be auto-updated by deployments)
include /etc/nginx/upstreams/my-product-production.conf;

server {
    listen 443 ssl http2;
    server_name production.yourdomain.com;

    # SSL configuration
    ssl_certificate /path/to/cert.pem;
    ssl_certificate_key /path/to/key.pem;

    location / {
        # Proxy to upstream (backend name auto-generated from product-environment)
        proxy_pass http://my_product_production_backend;

        # Headers
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_cache_bypass $http_upgrade;
    }
}
```

**Upstream Backend Name Format:**
- Format: `{product}_{environment}_backend` (with underscores, not hyphens)
- Example: `my_product_production_backend`
- Auto-generated by deployment script

**Upstream File Naming:**
- Format: `/etc/nginx/upstreams/{product}-{environment}.conf` (with hyphens)
- Example: `/etc/nginx/upstreams/my-product-production.conf`
- Auto-updated during deployments with new port

Test and reload:
```bash
sudo nginx -t
sudo nginx -s reload
```

### 3. Test SSH Connection

From **Application Server**:
```bash
ssh -i ~/.ssh/deployment_key deploy@system-server-ip "echo 'Connection successful'"
```

### 4. Test sudo Permissions

From **Application Server**:
```bash
ssh -i ~/.ssh/deployment_key deploy@system-server-ip "sudo nginx -t"
```

Should show nginx config test results without asking for password.

---

## Verification Checklist

### Application Server

- [ ] Docker installed and running
- [ ] Docker Compose available
- [ ] AWS CLI installed and configured
- [ ] Deployment SSH key generated (`~/.ssh/deployment_key`)
- [ ] User in docker group
- [ ] Can SSH to System Server as deploy user

### System Server

- [ ] nginx installed and running
- [ ] Upstream directory created (`/etc/nginx/upstreams/`)
- [ ] Deploy user created
- [ ] Deploy user can sudo nginx commands
- [ ] Upstream files created for product
- [ ] nginx site config includes upstream files
- [ ] nginx configuration tests successfully
- [ ] Can receive SSH connections from Application Server

---

## Re-running Setup Scripts

Both scripts are **idempotent** - safe to re-run:

- Existing configuration is preserved
- Only missing components are created
- Permissions are fixed if incorrect
- No data loss or duplication

Example re-run scenarios:
```bash
# Re-check Application Server after installing Docker
./setup/setup-application-server.sh

# Add new product to System Server
sudo PRODUCT_NAME=newapp APPLICATION_SERVER_IP=10.0.1.100 ./setup-system-server.sh

# Fix permissions on System Server
sudo ./setup-system-server.sh
```

---

## Multi-Product Setup

For multiple products on the same servers:

### Application Server
Each product can use the same deployment key, or generate separate keys:
```bash
# Use same key (shared)
./setup/setup-application-server.sh

# Or use product-specific keys
SSH_KEY_PATH=~/.ssh/deployment_key_product1 ./setup/setup-application-server.sh
```

### System Server
Run setup for each product:
```bash
sudo PRODUCT_NAME=product1 APPLICATION_SERVER_IP=10.0.1.100 ./setup-system-server.sh
sudo PRODUCT_NAME=product2 APPLICATION_SERVER_IP=10.0.1.101 ./setup-system-server.sh
```

This creates separate upstream files:
```
/etc/nginx/upstreams/
├── product1-production.conf
├── product1-staging.conf
├── product2-production.conf
└── product2-staging.conf
```

---

## Security Notes

### SSH Key Security
- Private key (`~/.ssh/deployment_key`) never leaves Application Server
- Key has 600 permissions (owner read/write only)
- Public key only added to System Server

### Deploy User Permissions
- Can ONLY run: `sudo nginx -t` and `sudo nginx -s reload`
- Cannot run any other sudo commands
- Cannot modify nginx configs directly (writes to `/etc/nginx/upstreams/` owned by deploy user)

### Sudoers Configuration
```
deploy ALL=(ALL) NOPASSWD: /usr/sbin/nginx -t, /usr/sbin/nginx -s reload
```
- Specific commands only
- No password required (for automation)
- Validated syntax before creating

---

## How Deployments Update nginx

### Deployment Flow

1. **New container starts** with Docker auto-assigned port (e.g., 34567)
2. **Health check passes** (Docker native health status)
3. **Deployment script** SSHs to System Server and updates upstream file:
   ```bash
   ssh deploy@system-server "cat > /etc/nginx/upstreams/product-env.conf <<EOF
   upstream product_env_backend {
       server application-server:34567;
   }
   EOF"
   ```
4. **nginx reload** (zero-downtime)
5. **Old container stops** after connection draining

### Upstream File Example

```nginx
# /etc/nginx/upstreams/my-product-production.conf
upstream my_product_production_backend {
    server 10.0.1.100:34567;
}
```

This file is **auto-updated** during each deployment with the new port.

---

## Next Steps

After completing setup:

1. ✅ **Create product configuration**
   ```bash
   cp config.example.yml deploy.config.yml
   # Edit with your settings
   ```

2. ✅ **Create environment files on Application Server**
   ```bash
   ssh ubuntu@app-server
   cat > /home/ubuntu/apps/my-product/.env.production <<EOF
   DATABASE_URL=...
   EOF
   ```

3. ✅ **Test deployment**
   ```bash
   ./tools/deploy.sh staging
   ```

4. ✅ **Monitor first deployment**
   ```bash
   ./tools/logs.sh staging follow
   ```

5. ✅ **Verify zero-downtime**
   ```bash
   # Terminal 1: Monitor health
   while true; do curl -s https://staging.yourdomain.com/api/health || echo "FAIL"; sleep 0.1; done

   # Terminal 2: Deploy
   ./tools/deploy.sh staging

   # Terminal 1 should show zero failures ✅
   ```

---

## Support

If you encounter issues:
1. Check the troubleshooting sections above
2. Re-run the setup script (it's idempotent)
3. Review logs: `sudo journalctl -u nginx -f`
4. Test manually: `sudo nginx -t`
5. Check integration guide: `docs/integration.md`
