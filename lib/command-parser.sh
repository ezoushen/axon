#!/bin/bash
# AXON - Command Parser Library
# Copyright (C) 2024-2025 ezoushen
# Licensed under GPL-3.0 - See LICENSE file for details
#
# Provides command parsing and help system for axon CLI

# Command registry - list of valid commands
AXON_VALID_COMMANDS="build push deploy run build-and-push status logs restart health install uninstall delete config context env"

# Commands that require environment argument (delete is optional with --all)
AXON_ENV_REQUIRED_COMMANDS="build push deploy run build-and-push logs restart"

# Show main help
show_help() {
    cat <<EOF
AXON - Zero-Downtime Deployment Orchestration

Usage: axon <command> [environment] [options]

CORE COMMANDS:
  build <env>              Build Docker image
  push <env>               Push Docker image to ECR
  deploy <env>             Deploy to server with zero-downtime
  run <env>                Full pipeline: build → push → deploy

CONVENIENCE COMMANDS:
  build-and-push <env>     Build and push to ECR (skip deploy)

UTILITY COMMANDS:
  status <env|--all>       Show container status and Docker info (use --health for Docker health checks)
  logs <env|--all>         View container logs (specific environment or all)
  restart <env|--all>      Restart container (specific environment or all)
  health <env|--all>       Test application health endpoints (HTTP requests to /api/health, etc.)
  delete <env|--all>       Remove environment-specific configs (Docker + nginx)

CONFIGURATION COMMANDS:
  config init              Generate axon.config.yml file
  config validate          Validate configuration file

ENVIRONMENT FILE COMMANDS:
  env edit <env>           Edit .env file for environment on Application Server

CONTEXT COMMANDS:
  context add <name>       Add a new global context
  context use <name>       Switch to a context (deploy from anywhere)
  context list             List all contexts
  context current          Show current active context
  context remove <name>    Remove a context

INSTALLATION COMMANDS:
  install [server]         Install AXON on servers (default: all servers)
  install local            Install tools on local machine
  install app-server       Install Docker and tools on Application Server
  install system-server    Install nginx and setup on System Server
  uninstall [server]       Uninstall AXON from servers (default: all servers)
  uninstall local          Remove AXON tools from local machine
  uninstall app-server     Remove AXON setup from Application Server
  uninstall system-server  Remove AXON setup from System Server

GLOBAL OPTIONS:
  -c, --config FILE        Config file path (default: axon.config.yml)
  -h, --help               Show help for command
  -v, --verbose            Verbose output
  --dry-run                Show what would be done without executing
  --version                Show AXON version

EXAMPLES:
  axon build production --skip-git
  axon push staging --config custom.yml
  axon deploy production
  axon run staging
  axon build-and-push production
  axon logs production --follow
  axon status
  axon config init
  axon config init --interactive
  axon config validate --strict
  axon context add my-app
  axon context use my-app
  axon context list
  axon install local --auto-install
  axon install app-server
  axon install system-server
  axon install
  axon uninstall local

For command-specific help:
  axon <command> --help

Documentation: https://github.com/ezoushen/axon
EOF
}

# Show command-specific help
show_command_help() {
    local cmd=$1

    case "$cmd" in
        build)
            cat <<EOF
Usage: axon build <environment> [options]

Build Docker image locally with optional git SHA tagging.

OPTIONS:
  -c, --config FILE    Config file (default: axon.config.yml)
  --skip-git           Don't tag image with git SHA
  --sha <hash>         Use specific git SHA for tagging
  --no-cache           Build without Docker cache
  -h, --help           Show this help

EXAMPLES:
  axon build production
  axon build staging --skip-git
  axon build production --sha abc123
  axon build staging --config custom.yml --no-cache
EOF
            ;;
        push)
            cat <<EOF
Usage: axon push <environment> [options]

Push Docker image to AWS ECR. Requires image to be built first.

OPTIONS:
  -c, --config FILE    Config file (default: axon.config.yml)
  --sha <hash>         Also push specific SHA tag
  -h, --help           Show this help

EXAMPLES:
  axon push production
  axon push staging --sha abc123
  axon push production --config custom.yml
EOF
            ;;
        deploy)
            cat <<EOF
Usage: axon deploy <environment> [options]

Deploy to server with zero-downtime using image from ECR.

OPTIONS:
  -c, --config FILE      Config file (default: axon.config.yml)
  -f, --force            Force cleanup of existing containers
  --timeout <seconds>    Health check timeout (default: from config)
  -h, --help             Show this help

EXAMPLES:
  axon deploy production
  axon deploy staging --force
  axon deploy production --timeout 120
EOF
            ;;
        run)
            cat <<EOF
Usage: axon run <environment> [options]

Execute full deployment pipeline: build → push → deploy.

This is the primary deployment command that orchestrates the complete workflow.

OPTIONS:
  -c, --config FILE    Config file (default: axon.config.yml)
  --skip-git           Don't tag image with git SHA
  --sha <hash>         Use specific git SHA
  -f, --force          Force cleanup during deploy
  -h, --help           Show this help

EXAMPLES:
  axon run production
  axon run staging --skip-git
  axon run production --sha abc123
  axon run staging --config custom.yml
EOF
            ;;
        build-and-push)
            cat <<EOF
Usage: axon build-and-push <environment> [options]

Build Docker image and push to ECR without deploying.

Useful for CI/CD pipelines or when you want to test builds without deployment.

OPTIONS:
  -c, --config FILE    Config file (default: axon.config.yml)
  --skip-git           Don't tag image with git SHA
  --sha <hash>         Use specific git SHA
  --no-cache           Build without Docker cache
  -h, --help           Show this help

EXAMPLES:
  axon build-and-push production
  axon build-and-push staging --skip-git
  axon build-and-push production --sha abc123
EOF
            ;;
        status)
            cat <<EOF
Usage: axon status <environment|--all> [options]

Show comprehensive container status and Docker-level information.

This command displays container state, resource usage, configuration, and
Docker health check status (from Dockerfile HEALTHCHECK). It provides operational
insights into running containers without making active requests to your application.

Note: To actively test application health endpoints, use 'axon health' instead.

Display modes (can be combined):
  --detailed, --inspect     Show comprehensive container information
  --configuration, --env    Show configuration (env vars, volumes, ports)
  --health                  Show Docker health check status and history

OPTIONS:
  -c, --config FILE    Config file (default: axon.config.yml)
  --all                Show status for all environments
  -h, --help           Show this help

EXAMPLES:
  axon status --all                 # Summary of all environments
  axon status production            # Summary of specific environment
  axon status production --detailed # Detailed information
  axon status staging --health      # Docker health check status
  axon status --all --configuration # Configuration for all environments
EOF
            ;;
        logs)
            cat <<EOF
Usage: axon logs <environment|--all> [options]

View container logs for a specific environment or all environments.

OPTIONS:
  -c, --config FILE      Config file (default: axon.config.yml)
  --all                  View logs for all environments
  -f, --follow           Follow log output in real-time
  -n, --lines <number>   Number of lines to show (default: from script)
  --since <time>         Show logs since timestamp
  -h, --help             Show this help

EXAMPLES:
  axon logs production
  axon logs --all                   # View logs from all environments
  axon logs staging --follow
  axon logs production --lines 100
  axon logs staging --since "2024-01-01"
  axon logs --all --lines 50        # Last 50 lines from each environment
EOF
            ;;
        restart)
            cat <<EOF
Usage: axon restart <environment|--all> [options]

Restart container for a specific environment or all environments.

OPTIONS:
  -c, --config FILE    Config file (default: axon.config.yml)
  --all                Restart all environments
  -f, --force          Skip confirmation prompt (when using --all)
  -h, --help           Show this help

EXAMPLES:
  axon restart production
  axon restart --all                # Restart all environments (with confirmation)
  axon restart --all --force        # Restart all without confirmation
  axon restart staging --config custom.yml
EOF
            ;;
        delete)
            cat <<EOF
Usage: axon delete <environment|--all> [options]

Remove environment-specific configurations including Docker containers and nginx configs.

This command cleans up a specific environment (or all environments) while leaving the AXON
installation intact. It removes:
  - Docker containers for the environment(s)
  - Docker images tagged for the environment(s)
  - nginx site configuration(s)
  - nginx upstream configuration(s)

OPTIONS:
  -c, --config FILE    Config file (default: axon.config.yml)
  -f, --force          Skip confirmation prompt
  --all                Delete all configured environments
  -h, --help           Show this help

EXAMPLES:
  # Remove staging environment with confirmation
  axon delete staging

  # Force delete production without confirmation
  axon delete production --force

  # Delete with custom config
  axon delete staging --config custom.yml

  # Delete all environments (with confirmation)
  axon delete --all

  # Force delete all environments without confirmations
  axon delete --all --force

VALIDATION:
  - Checks if environment exists before deletion
  - Shows available environments if target not found
  - Lists resources found (containers, nginx configs)
  - Graceful container shutdown with configurable timeout

NOTES:
  - This does NOT remove the entire AXON installation
  - Use 'axon uninstall' to remove AXON completely
  - nginx will be reloaded after removing configs
  - Deleted environments cannot be recovered
EOF
            ;;
        health)
            cat <<EOF
Usage: axon health <environment|--all> [options]

Check application health by making HTTP requests to health endpoints.

This command actively tests your application's health endpoint (e.g., /api/health)
to verify the service is responding correctly. It checks business logic, database
connections, and external service availability through your defined health checks.

Note: This is different from Docker health checks. Use 'axon status --health' to
view Docker-level health check configuration and history.

OPTIONS:
  -c, --config FILE    Config file (default: axon.config.yml)
  --all                Check health for all environments
  -h, --help           Show this help

EXAMPLES:
  axon health --all              # All environments
  axon health production         # Specific environment
EOF
            ;;
        config)
            cat <<EOF
Usage: axon config <subcommand> [options]

Manage AXON configuration files.

SUBCOMMANDS:
  init                 Generate axon.config.yml file
  validate             Validate configuration file

GLOBAL OPTIONS:
  -c, --config FILE    Config file (default: axon.config.yml)
  -h, --help           Show help
  -v, --verbose        Verbose output

EXAMPLES:
  # Generate config from example
  axon config init

  # Interactive configuration
  axon config init --interactive

  # Generate with custom filename
  axon config init --file my-config.yml

  # Validate config
  axon config validate

  # Validate with strict mode
  axon config validate --strict

For subcommand-specific help:
  axon config <subcommand> --help
EOF
            ;;
        env)
            cat <<EOF
Usage: axon env <subcommand> [environment] [options]

Manage environment files (.env files) on Application Server.

SUBCOMMANDS:
  edit <environment>       Edit environment file for specified environment

OPTIONS:
  -c, --config FILE        Config file (default: axon.config.yml)
  --editor EDITOR          Editor to use (default: \$EDITOR or vim)
  -h, --help               Show this help message

EXAMPLES:
  # Edit production environment file
  axon env edit production

  # Edit staging with custom editor
  axon env edit staging --editor nano

  # Edit with custom config file
  axon env edit production -c custom.yml

NOTES:
  - Edits .env file directly on Application Server via SSH
  - Uses \$EDITOR environment variable, falls back to \$VISUAL, then vim
  - Requires SSH access to Application Server configured in axon.config.yml
  - Environment must be defined in config file with env_path set

For subcommand-specific help:
  axon env <subcommand> --help
EOF
            ;;
        context)
            cat <<EOF
Usage: axon context <command> [options]

Manage global contexts for deploying multiple projects from anywhere.

A context stores the config file location and project root, allowing you to
use AXON commands without being in the project directory.

COMMANDS:
  add <name> [config]      Add a new context
                           - Auto-detects config in current directory if not specified
                           - Example: axon context add my-app
                           - Example: axon context add my-app ~/path/to/config.yml

  use <name>               Switch to a context (deploy from anywhere)
                           - Example: axon context use my-app
                           - After switching, you can run commands from any directory

  list                     List all contexts with details
                           - Shows current active context with * marker
                           - Example: axon context list

  current                  Show details of current active context
                           - Example: axon context current

  remove <name>            Remove a context
                           - Example: axon context remove my-app
                           - Example: axon context remove my-app --force

OPTIONS:
  -h, --help               Show this help
  -f, --force              Force removal without confirmation (remove only)

EXAMPLES:
  # Add context from current directory
  cd ~/projects/my-app
  axon context add my-app

  # Add context with explicit path
  axon context add backend ~/projects/backend/axon.config.yml

  # Switch to context and deploy from anywhere
  axon context use my-app
  cd ~
  axon deploy production    # Deploys my-app!

  # List all contexts
  axon context list

  # Check current context
  axon context current

  # Remove context
  axon context remove my-app

PRECEDENCE (how AXON finds config):
  1. Explicit -c flag       (highest priority)
  2. Local axon.config.yml  (in current directory)
  3. Active context         (from 'axon context use')
  4. Error                  (no config found)

NOTES:
  - Contexts are stored in ~/.axon/contexts/
  - Local config always takes precedence over context
  - Use -c flag to override everything
  - Context references the config file (doesn't copy it)
  - Single source of truth: edit config in project, changes apply immediately
EOF
            ;;
        install)
            cat <<EOF
Usage: axon install [server] [options]

Install AXON on servers or local machine. If no server is specified, installs on all servers.

SERVERS:
  (none)             Install on all servers (local + app-server + system-server)
  local              Install tools on local machine only
  app-server         Install Docker and tools on Application Server only
  system-server      Install nginx and setup on System Server only

OPTIONS:
  -c, --config FILE    Config file (default: axon.config.yml)
  --auto-install       Automatically install missing tools (local only)
  -h, --help           Show this help

EXAMPLES:
  # Install on all servers
  axon install

  # Check what tools are missing on local machine
  axon install local

  # Auto-install all missing tools on local machine
  axon install local --auto-install

  # Install on Application Server using config
  axon install app-server --config axon.config.yml

  # Install on System Server (nginx, upstreams)
  axon install system-server

NOTES:
  - 'local' runs on your machine
  - 'app-server' and 'system-server' connect via SSH using config
  - Requires sudo permissions on remote servers
  - Installing 'all' runs: local → app-server → system-server
EOF
            ;;
        uninstall)
            cat <<EOF
Usage: axon uninstall [server] [options]

Uninstall AXON from servers or local machine. If no server is specified, uninstalls from all servers.

SERVERS:
  (none)             Uninstall from all servers (local + app-server + system-server)
  local              Remove AXON tools from local machine only
  app-server         Remove AXON setup from Application Server only
  system-server      Remove AXON nginx configs from System Server only

OPTIONS:
  -c, --config FILE    Config file (default: axon.config.yml)
  -f, --force          Skip confirmation prompts
  -h, --help           Show this help

EXAMPLES:
  # Uninstall from all servers
  axon uninstall

  # Uninstall from local machine only
  axon uninstall local

  # Uninstall from Application Server
  axon uninstall app-server --config axon.config.yml

  # Uninstall from System Server with force
  axon uninstall system-server --force

NOTES:
  - Uninstalls will prompt for confirmation unless --force is used
  - 'local' removes AXON-installed tools (careful with shared tools)
  - 'app-server' removes deployment artifacts and AXON directories
  - 'system-server' removes nginx configs and AXON directories
  - Uninstalling 'all' runs: system-server → app-server → local
EOF
            ;;
        *)
            echo "Error: Unknown command: $cmd"
            echo "Run 'axon --help' for usage information"
            return 1
            ;;
    esac
}

# Validate command
validate_command() {
    local cmd=$1

    # Check if command exists in the list
    if echo "$AXON_VALID_COMMANDS" | grep -qw "$cmd"; then
        return 0
    else
        return 1
    fi
}

# Check if command requires environment argument
command_requires_env() {
    local cmd=$1

    # Check if command is in the env-required list
    if echo "$AXON_ENV_REQUIRED_COMMANDS" | grep -qw "$cmd"; then
        return 0
    else
        return 1
    fi
}

# Parse global options and return remaining args
# This function should be called before command-specific parsing
parse_global_options() {
    local -n _global_config=$1
    local -n _global_verbose=$2
    local -n _global_dry_run=$3
    shift 3

    # Defaults
    _global_config="axon.config.yml"
    _global_verbose=false
    _global_dry_run=false

    local remaining_args=()

    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|--config)
                _global_config="$2"
                shift 2
                ;;
            -v|--verbose)
                _global_verbose=true
                shift
                ;;
            --dry-run)
                _global_dry_run=true
                shift
                ;;
            *)
                remaining_args+=("$1")
                shift
                ;;
        esac
    done

    # Return remaining args
    printf '%s\n' "${remaining_args[@]}"
}
