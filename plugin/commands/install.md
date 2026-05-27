---
name: "axon:install"
description: Install the AXON deployment CLI on this machine (Homebrew or curl), then verify
args: "[--method brew|curl|manual] [--version <tag>]"
---

Install the **AXON** zero-downtime deployment CLI for the user. Be safe and confirm before any command that needs `sudo` or writes outside `$HOME`.

## Steps

1. **Check if already installed.** Run `command -v axon && axon --version`. If present, report the version and ask whether to reinstall/upgrade before continuing.

2. **Pick a method.** Honor `--method` if the user passed it. Otherwise:
   - If `brew` is available (`command -v brew`) → prefer **Homebrew**.
   - Else → use the **curl** installer.
   - Use **manual** only if the user asks or the others fail.

3. **Run the chosen install:**

   **Homebrew** (preferred when available):
   ```bash
   brew tap ezoushen/axon
   brew install axon
   ```

   **curl** (clones to `~/.axon`, symlinks into `/usr/local/bin` — the symlink step may prompt for `sudo`; warn the user first):
   ```bash
   curl -fsSL https://raw.githubusercontent.com/ezoushen/axon/main/install.sh | bash
   ```
   Override targets with env vars if the user wants no `sudo`: `INSTALL_DIR="$HOME/.local/bin" AXON_DIR="$HOME/.axon"`. A specific version maps to `AXON_BRANCH=<tag>`.

   **Manual:**
   ```bash
   git clone https://github.com/ezoushen/axon.git ~/.axon
   sudo ln -sf ~/.axon/axon /usr/local/bin/axon
   ```

4. **Verify.** Run `axon --version`. If `axon` is not found, check the install dir is on `PATH` (e.g. `/usr/local/bin` or the chosen `INSTALL_DIR`) and tell the user how to fix it.

5. **Next steps.** Point the user at prerequisites and setup:
   ```bash
   axon install local --auto-install   # install local prerequisites (yq, docker, etc.)
   axon config init --interactive       # scaffold axon.config.yml
   ```

## Notes

- AXON requires Bash 3.2+, `yq`, `git`, `ssh`, `curl`, and (for Docker mode) `docker` + a registry CLI. `axon install local` reports what's missing.
- Do not pipe `install.sh` to `sudo bash`; the script self-elevates only for the symlink and prompts as needed.
- After installing, the `axon-development` skill in this plugin covers contributing to the AXON codebase.
