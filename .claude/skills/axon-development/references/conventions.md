# AXON Conventions & Script Anatomy

> Source: `axon`, `lib/command-parser.sh`, `cmd/*.sh` in the AXON repo.

## Contents
- [Dispatch model](#dispatch-model)
- [Adding a subcommand](#adding-a-subcommand)
- [cmd script anatomy](#cmd-script-anatomy)
- [Output & control helpers](#output--control-helpers)
- [Config access](#config-access)
- [SSH](#ssh)
- [Bash 3.2 hard rules](#bash-32-hard-rules)
- [Anti-patterns](#anti-patterns)

## Dispatch model

The `axon` entry script parses global flags (`--context`, `-c|--config`, `-v|--verbose`), reads the subcommand from `$1`, validates it against a registry, then dispatches to a `cmd_<name>()` function defined inside `axon`. That function builds an argv array and shells out to `cmd/<name>.sh` via the `execute` helper.

Registry lives in `lib/command-parser.sh`:

```bash
AXON_VALID_COMMANDS="build push deploy run build-and-push status logs restart sync health install uninstall delete config context env"
AXON_ENV_REQUIRED_COMMANDS="build push deploy run build-and-push logs restart sync"
```

`install`/`uninstall`/`context`/`config`/`env` are handled specially in `axon` and may not have a 1:1 `cmd/` file. Most commands do.

## Adding a subcommand

Adding `axon foo <env>` requires **four** edits. Miss one and dispatch, help, or validation breaks silently.

1. **`lib/command-parser.sh`** — add `foo` to `AXON_VALID_COMMANDS`. If it needs an environment arg, also add it to `AXON_ENV_REQUIRED_COMMANDS`.
2. **`lib/command-parser.sh`** — add a `foo)` case in `show_command_help()` with a heredoc (`Usage:` / `OPTIONS:` / `EXAMPLES:` sections — match existing entries exactly).
3. **`cmd/foo.sh`** — new executable script (see [anatomy](#cmd-script-anatomy)).
4. **`axon`** — define `cmd_foo()` (build argv, call `validate_config_file`, `execute "\"$SCRIPT_DIR/cmd/foo.sh\" ${args[*]}"`) and add a `foo)` branch to the main dispatch `case` (around the other `cmd_*` calls).

`cmd_*()` template inside `axon` (mirrors `cmd_sync`):

```bash
cmd_foo() {
    verbose "Executing foo command for environment: $ENVIRONMENT"
    validate_config_file
    local foo_args=("--config" "$CONFIG_FILE" "$ENVIRONMENT")
    execute "\"$SCRIPT_DIR/cmd/foo.sh\" ${foo_args[*]}"
}
```

## cmd script anatomy

Every `cmd/*.sh` follows this skeleton (from `cmd/build.sh`):

```bash
#!/bin/bash
# One-line purpose
set -e

# Colors (copied verbatim per script — no central logger)
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PRODUCT_ROOT="${PROJECT_ROOT:-$PWD}"

CONFIG_FILE="${PRODUCT_ROOT}/axon.config.yml"
ENVIRONMENT=""

while [[ $# -gt 0 ]]; do
  case $1 in
    -c|--config) CONFIG_FILE="$2"; shift 2 ;;
    -h|--help) echo "Usage: $0 [OPTIONS] <environment>"; exit 0 ;;
    -*) echo -e "${RED}Error: Unknown option: $1${NC}"; exit 1 ;;
    *) ENVIRONMENT="$1"; shift ;;
  esac
done

# Make config absolute, then validate existence; load config.
[[ "$CONFIG_FILE" != /* ]] && CONFIG_FILE="${PRODUCT_ROOT}/${CONFIG_FILE}"
[ -f "$CONFIG_FILE" ] || { echo -e "${RED}Error: Config not found: $CONFIG_FILE${NC}"; exit 1; }

source "$MODULE_DIR/lib/config-parser.sh"
source "$MODULE_DIR/lib/defaults.sh"
# ... command logic
```

- `MODULE_DIR` = AXON install dir (where `lib/` lives). `PRODUCT_ROOT` = the user's project (where their config/Dockerfile live). Keep them distinct.
- Errors go to the user in `${RED}Error: ...${NC}`; success in `${GREEN}✓ ...${NC}`.

## Output & control helpers

Defined in `axon` (available to the router, not auto-inherited by `cmd/` scripts):

- `verbose "$msg"` — prints `[VERBOSE]` only when `VERBOSE=true`.
- `dry_run "$cmd"` — prints `[DRY-RUN] Would execute:` when `DRY_RUN=true`.
- `execute "$cmd"` — `dry_run`s then `eval`s the command unless `DRY_RUN`. This is how `cmd_*` shells out.
- `validate_config_file` / `make_config_absolute` — resolve and check `$CONFIG_FILE`.

`cmd/*.sh` scripts re-declare their own colors and do inline `echo -e`; they do not have `verbose`/`execute`.

## Config access

Source `lib/config-parser.sh` and `lib/defaults.sh`. Read values through the getters there (`yq`-backed with `grep` fallback). YAML values support `${VAR}` / `${VAR:-default}` env expansion. Never grep the YAML ad-hoc in a new script — use the helpers so the fallback path and expansion stay consistent. See [references/libraries.md](../references/libraries.md).

## SSH

Use the SSH helpers (`lib/ssh-batch.sh`, `lib/ssh-connection.sh`), not raw `ssh`. Batching sends multiple commands over one multiplexed connection with output markers, cutting latency on deploy. SSH key paths use tilde expansion (`${SSH_KEY/#\~/$HOME}`).

## Bash 3.2 hard rules

| Want | Banned (Bash 4+) | Use instead |
|---|---|---|
| Key/value map | `declare -A` | parse YAML per-key via getters; or parallel arrays |
| Replace substring | `${var//old/new}` | `sed 's/old/new/g'` |
| Lowercase | `${var,,}` | `tr '[:upper:]' '[:lower:]'` |
| Read file→array | `mapfile` / `readarray` | `while read -r` loop with `array+=("$line")` |
| Pass array by ref | `declare -n` | function params / echoed values |

Other constants: use `$()` not backticks; build arrays with `array+=("x")`; prefer `[ ... ]`/`(( ... ))` for tests.

## Anti-patterns

- **Adding `cmd/foo.sh` without registering it** — `axon foo` reports unknown command. All four edit points are mandatory.
- **Raw `ssh` calls in new code** — bypasses multiplexing/batching; slow and inconsistent. Use the helpers.
- **Hardcoding product/env values** — everything comes from `axon.config.yml`.
- **Bash 4 syntax** — works on the author's Linux, breaks on macOS Bash 3.2 users. Test under `/bin/bash`.
- **Swallowing errors** — `set -e` is the contract; don't `|| true` to hide failures.
