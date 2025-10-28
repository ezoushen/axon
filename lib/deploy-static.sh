#!/bin/bash
# AXON - Static Site Deployment Library
# Copyright (C) 2024-2025 ezoushen
# Licensed under GPL-3.0 - See LICENSE file for details
#
# Function for deploying static sites with zero-downtime

# ==============================================================================
# Static Site Deployment Function
# ==============================================================================
deploy_static() {
    # Get per-environment deployment configuration
    DEPLOY_PATH=$(get_deploy_path "$ENVIRONMENT" "$CONFIG_FILE")
    DOMAIN=$(get_domain "$ENVIRONMENT" "$CONFIG_FILE")

    # Get global static configuration
    DEPLOY_USER=$(get_static_deploy_user "$CONFIG_FILE")
    KEEP_RELEASES=$(get_static_keep_releases "$CONFIG_FILE")

    # Get nginx paths and names from defaults library
    NGINX_AXON_DIR=$(get_nginx_axon_dir "$CONFIG_FILE")
    NGINX_SITE_FILENAME=$(get_site_filename "$PRODUCT_NAME" "$ENVIRONMENT")
    NGINX_SITE_FILE="${NGINX_AXON_DIR}/sites/${NGINX_SITE_FILENAME}"

    # Validate required per-environment configuration
    if [ -z "$DEPLOY_PATH" ]; then
        echo -e "${RED}Error: environments.${ENVIRONMENT}.deploy_path not configured${NC}"
        echo "Please set 'environments.${ENVIRONMENT}.deploy_path' in $CONFIG_FILE"
        exit 1
    fi

    if [ -z "$DOMAIN" ]; then
        echo -e "${RED}Error: environments.${ENVIRONMENT}.domain not configured${NC}"
        echo "Please set 'environments.${ENVIRONMENT}.domain' in $CONFIG_FILE"
        exit 1
    fi

    # Validate System Server configuration
    if ! require_system_server "$CONFIG_FILE"; then
        exit 1
    fi

    # Display configuration
    echo -e "${BLUE}Configuration loaded:${NC}"
    echo -e "  Product:            ${YELLOW}${PRODUCT_NAME}${NC}"
    echo -e "  Environment:        ${YELLOW}${ENVIRONMENT}${NC}"
    echo -e "  Deploy Type:        ${YELLOW}Static Site${NC}"
    echo -e "  System Server:      ${YELLOW}${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}${NC}"
    echo -e "  Deploy Path:        ${YELLOW}${DEPLOY_PATH}/${ENVIRONMENT}${NC}"
    echo -e "  Keep Releases:      ${YELLOW}${KEEP_RELEASES}${NC}"
    echo ""

    # SSH connection strings
    SYSTEM_SERVER="${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}"

    # Check SSH key exists
    if [ ! -f "$SSH_KEY" ]; then
        echo -e "${RED}Error: System Server SSH key not found: $SSH_KEY${NC}"
        echo "Please check your configuration."
        exit 1
    fi

    # Determine sudo usage
    if [ "$SYSTEM_SERVER_USER" = "root" ]; then
        USE_SUDO=""
    else
        USE_SUDO="sudo"
    fi

    # Step 1: Find latest build archive
    echo -e "${BLUE}Step 1/12: Finding build archive on System Server...${NC}"

    LATEST_ARCHIVE=$(ssh -i "$SSH_KEY" "$SYSTEM_SERVER" \
        "ls -t /tmp/static-build-*.tar.gz 2>/dev/null | head -n 1")

    if [ -z "$LATEST_ARCHIVE" ]; then
        echo -e "${RED}Error: No build archive found in /tmp/ on System Server${NC}"
        echo "Please run build and push first:"
        echo "  axon build ${ENVIRONMENT}"
        echo "  axon push ${ENVIRONMENT}"
        exit 1
    fi

    # Extract release name from archive filename
    ARCHIVE_BASENAME=$(basename "$LATEST_ARCHIVE")
    RELEASE_NAME=$(echo "$ARCHIVE_BASENAME" | sed 's/static-build-\(.*\)\.tar\.gz/\1/')

    ARCHIVE_SIZE=$(ssh -i "$SSH_KEY" "$SYSTEM_SERVER" "du -sh '$LATEST_ARCHIVE' | cut -f1")

    echo -e "  Archive:         ${YELLOW}${LATEST_ARCHIVE}${NC}"
    echo -e "  Release Name:    ${YELLOW}${RELEASE_NAME}${NC}"
    echo -e "  Archive Size:    ${YELLOW}${ARCHIVE_SIZE}${NC}"
    echo ""

    # Step 2: Create directory structure
    echo -e "${BLUE}Step 2/12: Creating release directory structure...${NC}"

    RELEASE_PATH=$(get_release_path "$DEPLOY_PATH" "$ENVIRONMENT" "$RELEASE_NAME")
    SHARED_PATH=$(get_shared_path "$DEPLOY_PATH" "$ENVIRONMENT")
    CURRENT_SYMLINK=$(get_current_symlink_path "$DEPLOY_PATH" "$ENVIRONMENT")

    ssh -i "$SSH_KEY" "$SYSTEM_SERVER" bash <<EOF
set -e
# Create directories
$USE_SUDO mkdir -p "$RELEASE_PATH"
$USE_SUDO mkdir -p "$SHARED_PATH"
$USE_SUDO mkdir -p "$(dirname "$CURRENT_SYMLINK")"
echo "✓ Directories created"
EOF

    if [ $? -ne 0 ]; then
        echo -e "${RED}Error: Failed to create directory structure${NC}"
        exit 1
    fi

    echo -e "  Release Path:    ${YELLOW}${RELEASE_PATH}${NC}"
    echo -e "  Shared Path:     ${YELLOW}${SHARED_PATH}${NC}"
    echo -e "  Current Symlink: ${YELLOW}${CURRENT_SYMLINK}${NC}"
    echo ""

    # Step 3: Extract archive
    echo -e "${BLUE}Step 3/12: Extracting build archive...${NC}"

    ssh -i "$SSH_KEY" "$SYSTEM_SERVER" bash <<EOF
set -e
cd "$RELEASE_PATH"
$USE_SUDO tar -xzf "$LATEST_ARCHIVE"
if [ \$? -eq 0 ]; then
    echo "✓ Archive extracted successfully"
else
    echo "Error: Failed to extract archive"
    exit 1
fi
EOF

    if [ $? -ne 0 ]; then
        echo -e "${RED}Error: Failed to extract archive${NC}"
        exit 1
    fi
    echo ""

    # Step 4: Setup shared directories
    echo -e "${BLUE}Step 4/12: Setting up shared directories...${NC}"

    SHARED_DIRS=$(get_static_shared_dirs "$CONFIG_FILE")
    if [ -n "$SHARED_DIRS" ]; then
        while IFS= read -r shared_dir; do
            if [ -n "$shared_dir" ]; then
                ssh -i "$SSH_KEY" "$SYSTEM_SERVER" bash <<EOF
set -e
# Create shared directory if it doesn't exist
$USE_SUDO mkdir -p "${SHARED_PATH}/${shared_dir}"

# Remove directory from release if it exists
$USE_SUDO rm -rf "${RELEASE_PATH}/${shared_dir}"

# Create symlink
$USE_SUDO ln -s "${SHARED_PATH}/${shared_dir}" "${RELEASE_PATH}/${shared_dir}"

echo "✓ Linked: ${shared_dir} -> ${SHARED_PATH}/${shared_dir}"
EOF
            fi
        done <<< "$SHARED_DIRS"
    else
        echo "  No shared directories configured"
    fi
    echo ""

    # Step 5: Set file ownership and permissions
    echo -e "${BLUE}Step 5/12: Setting file permissions...${NC}"

    ssh -i "$SSH_KEY" "$SYSTEM_SERVER" bash <<EOF
set -e
${USE_SUDO} chown -R ${DEPLOY_USER}:${DEPLOY_USER} "$RELEASE_PATH"
${USE_SUDO} chmod -R 755 "$RELEASE_PATH"
echo "✓ Permissions set (owner: ${DEPLOY_USER})"
EOF

    if [ $? -ne 0 ]; then
        echo -e "${YELLOW}Warning: Failed to set permissions (continuing anyway)${NC}"
    fi
    echo ""

    # Step 6: Validate required files
    echo -e "${BLUE}Step 6/12: Validating required files...${NC}"

    REQUIRED_FILES=$(get_static_required_files "$CONFIG_FILE")
    if [ -n "$REQUIRED_FILES" ]; then
        VALIDATION_FAILED=false
        while IFS= read -r required_file; do
            if [ -n "$required_file" ]; then
                if ssh -i "$SSH_KEY" "$SYSTEM_SERVER" "[ -f '${RELEASE_PATH}/${required_file}' ]"; then
                    echo -e "  ${GREEN}✓${NC} ${required_file}"
                else
                    echo -e "  ${RED}✗${NC} ${required_file}"
                    VALIDATION_FAILED=true
                fi
            fi
        done <<< "$REQUIRED_FILES"

        if [ "$VALIDATION_FAILED" = true ]; then
            echo -e "${RED}Error: Required files missing${NC}"
            exit 1
        fi
    else
        echo "  No required files configured"
    fi
    echo ""

    # Step 7: Detect current deployment
    echo -e "${BLUE}Step 7/12: Detecting current deployment...${NC}"

    CURRENT_RELEASE=$(ssh -i "$SSH_KEY" "$SYSTEM_SERVER" \
        "if [ -L '$CURRENT_SYMLINK' ]; then readlink '$CURRENT_SYMLINK' | xargs basename; else echo ''; fi")

    if [ -n "$CURRENT_RELEASE" ]; then
        echo -e "  Current Release: ${YELLOW}${CURRENT_RELEASE}${NC}"
    else
        echo -e "  No current deployment (first deployment)"
    fi
    echo ""

    # Step 8: Atomic symlink switch
    echo -e "${BLUE}Step 8/12: Switching to new release (atomic operation)...${NC}"

    ssh -i "$SSH_KEY" "$SYSTEM_SERVER" bash <<EOF
set -e
# Create temporary symlink
TEMP_SYMLINK="${CURRENT_SYMLINK}.tmp.\$\$"
$USE_SUDO ln -s "$RELEASE_PATH" "\$TEMP_SYMLINK"

# Atomic move
$USE_SUDO mv -Tf "\$TEMP_SYMLINK" "$CURRENT_SYMLINK"

if [ \$? -eq 0 ]; then
    echo "✓ Symlink switched atomically"
else
    echo "Error: Failed to switch symlink"
    $USE_SUDO rm -f "\$TEMP_SYMLINK"
    exit 1
fi
EOF

    if [ $? -ne 0 ]; then
        echo -e "${RED}Error: Failed to switch symlink${NC}"
        exit 1
    fi

    echo -e "  ${GREEN}✓ Current symlink now points to: ${RELEASE_NAME}${NC}"
    echo ""

    # Step 9: Generate/Update nginx site configuration
    echo -e "${BLUE}Step 9/12: Generating nginx site configuration...${NC}"

    # Get nginx settings for this environment
    DOMAIN=$(get_nginx_domain "$ENVIRONMENT" "$CONFIG_FILE")
    HAS_SSL=$(has_ssl_config "$ENVIRONMENT" "$CONFIG_FILE")
    SSL_CERT=$(get_ssl_certificate "$ENVIRONMENT" "$CONFIG_FILE")
    SSL_KEY=$(get_ssl_certificate_key "$ENVIRONMENT" "$CONFIG_FILE")
    CUSTOM_PROPS=$(get_nginx_custom_properties "$CONFIG_FILE")

    # Generate site config for static files
    TEMP_SITE_FILE="/tmp/${NGINX_SITE_FILENAME%.conf}-static-site.conf"
    generate_nginx_static_site_config \
        "$TEMP_SITE_FILE" \
        "$PRODUCT_NAME" \
        "$ENVIRONMENT" \
        "$DOMAIN" \
        "$CURRENT_SYMLINK" \
        "$HAS_SSL" \
        "$SSL_CERT" \
        "$SSL_KEY" \
        "$CUSTOM_PROPS"

    echo -e "  ✓ Site config generated: ${NGINX_SITE_FILENAME}"
    echo ""

    # Step 10: Upload nginx configuration
    echo -e "${BLUE}Step 10/12: Uploading nginx configuration to System Server...${NC}"

    REMOTE_TEMP_SITE="/tmp/${NGINX_SITE_FILENAME%.conf}-static-site.conf"

    # Ensure sites directory exists
    ssh -i "$SSH_KEY" "$SYSTEM_SERVER" "${USE_SUDO} mkdir -p ${NGINX_AXON_DIR}/sites"

    # Upload config
    scp -i "$SSH_KEY" "$TEMP_SITE_FILE" \
        "${SYSTEM_SERVER}:${REMOTE_TEMP_SITE}" > /dev/null 2>&1

    # Move to final location
    ssh -i "$SSH_KEY" "$SYSTEM_SERVER" "${USE_SUDO} mv ${REMOTE_TEMP_SITE} ${NGINX_SITE_FILE}"

    if [ $? -ne 0 ]; then
        echo -e "${RED}Error: Failed to upload nginx configuration${NC}"
        rm -f "$TEMP_SITE_FILE"
        exit 1
    fi

    echo -e "  ✓ Site config uploaded: ${NGINX_SITE_FILE}"

    # Cleanup local temp file
    rm -f "$TEMP_SITE_FILE"
    echo ""

    # Step 11: Test and reload nginx
    echo -e "${BLUE}Step 11/12: Testing and reloading nginx...${NC}"

    # Test nginx configuration
    NGINX_TEST_OUTPUT=$(ssh -i "$SSH_KEY" "$SYSTEM_SERVER" "${USE_SUDO} nginx -t 2>&1")

    if ! echo "$NGINX_TEST_OUTPUT" | grep -q "successful"; then
        echo -e "${RED}Error: nginx configuration test failed!${NC}"
        echo ""
        echo -e "${YELLOW}nginx -t output:${NC}"
        echo "$NGINX_TEST_OUTPUT"
        echo ""

        # Rollback symlink if there was a previous release
        if [ -n "$CURRENT_RELEASE" ]; then
            echo -e "${YELLOW}Rolling back to previous release...${NC}"
            PREVIOUS_RELEASE_PATH=$(get_release_path "$DEPLOY_PATH" "$ENVIRONMENT" "$CURRENT_RELEASE")
            ssh -i "$SSH_KEY" "$SYSTEM_SERVER" "ln -snf '$PREVIOUS_RELEASE_PATH' '$CURRENT_SYMLINK'"
        fi

        exit 1
    fi

    echo -e "  ${GREEN}✓ nginx configuration is valid${NC}"

    # Reload nginx
    ssh -i "$SSH_KEY" "$SYSTEM_SERVER" "${USE_SUDO} nginx -s reload"

    if [ $? -ne 0 ]; then
        echo -e "${RED}Error: nginx reload failed!${NC}"
        exit 1
    fi

    echo -e "  ${GREEN}✓ nginx reloaded successfully (zero-downtime)${NC}"
    echo ""

    # Step 12: Cleanup old releases
    echo -e "${BLUE}Step 12/12: Cleaning up old releases (keeping last ${KEEP_RELEASES})...${NC}"

    ssh -i "$SSH_KEY" "$SYSTEM_SERVER" bash <<EOF
set -e
RELEASES_DIR="${DEPLOY_PATH}/${ENVIRONMENT}/releases"
if [ -d "\$RELEASES_DIR" ]; then
    # List releases by modification time (oldest first)
    cd "\$RELEASES_DIR"
    RELEASES=\$(ls -t | tail -n +\$((${KEEP_RELEASES} + 1)))

    if [ -n "\$RELEASES" ]; then
        echo "Removing old releases:"
        for release in \$RELEASES; do
            echo "  - \$release"
            $USE_SUDO rm -rf "\$release"
        done
    else
        echo "No old releases to remove"
    fi
fi
EOF

    echo ""

    # Success!
    echo -e "${GREEN}==================================================${NC}"
    echo -e "${GREEN}✓ Deployment completed successfully!${NC}"
    echo -e "${GREEN}==================================================${NC}"
    echo ""

    echo -e "${CYAN}Deployment Summary:${NC}"
    echo -e "  Product:          ${YELLOW}${PRODUCT_NAME}${NC}"
    echo -e "  Environment:      ${YELLOW}${ENVIRONMENT}${NC}"
    echo -e "  Release:          ${YELLOW}${RELEASE_NAME}${NC}"
    echo -e "  Deploy Path:      ${YELLOW}${CURRENT_SYMLINK}${NC}"
    echo -e "  Domain:           ${YELLOW}${DOMAIN}${NC}"
    echo ""

    echo -e "${CYAN}Useful Commands:${NC}"
    echo -e "  View site:        ${BLUE}http://${DOMAIN}${NC}"
    echo -e "  Current release:  ${BLUE}ssh -i $SSH_KEY $SYSTEM_SERVER 'readlink $CURRENT_SYMLINK'${NC}"
    echo -e "  nginx config:     ${BLUE}ssh -i $SSH_KEY $SYSTEM_SERVER 'cat $NGINX_SITE_FILE'${NC}"
    echo -e "  List releases:    ${BLUE}ssh -i $SSH_KEY $SYSTEM_SERVER 'ls -lt ${DEPLOY_PATH}/${ENVIRONMENT}/releases'${NC}"
    echo ""
}
