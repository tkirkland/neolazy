# Reproducible Neovim Setup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a from-scratch Neovim reinstall a one-command operation that restores the config and auto-installs all 34 Mason tools, with no manual `:Mason` steps.

**Architecture:** The full tool list lives in the nvim config (`lua/plugins/mason.lua`) as the single source of truth. The config is managed by chezmoi. The neolazy bootstrap script deploys that config and runs a headless nvim step that installs every declared Mason tool and blocks until done. A chezmoi `run_once` hook fires the bootstrap automatically on first apply.

**Tech Stack:** Bash, Neovim/LazyVim (Lua), Mason (`mason.nvim` + `mason-registry` API), chezmoi.

**Note on "tests":** This is shell + editor-config work, not unit-testable code. Each task's verification is a concrete command run against the *current* machine. Mason installs are idempotent (already-installed tools are skipped), so the install step is safe to run here as its own verification. The full fresh-machine path cannot be exercised without a clean VM — that limit is called out where relevant.

---

## File Structure

- **Create:** `~/.config/nvim/lua/plugins/mason.lua` — declares all 34 tools via `ensure_installed`.
- **Create (chezmoi source):** `~/.local/share/chezmoi/dot_config/nvim/...` — the imported config (chezmoi generates these from `chezmoi add`).
- **Create (chezmoi source):** `~/.local/share/chezmoi/run_once_after_50-neovim-bootstrap.sh` — auto-fire hook.
- **Modify:** `~/src/neolazy/neovim-lazy-setup.sh` — backup logic, starter→chezmoi, add Mason install step.

All git commits land in two existing repos: `~/.local/share/chezmoi` (config + hook) and `~/src/neolazy` (script + docs). Local commits only — **no `git push`** unless the user asks.

---

## Task 1: Declare all 34 Mason tools in the config

**Files:**
- Create: `~/.config/nvim/lua/plugins/mason.lua`

- [ ] **Step 1: Write the plugin file**

```lua
-- lua/plugins/mason.lua
-- Single source of truth for every Mason tool this config relies on.
-- Uses the extend pattern (vim.list_extend) so tools added by LazyVim extras
-- are preserved rather than overwritten. mason.nvim is keyed by the short name
-- "mason.nvim", so this merges with LazyVim's own mason spec.
return {
  {
    "mason-org/mason.nvim",
    opts = function(_, opts)
      opts.ensure_installed = opts.ensure_installed or {}
      vim.list_extend(opts.ensure_installed, {
        "bash-language-server",
        "beautysh",
        "black",
        "cmakelang",
        "cmakelint",
        "docker-compose-language-service",
        "editorconfig-checker",
        "gh",
        "jdtls",
        "jq",
        "json-lsp",
        "json-repair",
        "lua-language-server",
        "markdownlint-cli2",
        "markdown-toc",
        "marksman",
        "mdformat",
        "neocmakelsp",
        "prettier",
        "pylint",
        "pyright",
        "ruff",
        "rust-analyzer",
        "shellcheck",
        "shfmt",
        "sqlfluff",
        "sqlfmt",
        "stylua",
        "systemdlint",
        "systemd-lsp",
        "taplo",
        "xcode-build-server",
        "xmlformatter",
        "yaml-language-server",
      })
    end,
  },
}
```

- [ ] **Step 2: Verify the config still loads cleanly**

Run: `nvim --headless "+qa" 2>&1`
Expected: exits 0 with no Lua error output. (A syntax error in `mason.lua` would print a stack trace and a non-zero-ish error here.)

- [ ] **Step 3: Verify the merged list contains all 34 tools**

Run:
```bash
nvim --headless "+lua local t=LazyVim.opts('mason.nvim').ensure_installed; io.stdout:write(#t..' tools\n')" "+qa" 2>&1
```
Expected: prints a count `>= 34` (extras may push it higher; duplicates are fine — Mason de-dupes).

- [ ] **Step 4: Commit (after Task 2 imports it into chezmoi — see note)**

This file is committed as part of Task 2's chezmoi import, since chezmoi is where the config is version-controlled. No separate commit here.

---

## Task 2: Import the nvim config into chezmoi

**Files:**
- Create (chezmoi source): `~/.local/share/chezmoi/dot_config/nvim/...`

- [ ] **Step 1: Add the config to chezmoi**

Run: `chezmoi add ~/.config/nvim`
This recursively copies the config into chezmoi's source dir as `dot_config/nvim/`.

- [ ] **Step 2: Verify nvim is now managed and includes the tool list**

Run: `chezmoi managed | grep -E 'nvim/(lazy-lock.json|lazyvim.json|lua/plugins/mason.lua)$'`
Expected: all three paths listed.

- [ ] **Step 3: Verify there is no drift between source and target**

Run: `chezmoi diff -- ~/.config/nvim`
Expected: empty output (source matches what's on disk).

- [ ] **Step 4: Commit in the chezmoi repo**

```bash
git -C ~/.local/share/chezmoi add -A
git -C ~/.local/share/chezmoi commit -m "feat(nvim): manage neovim config + Mason tool list via chezmoi"
```
Expected: commit succeeds. Do NOT push.

---

## Task 3: Stop the bootstrap from clobbering the chezmoi-managed config

The script currently runs `backup_if_present "$HOME/.config/nvim"`, which would move the config chezmoi just placed. It also unconditionally backs up `~/.local/share/nvim` etc., which is destructive on a re-run. Make backups only happen on a genuine fresh install (no `nvim` binary yet), and never move the chezmoi-managed config dir.

**Files:**
- Modify: `~/src/neolazy/neovim-lazy-setup.sh` (the backup block, currently ~lines 190-194)

- [ ] **Step 1: Replace the backup block**

Find:
```bash
log "Checking for existing Neovim state..."
backup_if_present "$HOME/.config/nvim"
backup_if_present "$HOME/.local/share/nvim"
backup_if_present "$HOME/.local/state/nvim"
backup_if_present "$HOME/.cache/nvim"
```

Replace with:
```bash
# The config dir (~/.config/nvim) is owned by chezmoi now — never move it.
# Only back up Neovim's *data/state/cache* on a genuine fresh install (no nvim
# binary yet); on a re-run these are reused, and moving them would force a
# needless 600 MB+ re-download.
if ! have nvim; then
  log "Fresh install detected — backing up any stale Neovim data/state..."
  backup_if_present "$HOME/.local/share/nvim"
  backup_if_present "$HOME/.local/state/nvim"
  backup_if_present "$HOME/.cache/nvim"
else
  skip "nvim already installed — leaving existing config/data in place"
fi
```

- [ ] **Step 2: Verify the script still parses and lints**

Run: `bash -n ~/src/neolazy/neovim-lazy-setup.sh && shellcheck ~/src/neolazy/neovim-lazy-setup.sh`
Expected: `bash -n` silent (valid syntax); shellcheck reports no new errors (pre-existing warnings, if any, unchanged).

- [ ] **Step 3: Commit**

```bash
git -C ~/src/neolazy add neovim-lazy-setup.sh
git -C ~/src/neolazy commit -m "fix(bootstrap): don't move chezmoi-managed config; only back up data on fresh install"
```

---

## Task 4: Deploy the real config via chezmoi instead of cloning the vanilla starter

**Files:**
- Modify: `~/src/neolazy/neovim-lazy-setup.sh` (the `install_starter` function, ~lines 499-513, and its call site ~line 513)

- [ ] **Step 1: Replace the `install_starter` function**

Find the whole `install_starter() { ... }` function and replace it with:
```bash
# ---------- Deploy config from chezmoi --------------------------------------

# The Neovim config is owned by chezmoi (dot_config/nvim). Ensure it is applied
# so ~/.config/nvim exists before we sync plugins / install tools. If chezmoi
# isn't installed or initialized, fail loudly with guidance rather than silently
# falling back to a vanilla starter (which would not reproduce this setup).
deploy_config() {
  if [ -d "$HOME/.config/nvim" ] && [ -f "$HOME/.config/nvim/lua/plugins/mason.lua" ]; then
    skip "~/.config/nvim already present (mason.lua found)"
    note_skipped "nvim config (already deployed)"
    return 0
  fi

  if have chezmoi; then
    log "Applying Neovim config via chezmoi..."
    chezmoi apply --force "$HOME/.config/nvim"
  fi

  if [ ! -f "$HOME/.config/nvim/lua/plugins/mason.lua" ]; then
    err "Neovim config not found at ~/.config/nvim (expected it from chezmoi)."
    err "Run 'chezmoi init --apply <your-dotfiles-repo>' first, then re-run this script."
    exit 1
  fi
  ok "Neovim config deployed (~/.config/nvim)"
  note_installed "nvim config (chezmoi)"
}
```

- [ ] **Step 2: Update the call site**

Find: `install_starter`
Replace with: `deploy_config`

- [ ] **Step 3: Verify syntax and lint**

Run: `bash -n ~/src/neolazy/neovim-lazy-setup.sh && shellcheck ~/src/neolazy/neovim-lazy-setup.sh`
Expected: valid syntax, no new shellcheck errors.

- [ ] **Step 4: Commit**

```bash
git -C ~/src/neolazy add neovim-lazy-setup.sh
git -C ~/src/neolazy commit -m "feat(bootstrap): deploy real config via chezmoi instead of vanilla LazyVim starter"
```

---

## Task 5: Add the headless Mason install-and-wait step

This is the core ask: the script installs every declared tool and blocks until complete, modeled on the existing Tree-sitter `:wait` block. It reads the list from the config via `LazyVim.opts("mason.nvim")` — no second copy in bash.

**Files:**
- Modify: `~/src/neolazy/neovim-lazy-setup.sh` (inside `prefetch_plugins`, the `Step 3/3` Mason block, ~lines 570-574)

- [ ] **Step 1: Renumber the existing Mason-registry step and add the install step**

Find:
```bash
  log "Step 3/3 — updating Mason registry (+MasonUpdate)..."
  _nvim_headless "+MasonUpdate"
  ok "Mason registry updated"

  note_installed "Lazy plugins (synced + compiled)"
```

Replace with:
```bash
  log "Step 3/4 — updating Mason registry (+MasonUpdate)..."
  _nvim_headless "+MasonUpdate"
  ok "Mason registry updated"

  log "Step 4/4 — installing all Mason tools from the config (blocking)..."
  # The tool list lives in lua/plugins/mason.lua (ensure_installed). We read it
  # back via LazyVim.opts and drive mason-registry directly, blocking on each
  # install handle's "closed" event — a plain headless "+qa" would quit before
  # these async installs finish. Already-installed tools are skipped, so this is
  # safe to re-run.
  local mason_lua
  mason_lua="$(mktemp --suffix=.lua)"
  cat >"$mason_lua" <<'LUA'
local tools = {}
local ok_opts, opts = pcall(function() return LazyVim.opts("mason.nvim") end)
if ok_opts and type(opts) == "table" and type(opts.ensure_installed) == "table" then
  tools = opts.ensure_installed
end
if #tools == 0 then
  io.stderr:write("ERROR: no tools found in mason.nvim ensure_installed\n")
  vim.cmd("cq")
  return
end

local registry = require("mason-registry")

-- Make sure the registry is loaded/fresh before querying packages.
local refreshed = false
registry.refresh(function() refreshed = true end)
vim.wait(120000, function() return refreshed end, 200)

-- NOTE: corrected across two debugging rounds (commits 579424d, then the
-- receipt-based fix after a live-fire wipe test).
-- Round 1: the original ":once('closed')" + bare is_installed() approach
-- was broken because (a) LazyVim's mason config auto-starts installs on load
-- so Package:install() raised "Package is already installing", and (b)
-- is_installed() is true mid-install.
-- Round 2 (found by full wipe test): an earlier headless step (Lazy sync)
-- can leave a PARTIAL install dir (e.g. half-built venv) when it exits; the
-- dir-based is_installed() then reports the broken package as installed and
-- we skip it. Real "done" signal = mason-receipt.json exists. We also delete
-- any partial dir before reinstalling so it starts clean.
local function has_receipt(pkg)
  return vim.loop.fs_stat(pkg:get_install_path() .. "/mason-receipt.json") ~= nil
end
local watch = {}
for _, name in ipairs(tools) do
  local ok_pkg, pkg = pcall(registry.get_package, name)
  if not ok_pkg then
    io.stderr:write("WARN: unknown mason package, skipping: " .. name .. "\n")
  elseif has_receipt(pkg) and not pkg:is_installing() then
    io.stdout:write("  - skip (installed): " .. name .. "\n")
  else
    watch[name] = true
    if pkg:is_installing() then
      io.stdout:write("  ~ installing (already started): " .. name .. "\n")
    else
      local dir = pkg:get_install_path()
      if vim.loop.fs_stat(dir) then
        vim.fn.delete(dir, "rf")
        io.stdout:write("  ! cleaning partial install: " .. name .. "\n")
      end
      io.stdout:write("  + installing: " .. name .. "\n")
      pcall(function() pkg:install() end)
    end
  end
end

-- Block up to 30 minutes until every watched tool has a receipt and is idle.
local finished = vim.wait(1800000, function()
  for name, _ in pairs(watch) do
    local ok_pkg, pkg = pcall(registry.get_package, name)
    if not ok_pkg then
      watch[name] = nil
    elseif has_receipt(pkg) and not pkg:is_installing() then
      watch[name] = nil
    end
  end
  return next(watch) == nil
end, 500)
if not finished then
  local left = {}
  for name, _ in pairs(watch) do left[#left + 1] = name end
  io.stderr:write("ERROR: timed out installing: " .. table.concat(left, ", ") .. "\n")
  vim.cmd("cq")
end
LUA
  _nvim_headless "+luafile $mason_lua"
  rm -f "$mason_lua"
  ok "Mason tools installed"

  note_installed "Lazy plugins (synced + compiled)"
  note_installed "Mason tools (ensure_installed)"
```

- [ ] **Step 2: Verify syntax and lint**

Run: `bash -n ~/src/neolazy/neovim-lazy-setup.sh && shellcheck ~/src/neolazy/neovim-lazy-setup.sh`
Expected: valid syntax, no new shellcheck errors.

- [ ] **Step 3: Verify the install lua works against the live (already-installed) setup**

Extract and run just the install step on the current machine, where all 34 tools already exist — it must report skips, not errors:
```bash
tmp=$(mktemp --suffix=.lua)
cat >"$tmp" <<'LUA'
local tools = LazyVim.opts("mason.nvim").ensure_installed
local registry = require("mason-registry")
local refreshed = false
registry.refresh(function() refreshed = true end)
vim.wait(120000, function() return refreshed end, 200)
local missing = {}
for _, name in ipairs(tools) do
  local ok_pkg, pkg = pcall(registry.get_package, name)
  if not ok_pkg then io.stdout:write("UNKNOWN: "..name.."\n")
  elseif not pkg:is_installed() then missing[#missing+1] = name end
end
io.stdout:write("missing: "..(#missing==0 and "none" or table.concat(missing, ", ")).."\n")
LUA
nvim --headless "+luafile $tmp" "+qa" 2>&1; rm -f "$tmp"
```
Expected: `missing: none` and no `UNKNOWN:` lines. An `UNKNOWN:` line means a registry name in `mason.lua` is wrong — fix that name in Task 1's file and re-run.

- [ ] **Step 4: Commit**

```bash
git -C ~/src/neolazy add neovim-lazy-setup.sh
git -C ~/src/neolazy commit -m "feat(bootstrap): install all Mason tools from config, blocking until complete"
```

---

## Task 6: Update the script's header comment to match new behavior

**Files:**
- Modify: `~/src/neolazy/neovim-lazy-setup.sh` (the header block, ~lines 7-14)

- [ ] **Step 1: Update steps 7-8 in the header comment**

Find:
```bash
#   7. Clones LazyVim starter into ~/.config/nvim and removes its .git
#   8. Runs `nvim --headless "+Lazy! sync" +qa` to pre-pull all plugins
```

Replace with:
```bash
#   7. Deploys the Neovim config via chezmoi (expects ~/.config/nvim from chezmoi)
#   8. Headless nvim: syncs plugins, compiles Tree-sitter parsers, and installs
#      every Mason tool listed in lua/plugins/mason.lua (blocking until done)
```

- [ ] **Step 2: Commit**

```bash
git -C ~/src/neolazy add neovim-lazy-setup.sh
git -C ~/src/neolazy commit -m "docs(bootstrap): update header to reflect chezmoi + Mason steps"
```

---

## Task 7: Auto-fire the bootstrap from chezmoi (run_once hook)

Make `chezmoi apply` run the bootstrap automatically on a fresh machine. The hook is **self-guarding**: it no-ops when Neovim is already installed, so it is safe on the current (already-configured) machine and on repeat applies.

**Files:**
- Create (chezmoi source): `~/.local/share/chezmoi/run_once_after_50-neovim-bootstrap.sh`

- [ ] **Step 1: Create the hook script**

Create `~/.local/share/chezmoi/run_once_after_50-neovim-bootstrap.sh`:
```bash
#!/usr/bin/env bash
# Auto-run the neolazy Neovim bootstrap on first chezmoi apply per machine.
# Self-guarding: if nvim is already installed we assume this machine is set up
# and do nothing, so re-applying chezmoi here is harmless.
set -euo pipefail

if command -v nvim >/dev/null 2>&1; then
  echo "[neovim-bootstrap] nvim already installed — skipping bootstrap."
  exit 0
fi

# Need git to fetch the bootstrap repo; install it if missing.
if ! command -v git >/dev/null 2>&1; then
  echo "[neovim-bootstrap] installing git..."
  sudo apt-get update -qq && sudo apt-get install -y git
fi

repo="$HOME/src/neolazy"
if [ -d "$repo/.git" ]; then
  git -C "$repo" pull --ff-only || true
else
  mkdir -p "$HOME/src"
  git clone https://github.com/tkirkland/neolazy "$repo"
fi

echo "[neovim-bootstrap] running neolazy bootstrap..."
bash "$repo/neovim-lazy-setup.sh"
```

- [ ] **Step 2: Make it executable in the source dir**

Run: `chmod +x ~/.local/share/chezmoi/run_once_after_50-neovim-bootstrap.sh`

- [ ] **Step 3: Verify chezmoi sees it as a script and lint it**

Run:
```bash
bash -n ~/.local/share/chezmoi/run_once_after_50-neovim-bootstrap.sh && \
shellcheck ~/.local/share/chezmoi/run_once_after_50-neovim-bootstrap.sh && \
chezmoi managed | grep -i neovim-bootstrap || true
```
Expected: valid syntax, no shellcheck errors. (run_once scripts are not "managed" file targets; the `|| true` keeps the line from failing — confirm instead with `chezmoi state dump` in the next step.)

- [ ] **Step 4: Verify the guard fires on THIS machine (must NOT run the bootstrap)**

Run: `chezmoi apply 2>&1 | grep -i neovim-bootstrap`
Expected: `[neovim-bootstrap] nvim already installed — skipping bootstrap.` and nothing else from the hook. This confirms re-applying on the current machine is safe.

- [ ] **Step 5: Commit in the chezmoi repo**

```bash
git -C ~/.local/share/chezmoi add -A
git -C ~/.local/share/chezmoi commit -m "feat: auto-run neolazy Neovim bootstrap on first apply (self-guarding)"
```
Do NOT push.

---

## Task 8: Final end-to-end sanity check (current machine)

- [ ] **Step 1: Confirm the single-source-of-truth invariant**

Run: `grep -rn "ensure_installed" ~/src/neolazy/neovim-lazy-setup.sh`
Expected: no hardcoded tool list in the script — it only references the list via the headless Lua (`LazyVim.opts("mason.nvim")`). The only literal 34-tool list is in `~/.config/nvim/lua/plugins/mason.lua`.

- [ ] **Step 2: Confirm chezmoi has everything**

Run: `chezmoi managed | grep -c nvim`
Expected: a non-zero count (the nvim config files are tracked).

- [ ] **Step 3: Confirm Neovim is healthy with the new plugin file**

Run: `nvim --headless "+checkhealth mason" "+qa" 2>&1 | tail -20`
Expected: Mason reports OK / tools detected, no errors referencing `mason.lua`.

---

## Out of Scope

- Vendoring the 449 MB Mason binary tree (rejected in the spec — fragile, huge, arch-locked).
- `git push` of either repo (left to the user).
- Verifying the true fresh-machine path end-to-end (needs a clean VM; the run_once guard is verified instead by confirming it no-ops here).
