#!/bin/bash
# AXON Command Parser Library
# Provides command parsing and help system for axon CLI

# Command registry - list of valid commands
AXON_VALID_COMMANDS="build push deploy run build-and-push status logs restart health validate setup init-config"

# Commands that require environment argument
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
  status [env]             Show container status for all or specific environment
  logs <env>               View container logs
  restart <env>            Restart container
  health [env]             Check container health status
  validate                 Validate configuration file
  init-config              Generate axon.config.yml file

SETUP COMMANDS:
  setup local              Setup local machine (install required tools)
  setup app-server         Setup Application Server (Docker, AWS CLI, etc.)
  setup system-server      Setup System Server (nginx, upstreams)

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
  axon validate --strict
  axon init-config
  axon init-config --interactive
  axon setup local --auto-install
  axon setup app-server
  axon setup system-server

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
Usage: axon status [environment] [options]

Show container status for all environments or a specific environment.

Display modes (can be combined):
  --detailed, --inspect     Show comprehensive container information
  --configuration, --env    Show configuration (env vars, volumes, ports)
  --health                  Show health check status and history

OPTIONS:
  -c, --config FILE    Config file (default: axon.config.yml)
  -h, --help           Show this help

EXAMPLES:
  axon status                       # Summary of all environments
  axon status production            # Summary of specific environment
  axon status production --detailed # Detailed information
  axon status staging --health      # Health check status
  axon status --configuration       # Configuration for all environments
  axon status production --detailed --health  # Combined views
EOF
            ;;
        logs)
            cat <<EOF
Usage: axon logs <environment> [options]

View container logs for specified environment.

OPTIONS:
  -c, --config FILE      Config file (default: axon.config.yml)
  -f, --follow           Follow log output in real-time
  -n, --lines <number>   Number of lines to show (default: from script)
  --since <time>         Show logs since timestamp
  -h, --help             Show this help

EXAMPLES:
  axon logs production
  axon logs staging --follow
  axon logs production --lines 100
  axon logs staging --since "2024-01-01"
EOF
            ;;
        restart)
            cat <<EOF
Usage: axon restart <environment> [options]

Restart container for specified environment.

OPTIONS:
  -c, --config FILE    Config file (default: axon.config.yml)
  -h, --help           Show this help

EXAMPLES:
  axon restart production
  axon restart staging --config custom.yml
EOF
            ;;
        health)
            cat <<EOF
Usage: axon health [environment] [options]

Check container health status for all environments or a specific environment.

OPTIONS:
  -c, --config FILE    Config file (default: axon.config.yml)
  -h, --help           Show this help

EXAMPLES:
  axon health                    # All environments
  axon health production         # Specific environment
EOF
            ;;
        validate)
            cat <<EOF
Usage: axon validate [options]

Validate AXON configuration file for correctness and completeness.

OPTIONS:
  -c, --config FILE    Config file to validate (default: axon.config.yml)
  --strict             Treat warnings as errors
  -h, --help           Show this help

EXAMPLES:
  axon validate
  axon validate --config custom.yml
  axon validate --strict
EOF
            ;;
        init-config)
            cat <<EOF
Usage: axon init-config [options]

Generate axon.config.yml configuration file for your product.

OPTIONS:
  -f, --file FILE      Output file name (default: axon.config.yml)
  -i, --interactive    Interactive mode - configure field by field
  -h, --help           Show this help

EXAMPLES:
  # Generate config from example (quick start)
  axon init-config

  # Interactive configuration (step-by-step)
  axon init-config --interactive

  # Generate with custom filename
  axon init-config --file my-config.yml

  # Interactive with custom filename
  axon init-config --interactive --file production.yml

MODES:
  Default Mode:
    - Copies config.example.yml to axon.config.yml
    - Quick setup with placeholder values
    - You edit the file manually afterward

  Interactive Mode (--interactive):
    - Walks through each configuration field
    - Prompts for values with descriptions
    - Validates input as you go
    - Generates ready-to-use configuration

NOTES:
  - Generated file is automatically added to .gitignore
  - Contains server IPs and secrets - keep it private
  - Use 'axon validate' after editing to check correctness
EOF
            ;;
        setup)
            cat <<EOF
Usage: axon setup <target> [options]

Setup and configure servers or local machine for AXON deployment.

TARGETS:
  local              Setup local machine (install required tools)
  app-server         Setup Application Server (Docker, AWS CLI, etc.)
  system-server      Setup System Server (nginx, upstreams)

OPTIONS:
  -c, --config FILE    Config file (default: axon.config.yml)
  --auto-install       Automatically install missing tools (local only)
  -h, --help           Show this help

EXAMPLES:
  # Check what tools are missing on local machine
  axon setup local

  # Auto-install all missing tools on local machine
  axon setup local --auto-install

  # Setup Application Server using config
  axon setup app-server --config axon.config.yml

  # Setup System Server (nginx, upstreams)
  axon setup system-server

NOTES:
  - 'local' runs on your machine
  - 'app-server' and 'system-server' connect via SSH using config
  - Requires sudo permissions on remote servers
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
