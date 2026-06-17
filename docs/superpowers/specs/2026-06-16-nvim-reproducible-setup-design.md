# Reproducible Neovim Setup — Design

**Date:** 2026-06-16
**Status:** Approved (pending spec review)

## Goal

Make a from-scratch Neovim reinstall a one-command operation that restores the
config **and** every LSP/formatter/linter automatically — no manual `:Mason`
work. Kill the recurring "15 minutes of setup" problem.

## Current State

- **Config** (`~/.config/nvim`) is a LazyVim setup: `init.lua`, `lua/config/*`,
  `lua/plugins/example.lua`, `lazyvim.json` (18 extras), `lazy-lock.json`
  (pinned plugin versions), `.neoconf.json`. It is **not version-controlled**
  and **not** in chezmoi (hypr/kitty are; nvim was never added).
- **Tools**: 34 Mason packages installed (LSPs, formatters, linters). Several
  (`rust-analyzer`, `bash-language-server`, `systemd-lsp`, `xcode-build-server`,
  `marksman`, ...) are not tied to an enabled extra, so a fresh install would
  **not** bring them back.
- **neolazy** (`~/src/neolazy`, GitHub `tkirkland/neolazy`): a polished
  bootstrap script that installs Neovim + system deps + GitHub-release tools,
  then **clones the vanilla LazyVim starter** and runs `+MasonUpdate` (refreshes
  the registry — does *not* install tools). So it does not reproduce this setup.
- **chezmoi** (`~/.local/share/chezmoi`) manages the other dotfiles.

## Design

Three parts.

### Part 1 — Tool list lives in the repo (single source of truth)

Add `lua/plugins/mason.lua` to the nvim config that extends LazyVim's existing
`mason.nvim` with an explicit `ensure_installed` list of all 34 current tools
(snapshotted from `~/.local/share/nvim/mason/packages`, whose directory names
are exactly the Mason registry names).

- This list is the **only** place tools are declared. The bootstrap script does
  not hardcode a second copy.
- Adding/removing a tool later = edit this one file.
- Listing tools that some extras would also install is harmless — `mason.nvim`
  merges and de-dupes `ensure_installed`.

### Part 2 — Config goes into chezmoi

Import `~/.config/nvim` into chezmoi as `dot_config/nvim`, alongside
`hypr`/`kitty`. Tracked files: `init.lua`, `lua/`, `lazyvim.json`,
`lazy-lock.json`, `.neoconf.json`, `.gitignore`, `LICENSE`. Once imported, the
nvim config (including `mason.lua`) rides up to the dotfiles repo with
everything else, and `chezmoi apply` lays it down on any machine.

### Part 3 — Bootstrap installs the binaries (modeled on neolazy's existing patterns)

Modify the neolazy script:

1. **Replace `install_starter`** (vanilla LazyVim clone) with reliance on the
   chezmoi-deployed config — the script no longer clones the starter; it expects
   `~/.config/nvim` to already be in place via `chezmoi apply`. The existing
   `backup_if_present "$HOME/.config/nvim"` step must be adjusted so it does
   **not** move the chezmoi-managed config aside (it may still back up
   `~/.local/share/nvim` / state / cache, which chezmoi does not manage).
2. **Add `install_mason_tools`**, modeled on the existing Tree-sitter `:wait`
   block: a headless nvim invocation that triggers Mason and **blocks until all
   `ensure_installed` tools finish installing** (a plain headless `+qa` quits
   before async installs complete). It reads the list from the config — no
   duplicate list in bash. Progress and results report through the existing
   `INSTALLED`/`SKIPPED` summary helpers.

### Automation — "chezmoi apply and go"

A chezmoi `run_once_after_` hook fires the neolazy bootstrap automatically on
first apply per machine (run_once is keyed by content hash, so it runs once).
The hook fetches/uses the neolazy repo and runs `neovim-lazy-setup.sh`.

End-to-end on a fresh machine:

```
install chezmoi  →  chezmoi apply
   → deploys ~/.config/nvim (incl. tool list) + other dotfiles
   → run_once hook runs neolazy bootstrap
        → installs Neovim + system deps + GitHub-release tools
        → headless nvim: Lazy sync (pinned), Tree-sitter parsers,
          Mason installs all 34 tools and waits
   → done: every LSP/formatter/linter present, zero manual steps
```

First apply will prompt for sudo (the bootstrap installs system packages); the
script already handles passwordless sudo gracefully.

## Out of Scope (rejected)

- **Vendoring the 449 MB Mason binary tree into the repo.** Rejected: huge repo,
  x86_64-linux-locked, and several tools are Python venvs with absolute paths
  (`/home/me/...`) baked into shebangs/`pyvenv.cfg` that break on a
  home-path or Python-minor-version change — i.e. fragile on the very reinstall
  this is meant to survive. The declarative approach re-downloads fresh, correct
  binaries instead.

## Acceptance Criteria

1. `lua/plugins/mason.lua` lists all 34 current tools.
2. `~/.config/nvim` is managed by chezmoi and present in the dotfiles repo.
3. The neolazy script deploys the real config (not the vanilla starter) and
   installs every tool in `ensure_installed`, blocking until complete.
4. On a clean machine, `chezmoi apply` (with the run_once hook) yields a working
   Neovim with all LSPs/formatters/linters, with no manual `:Mason` interaction.
5. The tool list exists in exactly one place (the nvim config).
