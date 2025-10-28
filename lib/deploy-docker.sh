#!/bin/bash
# AXON - Docker Deployment Library
# Function for deploying Docker-based applications with zero-downtime

# ==============================================================================
# Docker Deployment Function
# ==============================================================================
deploy_docker() {
    # Use consistent variable names with load_config (for backward compatibility with this script)
    APP_SERVER_HOST="$APPLICATION_SERVER_HOST"
    APP_SERVER_USER="$APPLICATION_SERVER_USER"
    APP_SSH_KEY="$APPLICATION_SERVER_SSH_KEY"
    APP_SERVER_PRIVATE_IP="$APPLICATION_SERVER_PRIVATE_IP"

    # Use private IP for nginx upstream (falls back to public host if not set)
    APP_UPSTREAM_IP="${APP_SERVER_PRIVATE_IP:-$APP_SERVER_HOST}"

    # Get nginx paths and names from defaults library
    NGINX_AXON_DIR=$(get_nginx_axon_dir "$CONFIG_FILE")
    NGINX_UPSTREAM_FILENAME=$(get_upstream_filename "$PRODUCT_NAME" "$ENVIRONMENT")
    NGINX_UPSTREAM_FILE="${NGINX_AXON_DIR}/upstreams/${NGINX_UPSTREAM_FILENAME}"
    NGINX_UPSTREAM_NAME=$(get_upstream_name "$PRODUCT_NAME" "$ENVIRONMENT")
    NGINX_SITE_FILENAME=$(get_site_filename "$PRODUCT_NAME" "$ENVIRONMENT")
    NGINX_SITE_FILE="${NGINX_AXON_DIR}/sites/${NGINX_SITE_FILENAME}"

    # Use ENV_FILE_PATH from load_config, rename to ENV_PATH for this script
    ENV_PATH="$ENV_FILE_PATH"

    # Extract directory from env_path for deployment operations
    APP_DEPLOY_PATH=$(dirname "$ENV_PATH")

    # Validate required registry configuration
    if [ "${VERBOSE:-false}" = "true" ]; then
        echo "[VERBOSE] deploy.sh: Validating registry configuration..." >&2
    fi

    REGISTRY_PROVIDER=$(get_registry_provider)
    if [ -z "$REGISTRY_PROVIDER" ]; then
        echo -e "${RED}Error: Registry provider not configured${NC}"
        echo "Please set 'registry.provider' in $CONFIG_FILE"
        exit 1
    fi

    if [ "${VERBOSE:-false}" = "true" ]; then
        echo "[VERBOSE] deploy.sh: Registry provider validated, building image URI..." >&2
    fi

    # Build image URI
    FULL_IMAGE=$(build_image_uri "$IMAGE_TAG")
    if [ $? -ne 0 ] || [ -z "$FULL_IMAGE" ]; then
        echo -e "${RED}Error: Could not build image URI${NC}"
        echo "Check your registry configuration in $CONFIG_FILE"
        exit 1
    fi

    if [ "${VERBOSE:-false}" = "true" ]; then
        echo "[VERBOSE] deploy.sh: Image URI built successfully: $FULL_IMAGE" >&2
    fi

    # Validate required server configuration
    MISSING_CONFIG=()
    [ -z "$SYSTEM_SERVER_HOST" ] && MISSING_CONFIG+=("servers.system.host")
    [ -z "$APP_SERVER_HOST" ] && MISSING_CONFIG+=("servers.application.host")

    if [ ${#MISSING_CONFIG[@]} -gt 0 ]; then
        echo -e "${RED}Error: Missing required configuration:${NC}"
        for key in "${MISSING_CONFIG[@]}"; do
            echo "  - $key"
        done
        exit 1
    fi

    # Display configuration
    echo -e "${BLUE}Configuration loaded:${NC}"
    echo -e "  Product:            ${YELLOW}${PRODUCT_NAME}${NC}"
    echo -e "  Environment:        ${YELLOW}${ENVIRONMENT}${NC}"
    echo -e "  Registry:           ${YELLOW}${REGISTRY_PROVIDER}${NC}"
    echo -e "  Image:              ${YELLOW}${FULL_IMAGE}${NC}"
    echo -e "  System Server:      ${YELLOW}${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}${NC}"
    echo -e "  Application Server: ${YELLOW}${APP_SERVER_USER}@${APP_SERVER_HOST}${NC}"
    echo -e "  Deploy Path:        ${YELLOW}${APP_DEPLOY_PATH}${NC}"
    echo -e "  Port Assignment:    ${YELLOW}Auto (Docker assigns)${NC}"
    echo ""

    # SSH connection strings
    SYSTEM_SERVER="${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}"
    APP_SERVER="${APP_SERVER_USER}@${APP_SERVER_HOST}"

    # Check SSH keys exist
    if [ ! -f "$SSH_KEY" ]; then
        echo -e "${RED}Error: System Server SSH key not found: $SSH_KEY${NC}"
        echo "Please run setup scripts first or check your configuration."
        exit 1
    fi

    if [ ! -f "$APP_SSH_KEY" ]; then
        echo -e "${RED}Error: Application Server SSH key not found: $APP_SSH_KEY${NC}"
        echo "Please run setup scripts first or check your configuration."
        exit 1
    fi

    # Step 0: Pre-flight nginx validation on System Server
    echo -e "${BLUE}Step 0/9: Validating nginx setup on System Server...${NC}"

    # Determine sudo usage
    if [ "$SYSTEM_SERVER_USER" = "root" ]; then
        USE_SUDO=""
    else
        USE_SUDO="sudo"
    fi

    # Batch pre-flight checks on System Server
    ssh_batch_start
    ssh_batch_add "command -v nginx > /dev/null 2>&1 && echo 'INSTALLED' || echo 'NOT_INSTALLED'" "nginx_installed"
    ssh_batch_add "${USE_SUDO} systemctl is-active nginx 2>/dev/null || (pgrep nginx > /dev/null 2>&1 && echo 'active' || echo 'inactive')" "nginx_running"
    ssh_batch_add "[ -d '${NGINX_AXON_DIR}/upstreams' ] && echo 'EXISTS' || echo 'MISSING'" "upstreams_dir"
    ssh_batch_add "[ -d '${NGINX_AXON_DIR}/sites' ] && echo 'EXISTS' || echo 'MISSING'" "sites_dir"
    ssh_batch_add "${USE_SUDO} nginx -t 2>&1 | grep -q 'successful' && echo 'VALID' || echo 'INVALID'" "nginx_config_valid"
    ssh_batch_add "grep -qF 'include ${NGINX_AXON_DIR}/upstreams/*.conf' /etc/nginx/nginx.conf && echo 'INCLUDED' || echo 'MISSING'" "upstreams_included"
    ssh_batch_add "grep -qF 'include ${NGINX_AXON_DIR}/sites/*.conf' /etc/nginx/nginx.conf && echo 'INCLUDED' || echo 'MISSING'" "sites_included"
    ssh_batch_execute "$SSH_KEY" "$SYSTEM_SERVER" "system"

    # Check nginx installation
    NGINX_INSTALLED=$(ssh_batch_result "nginx_installed" | tr -d '[:space:]')
    if [ "$NGINX_INSTALLED" != "INSTALLED" ]; then
        echo -e "  ${RED}✗ nginx is not installed on System Server${NC}"
        echo -e ""
        echo -e "  Please install nginx first:"
        echo -e "  ${CYAN}ssh $SYSTEM_SERVER '${USE_SUDO} apt update && ${USE_SUDO} apt install -y nginx'${NC}"
        exit 1
    fi
    echo -e "  ${GREEN}✓ nginx is installed${NC}"

    # Check nginx is running
    NGINX_RUNNING=$(ssh_batch_result "nginx_running" | tr -d '[:space:]')
    if [ "$NGINX_RUNNING" != "active" ]; then
        echo -e "  ${YELLOW}⚠ nginx is not running${NC}"
        echo -e "  ${YELLOW}  Start nginx: ssh $SYSTEM_SERVER '${USE_SUDO} systemctl start nginx'${NC}"
    fi

    # Check AXON directories exist
    UPSTREAMS_DIR=$(ssh_batch_result "upstreams_dir" | tr -d '[:space:]')
    SITES_DIR=$(ssh_batch_result "sites_dir" | tr -d '[:space:]')

    if [ "$UPSTREAMS_DIR" != "EXISTS" ] || [ "$SITES_DIR" != "EXISTS" ]; then
        echo -e "  ${RED}✗ AXON directories not found on System Server${NC}"
        echo -e ""
        echo -e "  Please run setup first:"
        echo -e "  ${CYAN}axon setup system-server${NC}"
        exit 1
    fi
    echo -e "  ${GREEN}✓ AXON directories exist${NC}"

    # Check nginx config validity
    NGINX_CONFIG_VALID=$(ssh_batch_result "nginx_config_valid" | tr -d '[:space:]')
    if [ "$NGINX_CONFIG_VALID" != "VALID" ]; then
        echo -e "  ${RED}✗ nginx configuration is invalid${NC}"
        echo -e ""
        echo -e "  Please fix nginx configuration on System Server:"
        echo -e "  ${CYAN}ssh $SYSTEM_SERVER '${USE_SUDO} nginx -t'${NC}"
        exit 1
    fi
    echo -e "  ${GREEN}✓ nginx configuration is valid${NC}"

    # Check AXON includes in nginx.conf
    UPSTREAMS_INCLUDED=$(ssh_batch_result "upstreams_included" | tr -d '[:space:]')
    SITES_INCLUDED=$(ssh_batch_result "sites_included" | tr -d '[:space:]')

    if [ "$UPSTREAMS_INCLUDED" != "INCLUDED" ] || [ "$SITES_INCLUDED" != "INCLUDED" ]; then
        echo -e "  ${RED}✗ AXON includes not found in nginx.conf${NC}"
        echo -e ""
        echo -e "  Please run setup first:"
        echo -e "  ${CYAN}axon setup system-server${NC}"
        exit 1
    fi
    echo -e "  ${GREEN}✓ AXON includes are configured${NC}"

    echo -e "  ${GREEN}✓ All pre-flight checks passed${NC}"
    echo ""

    # Step 1: Detect current deployment (PARALLELIZED)
    echo -e "${BLUE}Step 1/9: Detecting current deployment...${NC}"

    # PARALLEL: Query System Server and App Server simultaneously
    # Batch 1: Get current port from System Server
    ssh_batch_start
    ssh_batch_add "grep -oP 'server.*:\K\d+' $NGINX_UPSTREAM_FILE 2>/dev/null || echo ''" "current_port"
    ssh_batch_execute_async "$SSH_KEY" "$SYSTEM_SERVER" "system_check" "system"

    # Batch 2: App Server pre-checks
    ssh_batch_start
    ssh_batch_add "docker ps --format '{{.Names}}\t{{.Ports}}' | grep '${PRODUCT_NAME}-${ENVIRONMENT}' || true" "list_containers"
    ssh_batch_add "mkdir -p $APP_DEPLOY_PATH" "create_dir"
    ssh_batch_add "[ -f '$ENV_PATH' ] && echo 'YES' || echo 'NO'" "check_env"
    ssh_batch_execute_async "$APP_SSH_KEY" "$APP_SERVER" "app_check" "app"

    # Wait for both to complete
    ssh_batch_wait "system_check" "app_check"

    # Extract results from System Server
    CURRENT_PORT=$(ssh_batch_result_from "system_check" "current_port")
    CURRENT_PORT=$(echo "$CURRENT_PORT" | tr -d '[:space:]')  # Trim whitespace

    # Extract results from App Server
    CONTAINER_LIST=$(ssh_batch_result_from "app_check" "list_containers")

    # Find current container by port if we have one
    CURRENT_CONTAINER=""
    if [ -n "$CURRENT_PORT" ]; then
        # Parse container list to find one using current port
        CURRENT_CONTAINER=$(echo "$CONTAINER_LIST" | grep ":${CURRENT_PORT}->" | awk '{print $1}' | head -1)
        echo -e "  Current active port: ${YELLOW}$CURRENT_PORT${NC}"
        if [ -n "$CURRENT_CONTAINER" ]; then
            echo -e "  Current container:   ${YELLOW}$CURRENT_CONTAINER${NC}"
        fi
    else
        echo -e "  No active deployment detected (first deployment)"
    fi

    # Step 2: Generate new container name (timestamp-based for uniqueness)
    TIMESTAMP=$(date +%s)
    NEW_CONTAINER="${PRODUCT_NAME}-${ENVIRONMENT}-${TIMESTAMP}"

    echo -e "  New container:       ${GREEN}$NEW_CONTAINER${NC}"
    echo -e "  Port:                ${GREEN}Auto-assigned by Docker${NC}"
    echo ""

    # Step 2: Check deployment files on Application Server
    echo -e "${BLUE}Step 2/9: Checking deployment files on Application Server...${NC}"

    # Check if .env file exists (already checked in parallel batch above)
    ENV_EXISTS=$(ssh_batch_result_from "app_check" "check_env")

    if [ "$ENV_EXISTS" = "NO" ]; then
        echo -e "${YELLOW}⚠ Warning: Environment file not found on Application Server: ${ENV_PATH}${NC}"
        echo -e "${YELLOW}  Please create it manually with your environment variables${NC}"
        echo -e "${YELLOW}  Example: ssh ${APP_SERVER} 'cat > ${ENV_PATH}'${NC}"
        ssh_batch_cleanup "system_check" "app_check"
        exit 1
    fi
    echo -e "  ✓ Environment file exists: ${ENV_PATH}"
    echo ""

    # Clean up async batch resources from Step 1
    ssh_batch_cleanup "system_check" "app_check"

    # Step 4: Authenticate with registry on Application Server and pull latest image
    echo -e "${BLUE}Step 3/9: Authenticating and pulling image on Application Server...${NC}"
    echo -e "  Registry: ${YELLOW}${REGISTRY_PROVIDER}${NC}"
    echo -e "  Image:    ${YELLOW}${FULL_IMAGE}${NC}"

    # Get SSH multiplexing options for app server
    local ssh_multiplex_opts=""
    if type ssh_get_multiplex_opts >/dev/null 2>&1; then
        ssh_multiplex_opts=$(ssh_get_multiplex_opts "app")
    fi

    # Generate registry-specific authentication commands for remote execution
    case $REGISTRY_PROVIDER in
        docker_hub)
            REGISTRY_USERNAME=$(get_registry_config "username")
            REGISTRY_TOKEN=$(get_registry_config "access_token")
            REGISTRY_TOKEN=$(expand_env_vars "$REGISTRY_TOKEN")

            ssh $ssh_multiplex_opts -i "$APP_SSH_KEY" "$APP_SERVER" bash <<EOF
    set -e
    echo "$REGISTRY_TOKEN" | docker login -u "$REGISTRY_USERNAME" --password-stdin
    docker pull "$FULL_IMAGE"
EOF
            ;;

        aws_ecr)
            AWS_PROFILE=$(get_registry_config "profile")
            AWS_REGION=$(get_registry_config "region")
            REGISTRY_URL=$(build_registry_url)

            # Build AWS CLI command with conditional profile flag
            if [ -n "$AWS_PROFILE" ]; then
                ssh $ssh_multiplex_opts -i "$APP_SSH_KEY" "$APP_SERVER" bash <<EOF
    set -e
    aws ecr get-login-password --region '$AWS_REGION' --profile '$AWS_PROFILE' | \
        docker login --username AWS --password-stdin '$REGISTRY_URL'
    docker pull '$FULL_IMAGE'
EOF
            else
                ssh $ssh_multiplex_opts -i "$APP_SSH_KEY" "$APP_SERVER" bash <<EOF
    set -e
    aws ecr get-login-password --region '$AWS_REGION' | \
        docker login --username AWS --password-stdin '$REGISTRY_URL'
    docker pull '$FULL_IMAGE'
EOF
            fi
            ;;

        google_gcr)
            SERVICE_ACCOUNT_KEY=$(get_registry_config "service_account_key")
            if [ -n "$SERVICE_ACCOUNT_KEY" ]; then
                SERVICE_ACCOUNT_KEY="${SERVICE_ACCOUNT_KEY/#\~/$HOME}"
                REMOTE_KEY="/tmp/gcp-key-$$.json"
                scp -i "$APP_SSH_KEY" "$SERVICE_ACCOUNT_KEY" "$APP_SERVER:$REMOTE_KEY"

                ssh $ssh_multiplex_opts -i "$APP_SSH_KEY" "$APP_SERVER" bash <<EOF
    set -e
    cat "$REMOTE_KEY" | docker login -u _json_key --password-stdin https://gcr.io
    rm -f "$REMOTE_KEY"
    docker pull "$FULL_IMAGE"
EOF
            else
                ssh $ssh_multiplex_opts -i "$APP_SSH_KEY" "$APP_SERVER" bash <<EOF
    set -e
    gcloud auth configure-docker --quiet
    docker pull "$FULL_IMAGE"
EOF
            fi
            ;;

        azure_acr)
            SP_ID=$(get_registry_config "service_principal_id")
            SP_PASSWORD=$(get_registry_config "service_principal_password")
            ADMIN_USER=$(get_registry_config "admin_username")
            ADMIN_PASSWORD=$(get_registry_config "admin_password")
            REGISTRY_NAME=$(get_registry_config "registry_name")
            REGISTRY_URL="${REGISTRY_NAME}.azurecr.io"

            if [ -n "$SP_ID" ] && [ -n "$SP_PASSWORD" ]; then
                SP_PASSWORD=$(expand_env_vars "$SP_PASSWORD")
                ssh $ssh_multiplex_opts -i "$APP_SSH_KEY" "$APP_SERVER" bash <<EOF
    set -e
    echo "$SP_PASSWORD" | docker login "$REGISTRY_URL" --username "$SP_ID" --password-stdin
    docker pull "$FULL_IMAGE"
EOF
            elif [ -n "$ADMIN_USER" ] && [ -n "$ADMIN_PASSWORD" ]; then
                ADMIN_PASSWORD=$(expand_env_vars "$ADMIN_PASSWORD")
                ssh $ssh_multiplex_opts -i "$APP_SSH_KEY" "$APP_SERVER" bash <<EOF
    set -e
    echo "$ADMIN_PASSWORD" | docker login "$REGISTRY_URL" --username "$ADMIN_USER" --password-stdin
    docker pull "$FULL_IMAGE"
EOF
            else
                ssh $ssh_multiplex_opts -i "$APP_SSH_KEY" "$APP_SERVER" bash <<EOF
    set -e
    az acr login --name "$REGISTRY_NAME"
    docker pull "$FULL_IMAGE"
EOF
            fi
            ;;

        *)
            echo -e "${RED}Error: Unknown registry provider: $REGISTRY_PROVIDER${NC}"
            exit 1
            ;;
    esac

    if [ $? -ne 0 ]; then
        echo -e "${RED}Error: Image pull failed${NC}"
        exit 1
    fi

    echo -e "  ✓ Image pulled successfully"
    echo ""

    # Step 4: Force cleanup if requested (optional step)
    if [ "$FORCE_CLEANUP" = true ]; then
        echo -e "${YELLOW}Force cleanup enabled - removing containers on port ${APP_PORT}...${NC}"

        ssh -i "$APP_SSH_KEY" "$APP_SERVER" bash <<EOF
    # Find containers using the target port
    BLOCKING_CONTAINERS=\$(docker ps -a --filter "publish=${APP_PORT}" --format "{{.Names}}")

    if [ -n "\$BLOCKING_CONTAINERS" ]; then
        echo "  Found containers blocking port ${APP_PORT}:"
        echo "\$BLOCKING_CONTAINERS" | while read container; do
            echo "    - \$container"
            docker stop "\$container" 2>/dev/null || true
            docker rm "\$container" 2>/dev/null || true
        done
        echo "  ✓ Cleanup completed"
    else
        echo "  No containers blocking port ${APP_PORT}"
    fi
EOF

        echo ""
    fi

    # Step 4: Start new container on Application Server
    echo -e "${BLUE}Step 4/9: Starting new container on Application Server...${NC}"
    echo -e "  Container: ${YELLOW}${NEW_CONTAINER}${NC}"
    echo -e "  Port: ${YELLOW}Auto-assigned by Docker${NC}"

    # Build docker run command from axon.config.yml
    # FULL_IMAGE already defined earlier using build_image_uri()
    CONTAINER_NAME="${NEW_CONTAINER}"

    # Get network name from config with template substitution
    NETWORK_NAME_TEMPLATE=$(parse_config ".docker.network_name" "")
    eval "NETWORK_NAME=\"$NETWORK_NAME_TEMPLATE\""

    # Add network alias if configured
    NETWORK_ALIAS_TEMPLATE=$(parse_config ".docker.network_alias" "")
    eval "NETWORK_ALIAS=\"$NETWORK_ALIAS_TEMPLATE\""

    # Build the docker run command from axon.config.yml (single source of truth)
    # Note: We pass "auto" for app_port to let Docker assign a random port
    DOCKER_RUN_CMD=$(build_docker_run_command \
        "$CONTAINER_NAME" \
        "auto" \
        "$FULL_IMAGE" \
        "$ENV_PATH" \
        "$NETWORK_NAME" \
        "$NETWORK_ALIAS" \
        "$CONTAINER_PORT")

    ssh -i "$APP_SSH_KEY" "$APP_SERVER" bash <<EOF
    set -e
    cd $APP_DEPLOY_PATH

    FULL_IMAGE="${FULL_IMAGE}"
    CONTAINER_NAME="${CONTAINER_NAME}"
    NETWORK_NAME="${NETWORK_NAME}"

    # Create network if it doesn't exist
    if ! docker network ls | grep -q "\${NETWORK_NAME}"; then
        docker network create "\${NETWORK_NAME}"
    fi

    # Remove container if it already exists (for retries)
    if docker ps -a --format '{{.Names}}' | grep -q "^\${CONTAINER_NAME}\$"; then
        echo "  Removing existing container \${CONTAINER_NAME}..."
        docker stop "\${CONTAINER_NAME}" 2>/dev/null || true
        docker rm "\${CONTAINER_NAME}" 2>/dev/null || true
    fi

    # Start new container using docker run command built from docker-compose.yml
    # This ensures we don't interfere with the old container and maintains docker-compose.yml as source of truth
    echo "  Running docker run command: ${DOCKER_RUN_CMD}"
    ${DOCKER_RUN_CMD}

    if [ \$? -ne 0 ]; then
        echo "Error: Failed to start container"
        exit 1
    fi
EOF

    if [ $? -ne 0 ]; then
        echo -e "${RED}Error: Failed to start container${NC}"
        exit 1
    fi

    echo -e "  ✓ Container started"
    echo ""

    # Query Docker for the assigned port
    APP_PORT=$(ssh -i "$APP_SSH_KEY" "$APP_SERVER" \
        "docker port ${CONTAINER_NAME} ${CONTAINER_PORT} | cut -d: -f2")

    if [ -z "$APP_PORT" ]; then
        echo -e "${RED}Error: Could not determine assigned port${NC}"
        echo -e "${YELLOW}Stopping new container...${NC}"
        axon_ssh "app" -i "$APP_SSH_KEY" "$APP_SERVER" "docker stop ${CONTAINER_NAME} && docker rm ${CONTAINER_NAME}"
        exit 1
    fi

    echo -e "  ${GREEN}✓ Docker assigned port: ${APP_PORT}${NC}"
    echo ""

    # Step 5: Wait for Docker health check on Application Server
    echo -e "${BLUE}Step 5/9: Waiting for health check on Application Server...${NC}"

    RETRY_COUNT=0

    while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        # Query Docker's health status for the container
        HEALTH_STATUS=$(axon_ssh "app" -i "$APP_SSH_KEY" "$APP_SERVER" \
            "docker inspect --format='{{.State.Health.Status}}' ${CONTAINER_NAME} 2>/dev/null || echo 'none'")

        if [ "$HEALTH_STATUS" = "healthy" ]; then
            echo -e "${GREEN}  ✓ Health check passed!${NC}"
            break
        elif [ "$HEALTH_STATUS" = "none" ]; then
            echo -e "${YELLOW}  Warning: Container has no health check configured${NC}"
            echo -e "${YELLOW}  Proceeding anyway...${NC}"
            break
        fi

        RETRY_COUNT=$((RETRY_COUNT + 1))
        if [ "$HEALTH_STATUS" = "unhealthy" ]; then
            echo -e "  ${RED}Attempt $RETRY_COUNT/$MAX_RETRIES (status: unhealthy)${NC}"
        else
            echo -e "  Attempt $RETRY_COUNT/$MAX_RETRIES (status: $HEALTH_STATUS)..."
        fi
        sleep $RETRY_INTERVAL
    done

    if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
        echo -e "${RED}Error: Container failed to become healthy after $MAX_RETRIES attempts${NC}"
        echo -e "${RED}Final status: $HEALTH_STATUS${NC}"

        if [ "$AUTO_ROLLBACK" == "true" ]; then
            echo -e "${YELLOW}Auto-rollback enabled. Stopping new container...${NC}"

            ssh -i "$APP_SSH_KEY" "$APP_SERVER" bash <<EOF
    # Stop and remove the failed container
    if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}\$"; then
        echo "  Stopping ${CONTAINER_NAME}..."
        docker stop "${CONTAINER_NAME}" 2>/dev/null || true
        docker rm "${CONTAINER_NAME}" 2>/dev/null || true
    fi
EOF

            echo -e "${YELLOW}Old container still running. No impact to production.${NC}"
        fi

        exit 1
    fi
    echo ""

    # Step 6: Generate nginx configs (site + upstream)
    echo -e "${BLUE}Step 6/9: Generating nginx configurations for ${ENVIRONMENT}...${NC}"

    # Get nginx settings for this environment
    DOMAIN=$(get_nginx_domain "$ENVIRONMENT" "$CONFIG_FILE")
    PROXY_TIMEOUT=$(get_nginx_proxy_setting "timeout" "$CONFIG_FILE")
    PROXY_BUFFER_SIZE=$(get_nginx_proxy_setting "buffer_size" "$CONFIG_FILE")
    PROXY_BUFFERS=$(get_nginx_proxy_setting "buffers" "$CONFIG_FILE")
    PROXY_BUSY_BUFFERS=$(get_nginx_proxy_setting "busy_buffers_size" "$CONFIG_FILE")
    CUSTOM_PROPS=$(get_nginx_custom_properties "$CONFIG_FILE")
    HAS_SSL=$(has_ssl_config "$ENVIRONMENT" "$CONFIG_FILE")
    SSL_CERT=$(get_ssl_certificate "$ENVIRONMENT" "$CONFIG_FILE")
    SSL_KEY=$(get_ssl_certificate_key "$ENVIRONMENT" "$CONFIG_FILE")

    # Generate site config
    echo -e "  Generating site config..."
    TEMP_SITE_FILE="/tmp/${NGINX_SITE_FILENAME%.conf}-site.conf"
    generate_nginx_proxy_site_config \
        "$TEMP_SITE_FILE" \
        "$PRODUCT_NAME" \
        "$ENVIRONMENT" \
        "$DOMAIN" \
        "$NGINX_UPSTREAM_NAME" \
        "$HAS_SSL" \
        "$SSL_CERT" \
        "$SSL_KEY" \
        "$PROXY_TIMEOUT" \
        "$PROXY_BUFFER_SIZE" \
        "$PROXY_BUFFERS" \
        "$PROXY_BUSY_BUFFERS" \
        "$CUSTOM_PROPS"

    echo -e "  ✓ Site config generated: ${NGINX_SITE_FILENAME}"

    # Generate upstream config
    echo -e "  Generating upstream config..."
    TEMP_UPSTREAM_FILE="/tmp/${NGINX_UPSTREAM_FILENAME%.conf}-upstream.conf"
    generate_nginx_upstream_config \
        "$TEMP_UPSTREAM_FILE" \
        "$PRODUCT_NAME" \
        "$ENVIRONMENT" \
        "$NGINX_UPSTREAM_NAME" \
        "$APP_UPSTREAM_IP" \
        "$APP_PORT"

    echo -e "  ✓ Upstream config generated: ${NGINX_UPSTREAM_FILENAME}"

    # Step 7: Upload and apply nginx configs
    echo -e "${BLUE}Step 7/9: Updating System Server nginx...${NC}"

    # Batch: Ensure directories, upload configs, test, and reload nginx
    ssh_batch_start
    ssh_batch_add "${USE_SUDO} mkdir -p ${NGINX_AXON_DIR}/upstreams ${NGINX_AXON_DIR}/sites" "ensure_dirs"
    ssh_batch_execute "$SSH_KEY" "$SYSTEM_SERVER" "system"

    # Upload both configs (using distinct temp names on both local and remote)
    REMOTE_TEMP_SITE="/tmp/${NGINX_SITE_FILENAME%.conf}-site.conf"
    REMOTE_TEMP_UPSTREAM="/tmp/${NGINX_UPSTREAM_FILENAME%.conf}-upstream.conf"

    scp -i "$SSH_KEY" "$TEMP_SITE_FILE" \
        "${SYSTEM_SERVER}:${REMOTE_TEMP_SITE}" > /dev/null 2>&1
    scp -i "$SSH_KEY" "$TEMP_UPSTREAM_FILE" \
        "${SYSTEM_SERVER}:${REMOTE_TEMP_UPSTREAM}" > /dev/null 2>&1

    # Move to final locations and validate
    ssh_batch_start
    ssh_batch_add "${USE_SUDO} mv ${REMOTE_TEMP_SITE} ${NGINX_SITE_FILE}" "move_site"
    ssh_batch_add "${USE_SUDO} mv ${REMOTE_TEMP_UPSTREAM} ${NGINX_UPSTREAM_FILE}" "move_upstream"
    ssh_batch_add "${USE_SUDO} nginx -t 2>&1" "test_nginx"
    ssh_batch_add "${USE_SUDO} nginx -s reload" "reload_nginx"
    ssh_batch_execute "$SSH_KEY" "$SYSTEM_SERVER" "system"

    # Check if upload succeeded
    if [ $(ssh_batch_exitcode "move_site") -ne 0 ] || [ $(ssh_batch_exitcode "move_upstream") -ne 0 ]; then
        echo -e "${RED}Error: Failed to update nginx configuration files${NC}"
        # Cleanup local temp files
        rm -f "$TEMP_SITE_FILE" "$TEMP_UPSTREAM_FILE"
        exit 1
    fi

    echo -e "  ✓ Site config: ${NGINX_SITE_FILE}"
    echo -e "  ✓ Upstream config: ${NGINX_UPSTREAM_FILE} (port $APP_PORT)"

    # Cleanup local temp files
    rm -f "$TEMP_SITE_FILE" "$TEMP_UPSTREAM_FILE"
    echo ""

    # Step 8: Test nginx configuration
    echo -e "${BLUE}Step 8/9: Testing nginx configuration on System Server...${NC}"

    NGINX_TEST_OUTPUT=$(ssh_batch_result "test_nginx")

    if ! echo "$NGINX_TEST_OUTPUT" | grep -q "successful"; then
        echo -e "${RED}Error: nginx configuration test failed!${NC}"
        echo ""
        echo -e "${YELLOW}nginx -t output:${NC}"
        echo "$NGINX_TEST_OUTPUT"
        echo ""

        # Rollback nginx config
        echo -e "${YELLOW}Rolling back nginx configuration...${NC}"
        ROLLBACK_CONFIG="upstream $NGINX_UPSTREAM_NAME {
        server $APP_UPSTREAM_IP:$CURRENT_PORT;
    }"
        ssh -i "$SSH_KEY" "$SYSTEM_SERVER" "echo '$ROLLBACK_CONFIG' | ${USE_SUDO} tee $NGINX_UPSTREAM_FILE > /dev/null"

        # Stop new container
        echo -e "${YELLOW}Stopping new container on Application Server...${NC}"
        ssh -i "$APP_SSH_KEY" "$APP_SERVER" bash <<EOF
    # Stop and remove the specific failed container
    FAILED_CONTAINER="${PRODUCT_NAME}-${ENVIRONMENT}-${APP_PORT}"

    if docker ps -a --format '{{.Names}}' | grep -q "^\${FAILED_CONTAINER}\$"; then
        echo "  Stopping \${FAILED_CONTAINER}..."
        docker stop "\${FAILED_CONTAINER}" 2>/dev/null || true
        docker rm "\${FAILED_CONTAINER}" 2>/dev/null || true
    fi
EOF

        exit 1
    fi

    echo -e "  ✓ nginx configuration is valid"

    # Check reload result from batch (reload happened during Step 7)
    if [ $(ssh_batch_exitcode "reload_nginx") -ne 0 ]; then
        echo -e "${RED}Error: nginx reload failed!${NC}"
        exit 1
    fi

    echo -e "  ${GREEN}✓ nginx reloaded successfully (zero-downtime)${NC}"
    echo -e "  ${GREEN}✓ Traffic now flows to new container (port $APP_PORT)${NC}"
    echo ""

    # Step 9: Graceful shutdown of old containers (BACKGROUND)
    echo -e "${BLUE}Step 9/9: Gracefully shutting down old containers (timeout: ${GRACEFUL_SHUTDOWN_TIMEOUT}s)...${NC}"

    # Run cleanup in background - deployment is already successful
    {
        ssh -i "$APP_SSH_KEY" "$APP_SERVER" bash <<EOF
    # Find all containers for this product/environment except the new one
    NEW_CONTAINER="${CONTAINER_NAME}"
    PRODUCT_ENV_PREFIX="${PRODUCT_NAME}-${ENVIRONMENT}"
    TIMEOUT="${GRACEFUL_SHUTDOWN_TIMEOUT}"

    # Get list of all containers for this product/environment
    OLD_CONTAINERS=\$(docker ps -a --filter "name=\${PRODUCT_ENV_PREFIX}" --format '{{.Names}}' | grep -v "^\${NEW_CONTAINER}\$" || true)

    if [ -n "\$OLD_CONTAINERS" ]; then
        # Silently cleanup old containers in background
        for container in \$OLD_CONTAINERS; do
            docker stop --timeout "\${TIMEOUT}" "\$container" 2>/dev/null || true
            docker rm "\$container" 2>/dev/null || true
        done
    fi
EOF
    } >/dev/null 2>&1 &

    # Store cleanup PID for reference
    CLEANUP_PID=$!

    echo -e "  ${GREEN}✓ Cleanup initiated in background (PID: $CLEANUP_PID)${NC}"
    echo -e "  ${CYAN}Note: Old containers are being removed asynchronously${NC}"
    echo ""

    # Success!
    echo -e "${GREEN}==================================================${NC}"
    echo -e "${GREEN}✓ Deployment completed successfully!${NC}"
    echo -e "${GREEN}==================================================${NC}"
    echo ""

    echo -e "${CYAN}Deployment Summary:${NC}"
    echo -e "  Product:          ${YELLOW}${PRODUCT_NAME}${NC}"
    echo -e "  Environment:      ${YELLOW}${ENVIRONMENT}${NC}"
    echo -e "  Active Port:      ${GREEN}${APP_PORT}${NC}"
    echo -e "  Container:        ${YELLOW}${CONTAINER_NAME}${NC}"
    echo -e "  Image:            ${YELLOW}${FULL_IMAGE}${NC}"
    echo ""

    echo -e "${CYAN}Useful Commands:${NC}"
    echo -e "  View logs:        ${BLUE}ssh -i $APP_SSH_KEY $APP_SERVER 'docker logs -f ${CONTAINER_NAME}'${NC}"
    echo -e "  Container status: ${BLUE}ssh -i $APP_SSH_KEY $APP_SERVER 'docker ps | grep ${PRODUCT_NAME}-${ENVIRONMENT}'${NC}"
    echo -e "  nginx upstream:   ${BLUE}ssh -i $SSH_KEY $SYSTEM_SERVER 'cat $NGINX_UPSTREAM_FILE'${NC}"
    echo ""

    # Batch: Display container status and logs (App Server)
    ssh_batch_start
    ssh_batch_add "docker ps --filter 'name=${PRODUCT_NAME}-${ENVIRONMENT}' --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'" "container_status"
    ssh_batch_add "if docker ps --filter 'name=${CONTAINER_NAME}' --format '{{.Names}}' | grep -q .; then docker logs --tail=20 '${CONTAINER_NAME}' 2>&1 | head -20; else echo 'Container not found'; fi" "container_logs"
    ssh_batch_execute "$APP_SSH_KEY" "$APP_SERVER" "app"

    # Display container status on Application Server
    echo -e "${CYAN}Container Status on Application Server:${NC}"
    ssh_batch_result "container_status"
    echo ""

    # Display recent logs from Application Server
    echo -e "${CYAN}Recent Logs (last 20 lines):${NC}"
    LOGS_OUTPUT=$(ssh_batch_result "container_logs")
    if [ "$LOGS_OUTPUT" != "Container not found" ]; then
        echo "$LOGS_OUTPUT"
    else
        echo "Container ${CONTAINER_NAME} not found"
    fi
    echo ""
}
