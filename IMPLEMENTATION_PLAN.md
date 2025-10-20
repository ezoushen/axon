# AXON Context Feature - Implementation Plan

## Overview

Add global context support to AXON, allowing users to manage multiple projects and deploy from anywhere without being in the project directory.

**Key Design Decisions:**
1. ✅ Context = config path + project_root
2. ✅ Internally `cd` to project_root when using context
3. ✅ Reference config files (single source of truth)
4. ✅ Git SHA detected from project_root
5. ✅ Simple context naming (alphanumeric, hyphens, underscores)

## Stage 1: Foundation - Context Storage & Basic Commands

**Goal**: Implement context storage and basic add/use/list commands

**Success Criteria**:
- [ ] Can add a context: `axon context add my-app`
- [ ] Can switch context: `axon context use my-app`
- [ ] Can list contexts: `axon context list`
- [ ] Context persists between sessions
- [ ] All tests pass

### 1.1 Create Context Storage Structure

**Files to create:**
```
~/.axon/
├── config                    # Global settings (YAML)
└── contexts/
    └── *.yml                 # Individual context files
```

**Global config format** (`~/.axon/config`):
```yaml
# Version for future migration compatibility
version: 1

# Currently active context (empty = use local)
current_context: ""

# Global settings (for future use)
settings:
  auto_validate: true
  verbose_by_default: false
```

**Context file format** (`~/.axon/contexts/<name>.yml`):
```yaml
# Context metadata
name: linebot
description: "LINE bot application"
created: "2025-10-20T14:30:00Z"
last_used: "2025-10-20T15:45:00Z"

# Required: Where is the config file?
config: /Users/ezou/projects/linebot-nextjs/axon.config.yml

# Required: What is the project root? (for Dockerfile, .git, etc.)
project_root: /Users/ezou/projects/linebot-nextjs

# Optional: Cached product info (for display, refreshed on use)
product_name: linebot-nextjs
registry_provider: aws_ecr
```

**Implementation:**
- Create `lib/context-manager.sh` for all context operations
- Create `~/.axon/` directory on first use
- Initialize `~/.axon/config` with defaults if missing

### 1.2 Implement Context Manager Library

**New file:** `lib/context-manager.sh`

**Functions to implement:**
```bash
# Initialization
init_context_storage()           # Create ~/.axon/ structure

# Context CRUD
context_exists()                 # Check if context exists
get_context_file()               # Get path to context YAML
load_context()                   # Load context by name, return config path + project_root
save_context()                   # Save/update context
delete_context()                 # Remove context
list_contexts()                  # List all contexts with metadata

# Active context management
get_current_context()            # Get active context name
set_current_context()            # Set active context
clear_current_context()          # Clear active context (use local)

# Context resolution
resolve_config()                 # Apply precedence logic, return config path + project_root
```

### 1.3 Implement Context Commands

**New file:** `tools/context.sh`

**Commands to implement:**

#### `axon context add <name> [config_file]`
```bash
# Usage:
axon context add my-app                      # Auto-detect in CWD
axon context add my-app ~/path/to/config.yml # Explicit path

# Logic:
1. Validate name (alphanumeric, hyphens, underscores only)
2. Check if context already exists (error if yes)
3. If config_file not provided:
   - Look for axon.config.yml in CWD
   - Error if not found
4. Resolve config_file to absolute path
5. Set project_root = dirname(config_file)
6. Validate config file exists and is readable
7. Parse config to get product_name, registry_provider (for display)
8. Create context file in ~/.axon/contexts/<name>.yml
9. Display success message
```

#### `axon context use <name>`
```bash
# Usage:
axon context use my-app

# Logic:
1. Verify context exists
2. Verify config file still exists (warn if not)
3. Update last_used timestamp in context file
4. Set current_context in ~/.axon/config
5. Display confirmation with context details
```

#### `axon context list`
```bash
# Usage:
axon context list

# Output format:
NAME        PRODUCT             PROJECT ROOT                          LAST USED
────────────────────────────────────────────────────────────────────────────────
* linebot   linebot-nextjs      ~/projects/linebot-nextjs            2 hours ago
  backend   backend-api         ~/projects/backend-api               yesterday

(* = currently active)
Use 'axon context use <name>' to switch contexts

# Logic:
1. List all .yml files in ~/.axon/contexts/
2. Parse each context file
3. Check which is active from ~/.axon/config
4. Format table with alignment
5. Convert timestamps to relative time ("2 hours ago")
6. Expand ~ for home directory in paths
```

#### `axon context current`
```bash
# Usage:
axon context current

# Output:
Current context: linebot
Config:       /Users/ezou/projects/linebot-nextjs/axon.config.yml
Project Root: /Users/ezou/projects/linebot-nextjs
Product:      linebot-nextjs
Last Used:    2 hours ago

# If no context active:
No context active (using local mode)

# Logic:
1. Get current_context from ~/.axon/config
2. If empty, show "No context active"
3. Otherwise, load context and display details
```

#### `axon context remove <name>`
```bash
# Usage:
axon context remove my-app

# Logic:
1. Verify context exists
2. If it's the active context, clear current_context in ~/.axon/config
3. Delete ~/.axon/contexts/<name>.yml
4. Display confirmation
```

### 1.4 Modify Main CLI to Support Context Resolution

**File to modify:** `axon`

**Changes needed:**

1. **Add context resolution before command dispatch:**
```bash
# After parsing command line args, before dispatching to tools

# Resolve config file using precedence logic
resolve_config_and_context() {
    # Precedence (highest to lowest):
    # 1. Explicit -c flag
    if [ -n "$CONFIG_FILE_EXPLICIT" ]; then
        CONFIG_FILE="$CONFIG_FILE_EXPLICIT"
        CONTEXT_MODE="explicit"
        PROJECT_ROOT="$PWD"
        return
    fi

    # 2. Local axon.config.yml exists in CWD
    if [ -f "$PWD/axon.config.yml" ]; then
        CONFIG_FILE="$PWD/axon.config.yml"
        CONTEXT_MODE="local"
        PROJECT_ROOT="$PWD"
        return
    fi

    # 3. Active context
    local current_context=$(get_current_context)
    if [ -n "$current_context" ]; then
        local context_data=$(load_context "$current_context")
        CONFIG_FILE=$(echo "$context_data" | grep "^config:" | cut -d' ' -f2-)
        PROJECT_ROOT=$(echo "$context_data" | grep "^project_root:" | cut -d' ' -f2-)
        CONTEXT_MODE="context:$current_context"

        # Validate config still exists
        if [ ! -f "$CONFIG_FILE" ]; then
            echo "Error: Config file not found: $CONFIG_FILE"
            echo "Context '$current_context' may be outdated."
            echo "Use 'axon context remove $current_context' to remove it."
            exit 1
        fi

        # cd to project root (Option A from design decision)
        cd "$PROJECT_ROOT" || {
            echo "Error: Cannot access project root: $PROJECT_ROOT"
            exit 1
        }
        return
    fi

    # 4. Default: Look for axon.config.yml in CWD
    if [ -f "$PWD/axon.config.yml" ]; then
        CONFIG_FILE="$PWD/axon.config.yml"
        CONTEXT_MODE="local"
        PROJECT_ROOT="$PWD"
    else
        echo "Error: No config file found and no active context"
        echo ""
        echo "Options:"
        echo "  1. Create config in current directory: axon init-config"
        echo "  2. Use existing context: axon context use <name>"
        echo "  3. Add new context: axon context add <name>"
        exit 1
    fi
}

# Export for child scripts
export CONFIG_FILE
export PROJECT_ROOT
export CONTEXT_MODE
```

2. **Update help text to show context commands**

3. **Add context subcommand routing:**
```bash
case $COMMAND in
    context)
        # Route to context management
        source "$MODULE_DIR/tools/context.sh"
        handle_context_command "$@"
        ;;
    # ... existing commands
esac
```

### 1.5 Update Existing Tools

**Files to check/modify:**
- `tools/build.sh` - Should use $PROJECT_ROOT for git operations, Dockerfile
- `tools/deploy.sh` - Should work from $PROJECT_ROOT
- `tools/push.sh` - Should work from $PROJECT_ROOT

**Key change pattern:**
```bash
# OLD:
PRODUCT_ROOT="$PWD"

# NEW:
PRODUCT_ROOT="${PROJECT_ROOT:-$PWD}"  # Use PROJECT_ROOT if set, else CWD
```

### 1.6 Testing Plan

**Test cases:**
1. ✅ Add context from project directory
2. ✅ Add context with explicit path
3. ✅ Use context and deploy from home directory
4. ✅ Local config overrides context
5. ✅ Explicit -c flag overrides everything
6. ✅ Remove context that's currently active
7. ✅ Context with non-existent config file
8. ✅ List contexts shows correct active marker
9. ✅ Git SHA detected from project_root (not CWD)
10. ✅ All existing commands work without contexts (backward compat)

---

## Stage 2: Enhanced Context Operations

**Goal**: Better context management and debugging

**Success Criteria**:
- [ ] Can show detailed context info
- [ ] Can validate context configuration
- [ ] Auto-detection works correctly
- [ ] All tests pass

### 2.1 Implement `axon context show <name>`

**Output:**
```
Context: linebot
─────────────────────────────
Config:       /Users/ezou/projects/linebot-nextjs/axon.config.yml
Project Root: /Users/ezou/projects/linebot-nextjs
Product:      linebot-nextjs
Registry:     aws_ecr (948190058961.dkr.ecr.ap-northeast-1.amazonaws.com)
Environments: production, staging

Servers:
  System:      ubuntu@13.231.123.45
  Application: ubuntu@10.0.1.100

Created:      2025-10-15 09:30:00
Last Used:    2 hours ago (2025-10-20 13:45:00)

Status:       ✓ Valid (config exists and is readable)
```

**Logic:**
1. Load context
2. Verify config exists
3. Parse config to extract key info (product, registry, environments, servers)
4. Format and display

### 2.2 Implement `axon context validate <name>`

**Logic:**
```bash
# Checks performed:
1. Context file exists
2. Config file exists
3. Config is valid YAML
4. Required fields present (product.name, registry.provider, servers.*)
5. Project root directory exists
6. SSH keys exist and are readable
7. Dockerfile exists in project root (warning only)

# Exit code:
0 = valid
1 = invalid (errors found)
2 = warnings only
```

**Output:**
```
Validating context: linebot

✓ Context file exists
✓ Config file exists: axon.config.yml
✓ Config is valid YAML
✓ Required fields present
✓ Project root exists
✓ SSH keys exist
⚠ Warning: Dockerfile not found in project root

Validation: Passed with warnings
```

### 2.3 Enhance `axon context add` with Auto-detection

**Auto-detection logic:**
1. Look for `axon.config.yml` in CWD
2. If found, extract product name
3. Suggest using product name as context name
4. If git repo, suggest using repo name

**Example:**
```bash
cd ~/projects/linebot-nextjs
axon context add

# Interactive prompt:
Found config: axon.config.yml
Product: linebot-nextjs

Enter context name [linebot-nextjs]: ▊
# User presses Enter to accept, or types different name
```

### 2.4 Add Context Info to Command Output

**Modify tools to show active context:**

```bash
# In build.sh, deploy.sh, etc.
if [ -n "$CONTEXT_MODE" ] && [[ "$CONTEXT_MODE" == context:* ]]; then
    echo -e "${CYAN}Context: ${CONTEXT_MODE#context:}${NC}"
fi
```

**Example output:**
```
==================================================
AXON - Zero-Downtime Deployment
==================================================

Context: linebot
Running from: MacBook-Pro.local

Loading configuration...
```

---

## Stage 3: Advanced Features

**Goal**: Power user features and team collaboration

**Success Criteria**:
- [ ] One-off context override works
- [ ] Context export/import works
- [ ] Better error messages with hints
- [ ] All tests pass

### 3.1 Implement `axon --context <name>` Flag

**Usage:**
```bash
# One-off command without switching context
axon --context backend status production
axon --context frontend deploy staging
```

**Implementation:**
- Add `--context` flag parsing in main axon script
- Set temporary context for single command
- Don't update last_used or current_context

### 3.2 Implement Context Export/Import

#### Export
```bash
axon context export linebot > linebot-context.yml

# Output (sanitized paths):
name: linebot
description: "LINE bot application"
config_relative: ./axon.config.yml
project_root_relative: .
# Absolute paths removed for portability
```

#### Import
```bash
axon context import linebot-context.yml --name my-linebot --root ~/my-projects/linebot

# Logic:
1. Read exported context
2. Resolve relative paths to absolute using --root
3. Create new context
```

### 3.3 Enhanced Error Messages

**Context-aware hints:**

```bash
# No config found
Error: No config file found and no active context

Did you mean to:
  - Work with an existing context? axon context list
  - Create a new context? axon context add <name>
  - Create config in this directory? axon init-config

# Context config missing
Error: Config file not found: /Users/ezou/projects/old-path/axon.config.yml
Context 'linebot' may be outdated (project moved or deleted)

To fix:
  - Update context: axon context add linebot ~/new-path/axon.config.yml
  - Remove context: axon context remove linebot
  - Switch to different context: axon context use <name>
```

---

## Implementation Checklist

### Stage 1: Foundation
- [ ] Create `lib/context-manager.sh`
- [ ] Create `tools/context.sh`
- [ ] Implement context storage initialization
- [ ] Implement `axon context add`
- [ ] Implement `axon context use`
- [ ] Implement `axon context list`
- [ ] Implement `axon context current`
- [ ] Implement `axon context remove`
- [ ] Modify main `axon` script for context resolution
- [ ] Update existing tools to use PROJECT_ROOT
- [ ] Write tests for Stage 1

### Stage 2: Enhanced Operations
- [ ] Implement `axon context show`
- [ ] Implement `axon context validate`
- [ ] Add auto-detection to `axon context add`
- [ ] Add context info to command outputs
- [ ] Write tests for Stage 2

### Stage 3: Advanced Features
- [ ] Implement `--context` flag
- [ ] Implement `axon context export`
- [ ] Implement `axon context import`
- [ ] Enhanced error messages
- [ ] Write tests for Stage 3

### Documentation
- [ ] Update README.md with context feature
- [ ] Add CONTEXT.md with detailed guide
- [ ] Update CHANGELOG.md
- [ ] Add examples to docs/

---

## Breaking Changes

**None!** This feature is fully backward compatible:
- Existing workflows without contexts continue to work
- `-c` flag behavior unchanged
- Local `axon.config.yml` still works as before

---

## Testing Strategy

### Unit Tests (per function)
```bash
# test-context-manager.sh
test_init_context_storage
test_save_and_load_context
test_get_current_context
test_resolve_config_precedence

# test-context-commands.sh
test_context_add
test_context_use
test_context_list
test_context_remove
```

### Integration Tests (end-to-end)
```bash
# test-context-integration.sh
test_deploy_with_context_from_home_dir
test_local_override_context
test_explicit_flag_override_context
test_context_switch_and_deploy
test_git_sha_from_project_root
```

### Manual Testing Checklist
```bash
# Setup
[ ] Add 3 different contexts
[ ] Switch between contexts
[ ] Deploy from home directory using context

# Edge cases
[ ] Remove active context
[ ] Use context with moved config file
[ ] Add context in directory without config
[ ] Use -c flag to override context
[ ] Deploy in project directory with active context (local wins)

# Backward compatibility
[ ] Run all commands without setting up contexts
[ ] Verify existing scripts/workflows unaffected
```

---

## Future Enhancements (Not in Initial Implementation)

- Context aliases: `axon context alias prod production`
- Context groups: `axon context group frontend app1 app2 app3`
- Context hooks: Run scripts on context switch
- Context variables: Per-context environment variables
- Remote contexts: Sync contexts across team via git
- Context templates: Create contexts from templates
- Shell integration: Show active context in prompt

---

## Notes

- Keep implementation simple in Stage 1 - get core working first
- Stage 2 and 3 can be deferred based on user feedback
- All stages maintain backward compatibility
- Use existing yq for YAML operations
- Follow Bash 3.2 compatibility throughout
