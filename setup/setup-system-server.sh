#!/bin/bash
# AXON - System Server Setup Script
# Runs from LOCAL MACHINE and prepares System Server (nginx) for zero-downtime deployments
# Safe to re-execute (idempotent)
#
# New architecture:
# - Creates /etc/nginx/axon.d/{upstreams,sites} structure
# - Modifies nginx.conf to include axon.d configs
# - Generates site configs for ALL environments
# - Upstreams are created during deployment (not setup)

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PRODUCT_ROOT="$(cd "$DEPLOY_DIR/.." && pwd)"

# Default configuration file
CONFIG_FILE="${PRODUCT_ROOT}/axon.config.yml"

# Parse arguments
while [ $# -gt 0 ]; do
    case $1 in
        -c|--config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Prepares System Server nginx for zero-downtime deployments"
            echo ""
            echo "Options:"
            echo "  -c, --config FILE    Specify config file (default: axon.config.yml)"
            echo "  -h, --help           Show this help message"
            echo ""
            echo "Example:"
            echo "  $0 --config custom.yml"
            exit 0
            ;;
        -*)
            echo -e "${RED}Error: Unknown option: $1${NC}"
            echo "Use --help for usage information"
            exit 1
            ;;
        *)
            echo -e "${RED}Error: Unexpected argument: $1${NC}"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Make CONFIG_FILE absolute path if it's relative
if [ "${CONFIG_FILE:0:1}" != "/" ]; then
    CONFIG_FILE="${PRODUCT_ROOT}/${CONFIG_FILE}"
fi

# Source libraries
source "$DEPLOY_DIR/lib/config-parser.sh"
source "$DEPLOY_DIR/lib/defaults.sh"

echo -e "${CYAN}==================================================${NC}"
echo -e "${CYAN}System Server Setup (from Local Machine)${NC}"
echo -e "${CYAN}nginx Configuration for Zero-Downtime Deployments${NC}"
echo -e "${CYAN}==================================================${NC}"
echo ""
echo -e "${YELLOW}Running from: $(hostname)${NC}"
echo -e "${YELLOW}Config file: ${CONFIG_FILE}${NC}"
echo ""

# Check if config file exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}Error: Configuration file not found: ${CONFIG_FILE}${NC}"
    echo ""
    echo -e "Please create a configuration file first:"
    echo -e "${CYAN}cp ${DEPLOY_DIR}/config.example.yml axon.config.yml${NC}"
    echo -e "${CYAN}vi axon.config.yml${NC}"
    echo ""
    exit 1
fi

# Load configuration
echo -e "${BLUE}Loading configuration...${NC}"
PRODUCT_NAME=$(parse_yaml_key ".product.name" "" "$CONFIG_FILE")
APP_SERVER_HOST=$(parse_yaml_key ".servers.application.host" "" "$CONFIG_FILE")
APP_SERVER_PRIVATE_IP=$(parse_yaml_key ".servers.application.private_ip" "" "$CONFIG_FILE")

SYSTEM_SERVER_HOST=$(parse_yaml_key ".servers.system.host" "" "$CONFIG_FILE")
SYSTEM_SERVER_USER=$(parse_yaml_key ".servers.system.user" "ubuntu" "$CONFIG_FILE")
SYSTEM_SERVER_SSH_KEY=$(parse_yaml_key ".servers.system.ssh_key" "" "$CONFIG_FILE")

# Get nginx paths from config or use defaults
NGINX_CONFIG_PATH=$(get_nginx_config_path "$CONFIG_FILE")
NGINX_AXON_DIR=$(get_nginx_axon_dir "$CONFIG_FILE")

# Use private IP for nginx upstream (falls back to public host if not set)
APPLICATION_SERVER_IP="${APP_SERVER_PRIVATE_IP:-$APP_SERVER_HOST}"

# Expand tilde in SSH key path
SYSTEM_SERVER_SSH_KEY="${SYSTEM_SERVER_SSH_KEY/#\~/$HOME}"

# Determine if we need sudo
if [ "$SYSTEM_SERVER_USER" = "root" ]; then
    USE_SUDO=""
else
    USE_SUDO="sudo"
fi

# Get list of environments
ENVIRONMENTS=$(get_configured_environments "$CONFIG_FILE")

echo -e "  System Server:      ${CYAN}${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}${NC}"
echo -e "  Product Name:       ${CYAN}${PRODUCT_NAME}${NC}"
echo -e "  Application Server: ${CYAN}${APPLICATION_SERVER_IP}${NC}"
echo -e "  Nginx Config:       ${CYAN}${NGINX_CONFIG_PATH}${NC}"
echo -e "  AXON Directory:     ${CYAN}${NGINX_AXON_DIR}${NC}"
echo -e "  Environments:       ${CYAN}${ENVIRONMENTS}${NC}"
echo ""

# Validate required fields
if [ -z "$PRODUCT_NAME" ]; then
    echo -e "${RED}Error: product.name not configured${NC}"
    exit 1
fi

if [ -z "$SYSTEM_SERVER_HOST" ]; then
    echo -e "${RED}Error: servers.system.host not configured${NC}"
    exit 1
fi

if [ -z "$ENVIRONMENTS" ]; then
    echo -e "${RED}Error: No environments found in config${NC}"
    echo "Please define at least one environment in the 'environments' section"
    exit 1
fi

# Check prerequisites on local machine
echo -e "${BLUE}Checking local machine prerequisites...${NC}"

if ! command_exists ssh; then
    echo -e "  ${RED}✗ SSH client not found${NC}"
    exit 1
fi
echo -e "  ${GREEN}✓ SSH client installed${NC}"

if [ ! -f "$SYSTEM_SERVER_SSH_KEY" ]; then
    echo -e "  ${RED}✗ SSH key not found: ${SYSTEM_SERVER_SSH_KEY}${NC}"
    exit 1
fi
echo -e "  ${GREEN}✓ SSH key found${NC}"

echo ""

# Test SSH connection
echo -e "${BLUE}Testing SSH connection to System Server...${NC}"

if ! ssh -i "$SYSTEM_SERVER_SSH_KEY" -o ConnectTimeout=10 -o BatchMode=yes \
    "${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}" "echo 'OK'" > /dev/null 2>&1; then
    echo -e "  ${RED}✗ SSH connection failed${NC}"
    echo ""
    echo -e "  ${YELLOW}To fix:${NC}"
    echo -e "  1. Ensure System Server is running"
    echo -e "  2. Add public key to System Server:"
    echo -e "     ${CYAN}ssh-copy-id -i ${SYSTEM_SERVER_SSH_KEY}.pub ${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}${NC}"
    echo ""
    exit 1
fi

echo -e "  ${GREEN}✓ SSH connection successful${NC}"
echo ""

###########################################
# PHASE 1: Pre-flight Safety Validation
###########################################

echo -e "${BLUE}Phase 1/5: Pre-flight Safety Validation${NC}"
echo ""

# Check nginx installation
echo -e "  Checking nginx installation..."
NGINX_CHECK=$(ssh -i "$SYSTEM_SERVER_SSH_KEY" "${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}" \
    'nginx -v 2>&1' || echo "NOT_INSTALLED")

if echo "$NGINX_CHECK" | grep -q "NOT_INSTALLED\|command not found"; then
    echo -e "  ${RED}✗ nginx is not installed on System Server${NC}"
    echo ""
    echo -e "  To install nginx (Ubuntu/Debian):"
    echo -e "  ${CYAN}ssh ${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}${NC}"
    echo -e "  ${CYAN}${USE_SUDO} apt update && ${USE_SUDO} apt install -y nginx${NC}"
    echo ""
    exit 1
fi

NGINX_VERSION=$(echo "$NGINX_CHECK" | grep -o 'nginx/[0-9.]*' | head -1 | cut -d'/' -f2)
echo -e "  ${GREEN}✓ nginx installed (version: ${NGINX_VERSION})${NC}"

# Validate current nginx config (refuse to proceed if broken)
echo -e "  Validating current nginx configuration..."
NGINX_TEST=$(ssh -i "$SYSTEM_SERVER_SSH_KEY" "${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}" \
    "${USE_SUDO} nginx -t 2>&1")

if ! echo "$NGINX_TEST" | grep -q "successful"; then
    echo -e "  ${RED}✗ nginx configuration is already broken!${NC}"
    echo ""
    echo "$NGINX_TEST"
    echo ""
    echo -e "${RED}Please fix nginx configuration before running setup${NC}"
    exit 1
fi

echo -e "  ${GREEN}✓ nginx configuration is valid${NC}"

# Create backup if this is first time
BACKUP_EXISTS=$(ssh -i "$SYSTEM_SERVER_SSH_KEY" "${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}" \
    "ls ${NGINX_CONFIG_PATH}.axon-backup-* 2>/dev/null | wc -l" | tr -d ' ')

if [ "$BACKUP_EXISTS" = "0" ]; then
    echo -e "  Creating backup of nginx.conf..."
    BACKUP_FILE="${NGINX_CONFIG_PATH}.axon-backup-$(date +%Y%m%d-%H%M%S)"
    ssh -i "$SYSTEM_SERVER_SSH_KEY" "${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}" \
        "${USE_SUDO} cp ${NGINX_CONFIG_PATH} ${BACKUP_FILE}"
    echo -e "  ${GREEN}✓ Backup created: $(basename $BACKUP_FILE)${NC}"
else
    echo -e "  ${GREEN}✓ Backup already exists (using existing)${NC}"
fi

echo ""

###########################################
# PHASE 2: Directory Structure Creation
###########################################

echo -e "${BLUE}Phase 2/5: Directory Structure Creation${NC}"
echo ""

# Create axon.d directory structure
echo -e "  Creating AXON directory structure..."

ssh -i "$SYSTEM_SERVER_SSH_KEY" "${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}" bash <<EOF
set -e
${USE_SUDO} mkdir -p ${NGINX_AXON_DIR}/upstreams
${USE_SUDO} mkdir -p ${NGINX_AXON_DIR}/sites
${USE_SUDO} chmod 755 ${NGINX_AXON_DIR}
${USE_SUDO} chmod 755 ${NGINX_AXON_DIR}/upstreams
${USE_SUDO} chmod 755 ${NGINX_AXON_DIR}/sites

# Create README
cat > /tmp/axon-readme.txt <<'EOFREADME'
# AXON-Managed Directory
# This directory is automatically managed by AXON deployment system.
# Do not manually edit files here - they will be overwritten.
#
# Structure:
# - upstreams/: Created during deployment with Docker-assigned ports
# - sites/: Created during setup with server blocks
#
# Last updated: $(date)
EOFREADME

${USE_SUDO} mv /tmp/axon-readme.txt ${NGINX_AXON_DIR}/README
${USE_SUDO} chmod 644 ${NGINX_AXON_DIR}/README
EOF

echo -e "  ${GREEN}✓ Directory structure created${NC}"
echo -e "    ${NGINX_AXON_DIR}/upstreams/"
echo -e "    ${NGINX_AXON_DIR}/sites/"
echo ""

###########################################
# PHASE 3: nginx.conf Modification
###########################################

echo -e "${BLUE}Phase 3/5: nginx.conf Modification${NC}"
echo ""

# Check if AXON configuration already exists (check for includes, not just marker)
AXON_INCLUDES_EXIST=$(ssh -i "$SYSTEM_SERVER_SSH_KEY" "${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}" \
    "grep -F 'include ${NGINX_AXON_DIR}/upstreams/' ${NGINX_CONFIG_PATH} 2>/dev/null && echo '1' || echo '0'")

if [ "$AXON_INCLUDES_EXIST" = "1" ]; then
    echo -e "  ${GREEN}✓ AXON includes already present in nginx.conf${NC}"

    # Verify both includes exist
    SITES_INCLUDE=$(ssh -i "$SYSTEM_SERVER_SSH_KEY" "${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}" \
        "grep -F 'include ${NGINX_AXON_DIR}/sites/' ${NGINX_CONFIG_PATH} 2>/dev/null && echo '1' || echo '0'")

    if [ "$SITES_INCLUDE" != "1" ]; then
        echo -e "  ${YELLOW}⚠ Sites include missing, re-running setup...${NC}"
        AXON_INCLUDES_EXIST="0"
    fi
fi

if [ "$AXON_INCLUDES_EXIST" = "0" ]; then
    echo -e "  Adding AXON configuration to nginx.conf..."

    # Create the configuration block to insert
    cat > /tmp/axon-nginx-insert.conf <<'EOFINSERT'

    # ===== AXON-managed configurations (auto-added by AXON setup) =====

    # WebSocket upgrade mapping (required for WebSocket support)
    map $http_upgrade $connection_upgrade {
        default upgrade;
        '' close;
    }

    # [OPTIONAL] Rate limiting zone (uncomment if needed)
    # Limits requests to 10 per second with 10MB zone for tracking IPs
    # limit_req_zone $binary_remote_addr zone=limit:10m rate=10r/s;

    # [OPTIONAL] Proxy cache zone (uncomment if needed)
    # Creates 100MB zone with 10GB max cache size, 60 day inactive timeout
    # proxy_cache_path /var/cache/nginx/imgCache levels=1:2 keys_zone=imgCache:100m max_size=10g inactive=60d use_temp_path=off;

    # Include AXON-managed upstream and site configurations
    include NGINX_AXON_DIR_PLACEHOLDER/upstreams/*.conf;
    include NGINX_AXON_DIR_PLACEHOLDER/sites/*.conf;

    # ===== End AXON-managed configurations =====

EOFINSERT

    # Replace placeholder with actual path
    sed -i.bak "s|NGINX_AXON_DIR_PLACEHOLDER|${NGINX_AXON_DIR}|g" /tmp/axon-nginx-insert.conf
    rm -f /tmp/axon-nginx-insert.conf.bak

    # Upload the insert file
    scp -i "$SYSTEM_SERVER_SSH_KEY" /tmp/axon-nginx-insert.conf \
        "${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}:/tmp/axon-nginx-insert.conf" > /dev/null 2>&1

    # Modify nginx.conf on remote server
    ssh -i "$SYSTEM_SERVER_SSH_KEY" "${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}" bash <<EOF
set -e

echo "  Backing up nginx.conf..."
# Backup before modification
${USE_SUDO} cp ${NGINX_CONFIG_PATH} /tmp/nginx.conf.before-axon

echo "  Inserting AXON configuration..."

# Use awk to insert before last closing brace (http block)
awk '
    {
        lines[NR] = \$0
    }
    END {
        # Find last line with closing brace (handles leading whitespace)
        for (i = NR; i >= 1; i--) {
            if (lines[i] ~ /^[[:space:]]*}[[:space:]]*\$/) {
                last_brace_line = i
                break
            }
        }

        if (last_brace_line == 0) {
            print "ERROR: Could not find closing brace in nginx.conf" > "/dev/stderr"
            exit 1
        }

        # Print all lines, inserting AXON config before last brace
        for (i = 1; i <= NR; i++) {
            if (i == last_brace_line) {
                # Insert AXON config before closing brace
                while ((getline line < "/tmp/axon-nginx-insert.conf") > 0) {
                    print line
                }
                close("/tmp/axon-nginx-insert.conf")
            }
            print lines[i]
        }
    }
' /tmp/nginx.conf.before-axon > /tmp/nginx.conf.tmp

if [ ! -s /tmp/nginx.conf.tmp ]; then
    echo "ERROR: awk failed to generate nginx.conf"
    ${USE_SUDO} mv /tmp/nginx.conf.before-axon ${NGINX_CONFIG_PATH}
    exit 1
fi

# Replace nginx.conf
${USE_SUDO} mv /tmp/nginx.conf.tmp ${NGINX_CONFIG_PATH}

# Validate
echo "  Validating modified nginx.conf..."
if ! ${USE_SUDO} nginx -t 2>&1 | grep -q "successful"; then
    echo "  ERROR: Validation failed, rolling back..."
    ${USE_SUDO} mv /tmp/nginx.conf.before-axon ${NGINX_CONFIG_PATH}
    exit 1
fi

echo "  Validation successful!"

# Cleanup
rm -f /tmp/axon-nginx-insert.conf
${USE_SUDO} rm -f /tmp/nginx.conf.before-axon
EOF

    if [ $? -eq 0 ]; then
        echo -e "  ${GREEN}✓ nginx.conf updated successfully${NC}"
    else
        echo -e "  ${RED}✗ Failed to update nginx.conf${NC}"
        exit 1
    fi

    # Cleanup local temp file
    rm -f /tmp/axon-nginx-insert.conf
fi

echo ""

###########################################
# PHASE 4: Post-validation
###########################################

echo -e "${BLUE}Phase 4/4: Post-validation${NC}"
echo ""

# Final nginx configuration test
echo -e "  Running final nginx configuration test..."
FINAL_TEST=$(ssh -i "$SYSTEM_SERVER_SSH_KEY" "${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}" \
    "${USE_SUDO} nginx -t 2>&1")

if ! echo "$FINAL_TEST" | grep -q "successful"; then
    echo -e "  ${RED}✗ nginx configuration test failed!${NC}"
    echo ""
    echo "$FINAL_TEST"
    echo ""
    echo -e "${RED}Rolling back nginx.conf...${NC}"

    # Restore nginx.conf from backup
    LATEST_BACKUP=$(ssh -i "$SYSTEM_SERVER_SSH_KEY" "${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}" \
        "ls -t ${NGINX_CONFIG_PATH}.axon-backup-* 2>/dev/null | head -1" || echo "")

    if [ -n "$LATEST_BACKUP" ]; then
        ssh -i "$SYSTEM_SERVER_SSH_KEY" "${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}" \
            "${USE_SUDO} cp ${LATEST_BACKUP} ${NGINX_CONFIG_PATH}"
        echo -e "  ${GREEN}✓ Restored nginx.conf from backup${NC}"
    fi

    exit 1
fi

echo -e "  ${GREEN}✓ nginx configuration is valid${NC}"

# Prompt to reload nginx
echo ""
echo -e "Configuration files created successfully."
echo -e ""
read -p "Would you like to reload nginx now? (y/n) " -n 1 -r
echo ""

if [ "$REPLY" = "y" ] || [ "$REPLY" = "Y" ]; then
    ssh -i "$SYSTEM_SERVER_SSH_KEY" "${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}" \
        "${USE_SUDO} nginx -s reload"
    echo -e "${GREEN}✓ nginx reloaded successfully${NC}"
else
    echo -e "${YELLOW}⚠ Remember to reload nginx manually:${NC}"
    echo -e "  ${CYAN}ssh ${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST} '${USE_SUDO} nginx -s reload'${NC}"
fi

echo ""

###########################################
# Summary
###########################################

echo -e "${GREEN}==================================================${NC}"
echo -e "${GREEN}✓ System Server setup complete!${NC}"
echo -e "${GREEN}==================================================${NC}"
echo ""

echo -e "${CYAN}Configuration Summary:${NC}"
echo -e "  Local Machine:      ${YELLOW}$(hostname)${NC}"
echo -e "  System Server:      ${YELLOW}${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}${NC}"
echo -e "  AXON Directory:     ${YELLOW}${NGINX_AXON_DIR}${NC}"
echo -e "  Product:            ${YELLOW}${PRODUCT_NAME}${NC}"
echo ""

echo -e "${CYAN}What was configured:${NC}"
echo -e "  ${GREEN}✓${NC} nginx.conf modified with AXON includes"
echo -e "  ${GREEN}✓${NC} Directory: ${NGINX_AXON_DIR}/upstreams/ (for dynamic upstreams)"
echo -e "  ${GREEN}✓${NC} Directory: ${NGINX_AXON_DIR}/sites/ (for site configs)"
echo -e "  ${GREEN}✓${NC} WebSocket map added to nginx.conf"
echo ""

echo -e "${CYAN}Next Steps:${NC}"
echo ""

echo -e "1. Deploy your application (configs will be generated automatically):"
echo -e "   ${CYAN}axon deploy <environment>${NC}"
echo -e ""
echo -e "   The deployment will:"
echo -e "   • Generate site config for the environment"
echo -e "   • Generate upstream config with Docker-assigned port"
echo -e "   • Validate and reload nginx"
echo ""

echo -e "${GREEN}System Server is ready for zero-downtime deployments!${NC}"
echo ""
