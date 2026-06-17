#!/usr/bin/env bash
# nvim-bootstrap.sh
# One-shot Neovim + LazyVim bootstrap for a fresh Debian 13 / Kubuntu install.
#
# What it does:
#   1. Sanity-checks (not root, sudo available, network up)
#   2. Prompts to back up existing ~/.config/nvim and ~/.local/share/nvim
#   3. apt-installs baseline build/runtime deps
#   4. Installs rustup system-wide to /usr/local (for blink.cmp)
#   5. Fetches latest GitHub releases for nvim, ripgrep, fd, fzf, lazygit,
#      tree-sitter and merges them into /usr/local/{bin,share,lib}
#   6. Installs Python and Node neovim providers (pynvim via pipx, neovim via npm -g)
#   7. Clones LazyVim starter into ~/.config/nvim and removes its .git
#   8. Runs `nvim --headless "+Lazy! sync" +qa` to pre-pull all plugins
#
# Run as your normal user; the script will sudo internally where needed.

set -euo pipefail

# ---------- helpers ----------------------------------------------------------

c_red=$'\033[0;31m'
c_grn=$'\033[0;32m'
c_ylw=$'\033[0;33m'
c_blu=$'\033[0;34m'
c_dim=$'\033[2m'
c_rst=$'\033[0m'

log()   { printf '%s[*]%s %s\n' "$c_blu" "$c_rst" "$*"; }
ok()    { printf '%s[+]%s %s\n' "$c_grn" "$c_rst" "$*"; }
warn()  { printf '%s[!]%s %s\n' "$c_ylw" "$c_rst" "$*" >&2; }
err()   { printf '%s[x]%s %s\n' "$c_red" "$c_rst" "$*" >&2; }
skip()  { printf '%s[-]%s %s%s%s\n' "$c_dim" "$c_rst" "$c_dim" "$*" "$c_rst"; }

declare -a INSTALLED=()
declare -a SKIPPED=()

note_installed() { INSTALLED+=("$1"); }
note_skipped()   { SKIPPED+=("$1"); }

confirm() {
  # confirm "prompt text" -> returns 0 for yes, 1 for no
  local prompt="$1" reply
  while true; do
    read -r -p "$prompt [y/N]: " reply || return 1
    case "${reply,,}" in
    y|yes) return 0 ;;
    n|no|"") return 1 ;;
    *) echo "Please answer y or n." ;;
    esac
  done
}

have() { command -v "$1" >/dev/null 2>&1; }

arch_tag() {
  # Map uname -m to the tag style used by upstream releases.
  case "$(uname -m)" in
  x86_64|amd64) echo "x86_64" ;;
  aarch64|arm64) echo "aarch64" ;;
  *) err "Unsupported architecture: $(uname -m)"; exit 1 ;;
  esac
}

# Fetch latest release tag from GitHub API. $1 = "owner/repo".
gh_latest_tag() {
  local repo="$1" json tag
  # Buffer the full response before grep -m1 so curl doesn't get SIGPIPE
  # when grep exits early (which would trip pipefail and abort the script).
  json="$(curl -fsSL "https://api.github.com/repos/${repo}/releases/latest")"
  tag="$(printf '%s\n' "$json" \
    | grep -m1 '"tag_name":' \
    | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')"
  if [ -z "$tag" ]; then
    err "Could not determine latest release tag for ${repo} (API rate-limited or unexpected response)"
    exit 1
  fi
  echo "$tag"
}

# Resolve a release asset's real download URL by matching its filename against
# an extended-regex pattern, via the GitHub API. Unlike hand-building the
# filename (which 404s the moment upstream renames an asset or changes its
# version string), this validates the asset actually exists and self-heals
# across version bumps. Fails loudly with the available asset list on no match.
# $1 = "owner/repo", $2 = release tag, $3 = ERE matched against the asset name.
gh_asset_url() {
  local repo="$1" tag="$2" pattern="$3" json url names
  json="$(curl -fsSL "https://api.github.com/repos/${repo}/releases/tags/${tag}")"
  # Match the pattern against the asset basename by anchoring it to the final
  # path segment of the download URL (strip the leading ^, require a preceding
  # slash). grep -E honours \. as a literal dot; awk -v would mangle the escape.
  url="$(printf '%s\n' "$json" \
    | grep -oE '"browser_download_url": *"[^"]+"' \
    | sed -E 's/.*"(https[^"]+)".*/\1/' \
    | grep -E "/${pattern#^}" \
    | head -n1)"
  if [ -z "$url" ]; then
    names="$(printf '%s\n' "$json" \
      | grep -oE '"name": *"[^"]+"' \
      | sed -E 's/.*"([^"]+)".*/\1/' \
      | grep -E '\.' | paste -sd', ' -)"
    err "No asset matching /${pattern}/ for ${repo} ${tag}. Available: ${names:-<none>}"
    exit 1
  fi
  echo "$url"
}

# Download a URL to a temple and echo the path.
fetch_to_tmp() {
  local url="$1" dst
  dst="$(mktemp)"
  curl -fsSL -o "$dst" "$url"
  echo "$dst"
}

# Run a command with sudo, but only if not already root.
sudo_run() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

# ---------- pre-flight -------------------------------------------------------

if [ "$(id -u)" -eq 0 ]; then
  err "Please run as your normal user; the script will sudo when needed."
  exit 1
fi

if ! have sudo; then
  err "sudo not found. Install sudo and add your user to it, then re-run."
  exit 1
fi

if sudo -n true 2>/dev/null; then
  : # passwordless sudo available, proceed silently
else
  log "Validating sudo (you may be prompted for your password)..."
  sudo -v
fi
# Keep sudo alive in the background while the script runs.
( while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done ) &
SUDO_KEEPALIVE_PID=$!
# shellcheck disable=SC2064  # intentional: expand PID now, not at trap-fire time
trap "kill '$SUDO_KEEPALIVE_PID' 2>/dev/null || true" EXIT

# Bootstrap curl + ca-certificates before anything else first since the rest of the
# script (and the network reachability check below) depends on curl.
bootstrap_apt_essentials() {
  local need=()
  have curl || need+=(curl)
  dpkg -s ca-certificates >/dev/null 2>&1 || need+=(ca-certificates)
  if [ "${#need[@]}" -gt 0 ]; then
    log "Bootstrapping essentials via apt: ${need[*]}"
    sudo_run apt-get update -qq
    sudo_run apt-get install -y "${need[@]}"
    for pkg in "${need[@]}"; do
      ok "$pkg installed"
      note_installed "apt:$pkg"
    done
  fi
}

bootstrap_apt_essentials

if ! curl -fsSL --max-time 10 https://github.com >/dev/null; then
  err "Cannot reach github.com. Check your network and retry."
  exit 1
fi

ARCH="$(arch_tag)"
ok "Architecture detected: $ARCH"

# ---------- backup prompts ---------------------------------------------------

backup_if_present() {
  local path="$1"
  if [ -e "$path" ]; then
    local ts backup
    ts="$(date +%Y%m%d-%H%M%S)"
    backup="${path}.bak.${ts}"
    mv "$path" "$backup"
    ok "Backed up $path -> $backup"
  fi
}

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

# ---------- apt packages -----------------------------------------------------

APT_PKGS=(
  git curl wget unzip tar
  build-essential
  python3 python3-pip python3-venv pipx pipenv
  sqlite3 libsqlite3-dev
  ca-certificates gnupg
)

log "Updating apt index..."
sudo_run apt-get update -qq

log "Checking apt packages..."
to_install=()
for pkg in "${APT_PKGS[@]}"; do
  if dpkg -s "$pkg" >/dev/null 2>&1; then
    skip "$pkg (already installed)"
    note_skipped "apt:$pkg"
  else
    to_install+=("$pkg")
  fi
done

if [ "${#to_install[@]}" -gt 0 ]; then
  log "Installing: ${to_install[*]}"
  sudo_run apt-get install -y "${to_install[@]}"
  for pkg in "${to_install[@]}"; do
    ok "$pkg installed"
    note_installed "apt:$pkg"
  done
else
  ok "All apt packages already present."
fi

# Make sure pipx's user bin is on PATH for this session and persistently.
if have pipx; then
  pipx ensurepath >/dev/null 2>&1 || true
  # shellcheck disable=SC1091
  [ -d "$HOME/.local/bin" ] && export PATH="$HOME/.local/bin:$PATH"
fi

# ---------- Node.js (NodeSource current LTS) --------------------------------

install_nodejs_lts() {
  local node_major=24  # Active LTS as of 2026
  local current_major=""
  if have node; then
    current_major="$(node --version 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/')"
  fi

  if [ -n "$current_major" ] && [ "$current_major" -ge "$node_major" ]; then
    skip "node $(node --version) already installed (>= v${node_major})"
    note_skipped "nodejs"
    return 0
  fi

  log "Installing Node.js ${node_major}.x LTS from NodeSource..."
  local tmp
  tmp="$(mktemp)"
  curl -fsSL "https://deb.nodesource.com/setup_${node_major}.x" -o "$tmp"
  sudo_run bash "$tmp"
  rm -f "$tmp"
  sudo_run apt-get install -y nodejs
  ok "Node.js $(node --version) installed"
  note_installed "nodejs $(node --version)"
}

install_nodejs_lts

# ---------- rustup (system-wide) --------------------------------------------

install_rustup_systemwide() {
  if have rustc && have cargo; then
    skip "rustc/cargo already present ($(rustc --version 2>/dev/null || echo unknown))"
    note_skipped "rustup"
    return 0
  fi

  log "Installing rustup system-wide to /usr/local..."
  local tmp
  tmp="$(mktemp -d)"
  pushd "$tmp" >/dev/null
  curl -fsSL https://sh.rustup.rs -o rustup-init.sh
  chmod +x rustup-init.sh
  # CARGO_HOME and RUSTUP_HOME under /usr/local make it system-wide.
  sudo_run env \
    CARGO_HOME=/usr/local/cargo \
    RUSTUP_HOME=/usr/local/rustup \
    ./rustup-init.sh -y --no-modify-path --default-toolchain stable --profile minimal
  popd >/dev/null
  rm -rf "$tmp"

  # Symlink cargo/rustc/rustup into /usr/local/bin so they're on PATH.
  local bin
  for bin in cargo rustc rustup rustdoc; do
    if [ -x "/usr/local/cargo/bin/$bin" ]; then
      sudo_run ln -sf "/usr/local/cargo/bin/$bin" "/usr/local/bin/$bin"
    fi
  done

  # Persistent env for everyone (CARGO_HOME/RUSTUP_HOME are needed for cargo install --root).
  sudo_run tee /etc/profile.d/rust-systemwide.sh >/dev/null <<'EOF'
export RUSTUP_HOME=/usr/local/rustup
export CARGO_HOME=/usr/local/cargo
EOF
  sudo_run chmod 644 /etc/profile.d/rust-systemwide.sh

  ok "rustup installed system-wide"
  note_installed "rustup (system-wide /usr/local)"
}

install_rustup_systemwide
export RUSTUP_HOME=/usr/local/rustup
export CARGO_HOME=/usr/local/cargo

# ---------- Neovim from GitHub releases -------------------------------------

install_neovim() {
  local desired_tag current
  desired_tag="$(gh_latest_tag neovim/neovim)"

  if have nvim; then
    current="$(nvim --version | head -n1 | awk '{print $2}')"
    if [ "$current" = "$desired_tag" ]; then
      skip "nvim $current already installed"
      note_skipped "nvim ($current)"
      return 0
    else
      log "nvim $current present; upgrading to $desired_tag..."
    fi
  else
    log "Installing nvim $desired_tag..."
  fi

  # Resolve the tarball from the release (v0.10+ uses nvim-linux-<arch>.tar.gz;
  # the .appimage assets are excluded by anchoring on \.tar\.gz$).
  local narch url
  narch="$( [ "$ARCH" = "x86_64" ] && echo x86_64 || echo arm64 )"
  url="$(gh_asset_url neovim/neovim "$desired_tag" "^nvim-linux-${narch}\.tar\.gz$")"

  local tarball extract_dir
  tarball="$(fetch_to_tmp "$url")"
  extract_dir="$(mktemp -d)"
  tar -xzf "$tarball" -C "$extract_dir"
  rm -f "$tarball"

  # The tarball top-level dir varies by version; find it.
  local top
  top="$(find "$extract_dir" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  if [ -z "$top" ]; then
    err "Could not find extracted Neovim directory."
    exit 1
  fi

  # Merge bin/, share/, lib/ into /usr/local/.
  local sub
  for sub in bin share lib; do
    if [ -d "$top/$sub" ]; then
      sudo_run cp -a "$top/$sub/." "/usr/local/$sub/"
    fi
  done
  rm -rf "$extract_dir"

  # Register nvim as the system editor/vi/vim via update-alternatives.
  if have update-alternatives; then
    sudo_run update-alternatives --install /usr/bin/editor editor /usr/local/bin/nvim 100
    sudo_run update-alternatives --install /usr/bin/vi     vi     /usr/local/bin/nvim 100
    sudo_run update-alternatives --install /usr/bin/vim    vim    /usr/local/bin/nvim 100
    sudo_run update-alternatives --set editor /usr/local/bin/nvim
    sudo_run update-alternatives --set vi     /usr/local/bin/nvim
    sudo_run update-alternatives --set vim    /usr/local/bin/nvim
    ok "Registered nvim as default editor/vi/vim via update-alternatives"
  fi

  ok "nvim $desired_tag installed to /usr/local"
  note_installed "nvim $desired_tag"
}

# Generic GitHub-release-to-/usr/local/bin installer for single-binary tools.
# $1 = repo (owner/name), $2 = command name to check, $3 = function that
# echoes an ERE pattern matching the asset filename for this arch.
install_gh_binary() {
  local repo="$1" cmd="$2" pattern_fn="$3"
  if have "$cmd"; then
    skip "$cmd already installed ($(command -v "$cmd"))"
    note_skipped "$cmd"
    return 0
  fi
  local tag asset url tmp
  tag="$(gh_latest_tag "$repo")"
  url="$(gh_asset_url "$repo" "$tag" "$($pattern_fn)")"
  asset="${url##*/}"
  log "Installing $cmd $tag from $repo..."
  tmp="$(mktemp -d)"
  pushd "$tmp" >/dev/null
  curl -fsSL -o "$asset" "$url"

  case "$asset" in
  *.tar.gz|*.tgz) tar -xzf "$asset" ;;
  *.tar.xz)       tar -xJf "$asset" ;;
  *.zip)          unzip -q "$asset" ;;
  *)              err "Unknown archive type: $asset"; popd >/dev/null; rm -rf "$tmp"; exit 1 ;;
  esac

  # Find the binary in the extracted tree and install it.
  local found
  found="$(find . -type f -name "$cmd" -perm -u+x | head -n1)"
  if [ -z "$found" ]; then
    # Some archives put the binary at the top level without an exec bit set yet.
    found="$(find . -type f -name "$cmd" | head -n1)"
  fi
  if [ -z "$found" ]; then
    err "Could not locate '$cmd' binary in $asset"
    popd >/dev/null
    rm -rf "$tmp"
    exit 1
  fi
  sudo_run install -m 0755 "$found" "/usr/local/bin/$cmd"
  popd >/dev/null
  rm -rf "$tmp"
  ok "$cmd $tag installed"
  note_installed "$cmd $tag"
}

# Asset-name patterns (extended regex), matched against the release's actual
# asset filenames by gh_asset_url. Version-agnostic on purpose: ".*" spans the
# version string, so a release bump never breaks the match — only a genuine
# rename of the stable parts would, and that surfaces as a clear error.
# ripgrep ships musl for x86_64 but only gnu for aarch64.
asset_ripgrep()    { echo "^ripgrep-.*-$( [ "$ARCH" = "x86_64" ] && echo x86_64-unknown-linux-musl || echo aarch64-unknown-linux-gnu )\.tar\.gz$"; }
asset_fd()         { echo "^fd-.*-${ARCH}-unknown-linux-musl\.tar\.gz$"; }
asset_fzf()        { echo "^fzf-.*-linux_$( [ "$ARCH" = "x86_64" ] && echo amd64 || echo arm64 )\.tar\.gz$"; }
asset_lazygit()    { echo "^lazygit_.*_linux_$( [ "$ARCH" = "x86_64" ] && echo x86_64 || echo arm64 )\.tar\.gz$"; }
# tree-sitter ships an unversioned, gzipped single binary (e.g.
# tree-sitter-linux-x64.gz) — note x64/arm64, not x86_64/aarch64.
asset_treesitter() { echo "^tree-sitter-linux-$( [ "$ARCH" = "x86_64" ] && echo x64 || echo arm64 )\.gz$"; }

# tree-sitter ships a single gzipped binary, not a tarball — handle separately.
install_treesitter() {
  if have tree-sitter; then
    skip "tree-sitter already installed ($(command -v tree-sitter))"
    note_skipped "tree-sitter"
    return 0
  fi
  local tag asset url tmp
  tag="$(gh_latest_tag tree-sitter/tree-sitter)"
  url="$(gh_asset_url tree-sitter/tree-sitter "$tag" "$(asset_treesitter)")"
  asset="${url##*/}"
  log "Installing tree-sitter $tag..."
  tmp="$(mktemp -d)"
  pushd "$tmp" >/dev/null
  curl -fsSL -o "$asset" "$url"
  gunzip "$asset"
  local bin="${asset%.gz}"
  sudo_run install -m 0755 "$bin" /usr/local/bin/tree-sitter
  popd >/dev/null
  rm -rf "$tmp"
  ok "tree-sitter $tag installed"
  note_installed "tree-sitter $tag"
}

install_neovim
install_gh_binary BurntSushi/ripgrep    rg       asset_ripgrep
install_gh_binary sharkdp/fd            fd       asset_fd
install_gh_binary junegunn/fzf          fzf      asset_fzf
install_gh_binary jesseduffield/lazygit lazygit  asset_lazygit
install_treesitter

# ---------- Python provider --------------------------------------------------

install_pynvim() {
  if pipx list 2>/dev/null | grep -q 'pynvim'; then
    skip "pynvim already installed via pipx"
    note_skipped "pynvim"
    return 0
  fi
  log "Installing pynvim via pipx..."
  pipx install pynvim
  ok "pynvim installed"
  note_installed "pynvim (pipx)"
}

install_pynvim

# ---------- Node provider ----------------------------------------------------

install_node_neovim() {
  if npm list -g --depth=0 2>/dev/null | grep -q ' neovim@'; then
    skip "npm 'neovim' package already installed globally"
    note_skipped "npm:neovim"
    return 0
  fi
  log "Installing npm 'neovim' package globally..."
  sudo_run npm install -g neovim
  ok "npm 'neovim' installed"
  note_installed "npm:neovim"
}

install_node_neovim

# ---------- Deploy config from chezmoi --------------------------------------

# The Neovim config is owned by chezmoi (dot_config/nvim). Ensure it is applied
# so ~/.config/nvim exists before we sync plugins / install tools. If chezmoi
# isn't installed or initialized, fail loudly with guidance rather than silently
# falling back to a vanilla starter (which would not reproduce this setup).
deploy_config() {
  if [ -d "$HOME/.config/nvim" ] && [ -f "$HOME/.config/nvim/lua/plugins/mason.lua" ]; then
    skip "$HOME/.config/nvim already present (mason.lua found)"
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

deploy_config

# ---------- Pre-pull plugins via headless lazy sync --------------------------

prefetch_plugins() {
  # Run a single headless nvim Ex command.  Uses `script` to provide a PTY, so
  # plugins that check for a terminal (e.g., lazy.nvim progress UI, blink.cmp
  # cargo build) don't skip work.  Output is NOT suppressed, so failures are
  # visible — critical for diagnosing bootstrap and compilation errors.
  _nvim_headless() {
    local excmd="$1"
    if have script; then
      script -qe -c "nvim --headless \"${excmd}\" +qa" /dev/null
    else
      nvim --headless "${excmd}" +qa
    fi
  }

  log "Step 1/3 — installing plugins (+Lazy! sync)..."
  _nvim_headless "+Lazy! sync"
  ok "Plugin sync complete"

  log "Step 2/3 — compiling Tree-sitter parsers (nvim-treesitter main)..."
  # LazyVim now tracks nvim-treesitter's `main` branch (the old `master` repo
  # was archived 2026-04-03). `main` removed the synchronous `:TSUpdateSync`
  # command in favour of an async Lua API, so a headless `+TSUpdateSync` now
  # fails with "Not an editor command". For a bootstrap we must call install()
  # and block on :wait(), or nvim quits via +qa before any parser compiles.
  # See the nvim-treesitter README, "synchronous installation in a script
  # context (bootstrapping)". Requires tree-sitter CLI >= 0.26.1 (installed
  # above) and a C compiler (build-essential, installed above).
  local ts_lua
  ts_lua="$(mktemp --suffix=.lua)"
  cat >"$ts_lua" <<'LUA'
-- Resolve the parser list from LazyVim's merged opts; fall back to a core set.
local langs
local ok, opts = pcall(function() return LazyVim.opts("nvim-treesitter") end)
if ok and type(opts) == "table" and type(opts.ensure_installed) == "table" then
  langs = {}
  for _, l in ipairs(opts.ensure_installed) do
    if type(l) == "string" then langs[#langs + 1] = l end
  end
end
if not langs or #langs == 0 then
  langs = {
    "bash", "c", "diff", "html", "javascript", "json", "jsonc", "lua",
    "luadoc", "markdown", "markdown_inline", "python", "query", "regex",
    "toml", "tsx", "typescript", "vim", "vimdoc", "yaml",
  }
end
-- install() runs asynchronously; block up to 10 minutes for parsers to build.
require("nvim-treesitter").install(langs):wait(600000)
LUA
  _nvim_headless "+luafile $ts_lua"
  rm -f "$ts_lua"
  ok "Tree-sitter parsers compiled"

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

-- Refresh the registry before querying/installing.
local refreshed = false
registry.refresh(function() refreshed = true end)
vim.wait(120000, function() return refreshed end, 200)

-- LazyVim's own mason config auto-starts installs for missing ensure_installed
-- tools when the plugin loads, so some packages may already be installing.
-- Package:install() asserts "Package is already installing" on those, so only
-- start the ones that aren't, guarded with pcall. Track unfinished tools.
local watch = {}
for _, name in ipairs(tools) do
  local ok_pkg, pkg = pcall(registry.get_package, name)
  if not ok_pkg then
    io.stderr:write("WARN: unknown mason package, skipping: " .. name .. "\n")
  elseif pkg:is_installed() and not pkg:is_installing() then
    io.stdout:write("  - skip (installed): " .. name .. "\n")
  else
    watch[name] = true
    if pkg:is_installing() then
      io.stdout:write("  ~ installing (already started): " .. name .. "\n")
    else
      io.stdout:write("  + installing: " .. name .. "\n")
      pcall(function() pkg:install() end)
    end
  end
end

-- Block until every watched tool is fully done. is_installed() alone is
-- unreliable — mason creates the package directory mid-install, so it reports
-- true before the download finishes — hence we also require not is_installing().
local finished = vim.wait(1800000, function()
  for name, _ in pairs(watch) do
    local ok_pkg, pkg = pcall(registry.get_package, name)
    if not ok_pkg then
      watch[name] = nil
    elseif pkg:is_installed() and not pkg:is_installing() then
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
}

prefetch_plugins

# ---------- Summary ----------------------------------------------------------

echo
echo "============================================================"
echo " Bootstrap complete."
echo "============================================================"
echo
echo "${c_grn}Installed / configured this run:${c_rst}"
for item in "${INSTALLED[@]}"; do
  echo "  + $item"
done
echo
echo "${c_dim}Already present (skipped):${c_rst}"
for item in "${SKIPPED[@]}"; do
  echo "  - $item"
done
echo
echo "Next steps:"
echo "  * Open a new shell (so PATH and pipx/cargo env vars apply), then run: nvim"
echo "  * Inside nvim: :checkhealth   to verify everything is wired up"
echo "  * Inside nvim: :LazyHealth    for LazyVim-specific checks"
echo
