---
name: "axon:update"
description: Update an installed AXON CLI to the latest (or a pinned) version — detect the install method, upgrade, and verify
args: "[--version <tag>] [--check]"
---

Update the user's installed **AXON** CLI. There is no `axon self-update` subcommand — the upgrade path depends on how AXON was installed. Detect the method, then run the matching upgrade.

## Steps

1. **Record current version.** Run `axon --version`. If `axon` is not found, this is a fresh install — route to `/axon:install` instead.

2. **Detect install method:**
   - **Homebrew** — `brew list axon` succeeds (`command -v brew && brew list axon &>/dev/null`).
   - **Git/curl install** — `~/.axon` (or `$AXON_DIR`) is a git repo: `git -C "${AXON_DIR:-$HOME/.axon}" rev-parse --git-dir`.
   - Resolve the real install dir from the symlink if unsure: `readlink -f "$(command -v axon)"` → its parent is the repo.

3. **`--check` only:** report current vs latest without upgrading. Latest tag:
   ```bash
   git ls-remote --tags --sort=-v:refname https://github.com/ezoushen/axon.git | head -1
   ```
   Compare to `axon --version`; tell the user if an update is available, then stop.

4. **Upgrade by method:**

   **Homebrew:**
   ```bash
   brew update && brew upgrade axon
   ```

   **Git/curl install** (default: latest on `main`):
   ```bash
   git -C "${AXON_DIR:-$HOME/.axon}" pull --ff-only origin main
   ```
   - Pin a version with `--version <tag>` → fetch and checkout that tag instead:
     ```bash
     git -C "${AXON_DIR:-$HOME/.axon}" fetch --tags origin
     git -C "${AXON_DIR:-$HOME/.axon}" checkout "<tag>"
     ```
   - Equivalent one-liner that also re-links: re-run the installer (honors `AXON_BRANCH=<tag>`):
     ```bash
     AXON_BRANCH="<tag-or-main>" bash -c "$(curl -fsSL https://raw.githubusercontent.com/ezoushen/axon/main/install.sh)"
     ```
   - If `pull --ff-only` fails (local edits / detached at a tag), tell the user — do not force-reset their `~/.axon`. Offer the installer re-run or a manual `git checkout`.

5. **Refresh shell hash** if the binary moved: `hash -r`.

6. **Verify.** Run `axon --version` again and confirm it changed (or matches the requested `--version`). Report old → new.

## Rules

- Confirm before upgrading if the user is mid-deployment or on production tooling.
- Never `git reset --hard` or discard changes in `~/.axon` without explicit consent — the user may have local modifications.
- After a major-version bump, suggest `axon config validate` in case the schema changed.
