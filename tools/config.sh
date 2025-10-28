#!/bin/bash
# AXON Config Command Handler
# Handles config-related subcommands

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Show config command help
show_config_help() {
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
}

# Show init subcommand help
show_config_init_help() {
    cat <<EOF
Usage: axon config init [options]

Generate axon.config.yml configuration file for your product.

OPTIONS:
  -f, --file FILE      Output file name (default: axon.config.yml)
  -i, --interactive    Interactive mode - configure field by field
  -h, --help           Show this help

EXAMPLES:
  # Generate config from example (quick start)
  axon config init

  # Interactive configuration (step-by-step)
  axon config init --interactive

  # Generate with custom filename
  axon config init --file my-config.yml

  # Interactive with custom filename
  axon config init --interactive --file production.yml

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
  - Use 'axon config validate' after editing to check correctness
EOF
}

# Show validate subcommand help
show_config_validate_help() {
    cat <<EOF
Usage: axon config validate [options]

Validate AXON configuration file for correctness and completeness.

OPTIONS:
  -c, --config FILE    Config file to validate (default: axon.config.yml)
  --strict             Treat warnings as errors
  -h, --help           Show this help

EXAMPLES:
  axon config validate
  axon config validate --config custom.yml
  axon config validate --strict
EOF
}

# Handle config command and subcommands
handle_config_command() {
    # Check if subcommand is provided
    if [ $# -eq 0 ]; then
        show_config_help
        exit 1
    fi

    # Get subcommand
    local subcommand="$1"
    shift

    # Check for subcommand help
    if [ "$subcommand" = "--help" ] || [ "$subcommand" = "-h" ]; then
        show_config_help
        exit 0
    fi

    case "$subcommand" in
        init)
            # Parse options for init subcommand
            INTERACTIVE=false
            OUTPUT_FILE=""

            # Check for help
            if [ $# -gt 0 ] && ([ "$1" = "--help" ] || [ "$1" = "-h" ]); then
                show_config_init_help
                exit 0
            fi

            # Parse arguments
            while [[ $# -gt 0 ]]; do
                case $1 in
                    -i|--interactive)
                        INTERACTIVE=true
                        shift
                        ;;
                    -f|--file)
                        OUTPUT_FILE="$2"
                        shift 2
                        ;;
                    -h|--help)
                        show_config_init_help
                        exit 0
                        ;;
                    *)
                        echo -e "${RED}Error: Unknown option: $1${NC}"
                        echo "Run 'axon config init --help' for usage information"
                        exit 1
                        ;;
                esac
            done

            # Call init-config.sh
            local init_args=()
            if [ -n "$OUTPUT_FILE" ]; then
                init_args+=("--file" "$OUTPUT_FILE")
            fi
            if [ "$INTERACTIVE" = true ]; then
                init_args+=("--interactive")
            fi

            "$SCRIPT_DIR/tools/init-config.sh" "${init_args[@]}"
            ;;

        validate)
            # Parse options for validate subcommand
            # Inherit CONFIG_FILE from parent if set, otherwise use default
            if [ -z "$CONFIG_FILE" ]; then
                CONFIG_FILE="axon.config.yml"
            fi
            STRICT=false

            # Check for help
            if [ $# -gt 0 ] && ([ "$1" = "--help" ] || [ "$1" = "-h" ]); then
                show_config_validate_help
                exit 0
            fi

            # Parse arguments
            while [[ $# -gt 0 ]]; do
                case $1 in
                    -c|--config)
                        CONFIG_FILE="$2"
                        shift 2
                        ;;
                    --strict)
                        STRICT=true
                        shift
                        ;;
                    -h|--help)
                        show_config_validate_help
                        exit 0
                        ;;
                    *)
                        echo -e "${RED}Error: Unknown option: $1${NC}"
                        echo "Run 'axon config validate --help' for usage information"
                        exit 1
                        ;;
                esac
            done

            # Call validate-config.sh
            local validate_args=("--config" "$CONFIG_FILE")
            if [ "$STRICT" = true ]; then
                validate_args+=("--strict")
            fi

            "$SCRIPT_DIR/tools/validate-config.sh" "${validate_args[@]}"
            ;;

        *)
            echo -e "${RED}Error: Unknown subcommand: ${subcommand}${NC}"
            echo ""
            show_config_help
            exit 1
            ;;
    esac
}
