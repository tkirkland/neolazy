#!/usr/bin/env bash
#
# install-hyprland.sh
#
# Builds Hyprland v0.54.3 and its hyprwm dependencies from source on
# Debian 13 (Trixie), and configures a no-DM single-user setup:
#
#   - autologin on TTY1 for user "me"
#   - bash login hook that execs the Hyprland wrapper on TTY1
#   - gnome-keyring with PAM auto-unlock on login
#   - global Wayland env vars in /etc/environment
#   - wayland-sessions/hyprland.desktop entry (in case a DM is added later)
#
# Install prefix: /usr
# Source dir:     ~/src/hyprland-build
#
# Usage:
#   ./install-hyprland.sh              # full run
#   ./install-hyprland.sh --skip-apt   # skip the apt step (already installed)
#

set -euo pipefail

# ----- pinned versions for Hyprland v0.54.3 ----------------------------------
HYPRLAND_TAG="v0.54.3"
HYPRUTILS_TAG="v0.11.0"
HYPRLANG_TAG="v0.6.8"
HYPRCURSOR_TAG="v0.1.13"
HYPRGRAPHICS_TAG="v0.5.0"
HYPRWAYLAND_SCANNER_TAG="v0.4.5"
AQUAMARINE_TAG="v0.10.0"
HYPRWIRE_TAG="v0.3.1"
HYPRTOOLKIT_TAG="v0.4.1"
HYPRLAND_GUIUTILS_TAG="v0.2.2"
GLAZE_TAG="v7.5.0"

# system deps too old in trixie; built from source if backports too old
XKBCOMMON_MIN="1.11.0"
WAYLAND_PROTOCOLS_MIN="1.45"
XKBCOMMON_TAG="xkbcommon-1.13.1"
WAYLAND_PROTOCOLS_TAG="1.48"

# ----- locations -------------------------------------------------------------
PREFIX="/usr"
SRC_DIR="${HOME}/src/hyprland-build"
JOBS="$(nproc)"
AUTOLOGIN_USER="me"

# ----- pkg-config paths so each build finds the previous ones ---------------
export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig:${PREFIX}/lib/x86_64-linux-gnu/pkgconfig:${PKG_CONFIG_PATH:-}"

# ----- colors ----------------------------------------------------------------
C_BLUE=$'\033[1;34m'
C_GREEN=$'\033[1;32m'
C_YELLOW=$'\033[1;33m'
C_RED=$'\033[1;31m'
C_RESET=$'\033[0m'

log()  { printf '%s==>%s %s\n' "${C_BLUE}"   "${C_RESET}" "$*"; }
ok()   { printf '%s[ok]%s %s\n' "${C_GREEN}" "${C_RESET}" "$*"; }
warn() { printf '%s[!!]%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*"; }
die()  { printf '%s[xx]%s %s\n' "${C_RED}"   "${C_RESET}" "$*" >&2; exit 1; }

# ----- args ------------------------------------------------------------------
SKIP_APT=0
for arg in "$@"; do
    case "$arg" in
        --skip-apt) SKIP_APT=1 ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) die "unknown arg: $arg" ;;
    esac
done

[[ $EUID -eq 0 ]] && die "run as a normal user; the script will sudo where needed"

# ----- apt build deps --------------------------------------------------------
APT_PACKAGES=(
    # build tools
    build-essential
    cmake
    meson
    ninja-build
    pkg-config
    git
    ca-certificates
    gettext
    gettext-base

    # core libs Hyprland and the hyprwm chain need
    libcairo2-dev
    libpango1.0-dev
    libgbm-dev
    libdrm-dev
    libegl-dev
    libgles-dev
    libxkbcommon-dev
    libxkbcommon-x11-dev
    libpixman-1-dev
    libwayland-dev
    wayland-protocols
    libseat-dev
    libsystemd-dev
    libudev-dev
    libinput-dev
    libliftoff-dev
    libdisplay-info-dev
    libtomlplusplus-dev
    libpugixml-dev
    libre2-dev
    libzip-dev
    libmagic-dev
    libspng-dev
    libjxl-dev
    libpipewire-0.3-dev
    libgtk-3-dev
    librsvg2-dev
    libmuparser-dev

    # graphics / glsl
    glslang-dev
    glslang-tools

    # x11 / xwayland support
    libxcb1-dev
    libxcb-composite0-dev
    libxcb-ewmh-dev
    libxcb-icccm4-dev
    libxcb-render-util0-dev
    libxcb-res0-dev
    libxcb-xinput-dev
    xwayland

    # misc runtime
    polkitd
    seatd
    qt6-wayland
    xdg-desktop-portal
    xdg-desktop-portal-wlr

    # session secrets — gnome-keyring + PAM auto-unlock
    gnome-keyring
    libpam-gnome-keyring
    libsecret-1-0
)

if [[ $SKIP_APT -eq 0 ]]; then
    log "installing apt build dependencies"

    if ! grep -rq "trixie-backports" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
        log "enabling trixie-backports"
        sudo tee /etc/apt/sources.list.d/debian-backports.sources >/dev/null <<'EOF'
Types: deb deb-src
URIs: http://deb.debian.org/debian
Suites: trixie-backports
Components: main contrib non-free non-free-firmware
Enabled: yes
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
    fi

    sudo apt update
    available=()
    for pkg in "${APT_PACKAGES[@]}"; do
        if apt-cache show "$pkg" >/dev/null 2>&1; then
            available+=("$pkg")
        else
            warn "skipping unavailable package: $pkg"
        fi
    done
    sudo apt install -y "${available[@]}"

    if ! command -v g++-15 >/dev/null 2>&1; then
        log "enabling sid temporarily for gcc-15"
        sudo tee /etc/apt/sources.list.d/debian-sid.sources >/dev/null <<'EOF'
Types: deb
URIs: http://deb.debian.org/debian
Suites: sid
Components: main
Enabled: yes
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
        sudo tee /etc/apt/preferences.d/99-pin-sid >/dev/null <<'EOF'
Package: *
Pin: release a=unstable
Pin-Priority: 100
EOF
        sudo apt update
        log "installing gcc-15/g++-15 from sid"
        sudo apt install -y -t sid gcc-15 g++-15

        log "disabling sid source"
        sudo sed -i 's/^Enabled: yes/Enabled: no/' /etc/apt/sources.list.d/debian-sid.sources
        sudo apt update
    else
        ok "g++-15 already installed; skipping sid"
    fi

    ok "apt deps installed"
else
    log "skipping apt step (--skip-apt)"
fi

if command -v g++-15 >/dev/null 2>&1; then
    export CC=gcc-15
    export CXX=g++-15
    ok "using compiler: $($CXX --version | head -1)"
else
    die "g++-15 not found; install failed?"
fi

# ----- prepare source dir ----------------------------------------------------
mkdir -p "$SRC_DIR"
cd "$SRC_DIR"
log "source directory: $SRC_DIR"

# ----- helpers for version-gated system deps ---------------------------------
pc_at_least() {
    local mod="$1" required="$2" have
    have="$(pkg-config --modversion "$mod" 2>/dev/null || true)"
    [[ -z "$have" ]] && return 1
    dpkg --compare-versions "$have" ge "$required"
}

ensure_pc_module() {
    local mod="$1" required="$2" apt_pkg="$3" build_fn="$4"
    if pc_at_least "$mod" "$required"; then
        ok "$mod $(pkg-config --modversion "$mod") satisfies >= $required"
        return 0
    fi

    log "$mod is too old (need >= $required); checking trixie-backports"
    if apt-cache madison "$apt_pkg" 2>/dev/null | grep -q trixie-backports; then
        if sudo apt install -y -t trixie-backports "$apt_pkg" 2>/dev/null; then
            if pc_at_least "$mod" "$required"; then
                ok "$mod from backports: $(pkg-config --modversion "$mod")"
                return 0
            fi
            warn "backports version still too old; falling back to source build"
        else
            warn "backports install failed for $apt_pkg; falling back to source build"
        fi
    else
        warn "$apt_pkg not in trixie-backports; falling back to source build"
    fi

    "$build_fn"

    if ! pc_at_least "$mod" "$required"; then
        die "$mod still too old after build attempt"
    fi
    ok "$mod built from source: $(pkg-config --modversion "$mod")"
}

build_libxkbcommon_from_source() {
    local name="libxkbcommon"
    if [[ ! -d "$name/.git" ]]; then
        git clone https://github.com/xkbcommon/libxkbcommon.git "$name"
    else
        git -C "$name" fetch --tags --force --prune
    fi
    git -C "$name" -c advice.detachedHead=false checkout "$XKBCOMMON_TAG"
    rm -rf "$name/build"
    meson setup "$name/build" "$name" \
        --prefix="$PREFIX" \
        --libdir=lib/x86_64-linux-gnu \
        --buildtype=release \
        -Denable-docs=false
    ninja -C "$name/build" -j "$JOBS"
    sudo ninja -C "$name/build" install
    sudo ldconfig
}

build_wayland_protocols_from_source() {
    local name="wayland-protocols"
    if [[ ! -d "$name/.git" ]]; then
        git clone https://gitlab.freedesktop.org/wayland/wayland-protocols.git "$name"
    else
        git -C "$name" fetch --tags --force --prune
    fi
    git -C "$name" -c advice.detachedHead=false checkout "$WAYLAND_PROTOCOLS_TAG"
    rm -rf "$name/build"
    meson setup "$name/build" "$name" \
        --prefix="$PREFIX" \
        --libdir=lib/x86_64-linux-gnu \
        --buildtype=release \
        -Dtests=false
    ninja -C "$name/build" -j "$JOBS"
    sudo ninja -C "$name/build" install
    sudo ldconfig
}

ensure_pc_module xkbcommon         "$XKBCOMMON_MIN"         libxkbcommon-dev   build_libxkbcommon_from_source
ensure_pc_module wayland-protocols "$WAYLAND_PROTOCOLS_MIN" wayland-protocols  build_wayland_protocols_from_source

# ----- build helpers ---------------------------------------------------------
clone_at_tag() {
    local repo="$1" tag="$2" name
    name="$(basename "$repo")"
    if [[ -d "$name/.git" ]]; then
        git -C "$name" fetch --tags --force --prune
    else
        git clone "https://github.com/hyprwm/$repo.git" "$name"
    fi
    git -C "$name" -c advice.detachedHead=false checkout "$tag"
    git -C "$name" submodule update --init --recursive
}

build_cmake_project() {
    local name="$1"
    log "$name: configuring"
    rm -rf "$name/build"
    cmake -S "$name" -B "$name/build" \
        -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_INSTALL_LIBDIR=lib/x86_64-linux-gnu \
        -DCMAKE_C_COMPILER="$CC" \
        -DCMAKE_CXX_COMPILER="$CXX"
    cmake --build "$name/build" --config Release -j "$JOBS"
    sudo cmake --install "$name/build"
    sudo ldconfig
    ok "$name installed"
}

# ----- build the chain -------------------------------------------------------
clone_at_tag hyprutils            "$HYPRUTILS_TAG";            build_cmake_project hyprutils
clone_at_tag hyprlang             "$HYPRLANG_TAG";             build_cmake_project hyprlang
clone_at_tag hyprcursor           "$HYPRCURSOR_TAG";           build_cmake_project hyprcursor
clone_at_tag hyprwayland-scanner  "$HYPRWAYLAND_SCANNER_TAG";  build_cmake_project hyprwayland-scanner
clone_at_tag hyprgraphics         "$HYPRGRAPHICS_TAG";         build_cmake_project hyprgraphics
clone_at_tag aquamarine           "$AQUAMARINE_TAG";           build_cmake_project aquamarine
clone_at_tag hyprwire             "$HYPRWIRE_TAG";             build_cmake_project hyprwire
clone_at_tag hyprtoolkit          "$HYPRTOOLKIT_TAG";          build_cmake_project hyprtoolkit
clone_at_tag hyprland-guiutils    "$HYPRLAND_GUIUTILS_TAG";    build_cmake_project hyprland-guiutils

# glaze — header-only JSON library, used by Hyprland's hyprpm. Tests off so we
# don't need OpenSSL/SQLite3 dev headers for them.
log "glaze: cloning + checkout $GLAZE_TAG"
if [[ -d glaze/.git ]]; then
    git -C glaze fetch --tags --force --prune
else
    git clone https://github.com/stephenberry/glaze.git glaze
fi
git -C glaze -c advice.detachedHead=false checkout "$GLAZE_TAG"
rm -rf glaze/build
cmake -S glaze -B glaze/build \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_INSTALL_LIBDIR=lib/x86_64-linux-gnu \
    -DCMAKE_C_COMPILER="$CC" \
    -DCMAKE_CXX_COMPILER="$CXX" \
    -Dglaze_DEVELOPER_MODE=OFF \
    -Dglaze_BUILD_EXAMPLES=OFF \
    -DBUILD_TESTING=OFF
cmake --build glaze/build --config Release -j "$JOBS"
sudo cmake --install glaze/build
sudo ldconfig
ok "glaze installed"

# Hyprland itself
clone_at_tag Hyprland "$HYPRLAND_TAG"
log "Hyprland: building"
make -C Hyprland all -j "$JOBS"
sudo make -C Hyprland install PREFIX="$PREFIX"
sudo ldconfig
ok "Hyprland installed"

# ----- launcher wrapper ------------------------------------------------------
WRAPPER="${HOME}/.local/bin/wrappedhl"
mkdir -p "$(dirname "$WRAPPER")"
log "writing launcher wrapper: $WRAPPER"
cat > "$WRAPPER" <<'EOF'
#!/bin/sh
# session-scoped exports (most are also in /etc/environment, but this makes
# wrappedhl work regardless of how it was invoked).
export XDG_SESSION_TYPE=wayland
export XDG_CURRENT_DESKTOP=Hyprland
export XDG_SESSION_DESKTOP=Hyprland

# Start gnome-keyring's secret-service + ssh components for libsecret apps.
# pam_gnome_keyring will already have unlocked the keyring with your login pw.
if command -v gnome-keyring-daemon >/dev/null 2>&1; then
    eval "$(gnome-keyring-daemon --start --components=secrets,ssh)"
    export SSH_AUTH_SOCK GNOME_KEYRING_CONTROL
fi

cd "$HOME"
exec Hyprland "$@"
EOF
chmod +x "$WRAPPER"
ok "wrapper created: $WRAPPER"

# ----- /etc/environment global Wayland vars ----------------------------------
log "adding Wayland env vars to /etc/environment"
ENV_MARK_BEGIN="# >>> hyprland install-script >>>"
ENV_MARK_END="# <<< hyprland install-script <<<"
sudo sed -i "/^${ENV_MARK_BEGIN}\$/,/^${ENV_MARK_END}\$/d" /etc/environment 2>/dev/null || true
sudo tee -a /etc/environment >/dev/null <<EOF
${ENV_MARK_BEGIN}
QT_QPA_PLATFORM=wayland
GDK_BACKEND=wayland
_JAVA_AWT_WM_NONREPARENTING=1
XCURSOR_SIZE=24
MOZ_ENABLE_WAYLAND=1
${ENV_MARK_END}
EOF
ok "/etc/environment updated"

# ----- wayland-sessions desktop file -----------------------------------------
log "installing wayland-sessions/hyprland.desktop"
sudo install -d /usr/share/wayland-sessions
sudo tee /usr/share/wayland-sessions/hyprland.desktop >/dev/null <<EOF
[Desktop Entry]
Name=Hyprland (wrappedhl)
Comment=Hyprland launched via the wrappedhl script
Exec=/home/${AUTOLOGIN_USER}/.local/bin/wrappedhl
Type=Application
EOF
ok "session file installed"

# ----- gnome-keyring PAM auto-unlock on login --------------------------------
log "configuring PAM auto-unlock for gnome-keyring on /etc/pam.d/login"
PAM_LOGIN=/etc/pam.d/login
if ! sudo grep -q "pam_gnome_keyring.so" "$PAM_LOGIN"; then
    sudo cp "$PAM_LOGIN" "${PAM_LOGIN}.bak.$(date +%s)"
    sudo sed -i '/^@include common-auth/a auth optional pam_gnome_keyring.so' "$PAM_LOGIN"
    sudo sed -i '/^@include common-session/a session optional pam_gnome_keyring.so auto_start' "$PAM_LOGIN"
    ok "PAM hooks added (backup at ${PAM_LOGIN}.bak.*)"
else
    ok "PAM already configured for gnome-keyring"
fi

# ----- TTY1 autologin via systemd drop-in ------------------------------------
log "configuring TTY1 autologin for user '${AUTOLOGIN_USER}'"
GETTY_DROPIN_DIR=/etc/systemd/system/getty@tty1.service.d
sudo install -d "$GETTY_DROPIN_DIR"
sudo tee "${GETTY_DROPIN_DIR}/override.conf" >/dev/null <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ${AUTOLOGIN_USER} --noclear %I \$TERM
EOF
sudo systemctl daemon-reload
ok "autologin configured (effective on next boot)"

# ----- bash login hook to exec wrappedhl on TTY1 -----------------------------
log "adding bash login hook to ~/.bash_profile"
BASH_PROFILE="${HOME}/.bash_profile"
HOOK_BEGIN="# >>> hyprland install-script >>>"
HOOK_END="# <<< hyprland install-script <<<"
touch "$BASH_PROFILE"
sed -i "/^${HOOK_BEGIN}\$/,/^${HOOK_END}\$/d" "$BASH_PROFILE"
cat >> "$BASH_PROFILE" <<EOF
${HOOK_BEGIN}
# auto-launch Hyprland when logging into TTY1 (no DM setup)
if [ -z "\${WAYLAND_DISPLAY:-}" ] && [ "\${XDG_VTNR:-0}" -eq 1 ]; then
    exec "\$HOME/.local/bin/wrappedhl"
fi
${HOOK_END}
EOF
ok "bash hook added to $BASH_PROFILE"

# ----- summary ---------------------------------------------------------------
echo
ok "All done."
echo
echo "Reboot to apply autologin. TTY1 will log you in as '${AUTOLOGIN_USER}',"
echo "the bash hook will exec Hyprland via wrappedhl, and pam_gnome_keyring"
echo "will unlock the keyring with your login password."
echo
echo "Other TTYs (Ctrl+Alt+F2..F6) will still give you a normal shell."
echo
echo "Wrapper:               ${WRAPPER}"
echo "Env vars:              /etc/environment  (between marker comments)"
echo "Autologin drop-in:     ${GETTY_DROPIN_DIR}/override.conf"
echo "PAM keyring backup:    ${PAM_LOGIN}.bak.*"
echo "Hyprland config dir:   ~/.config/hypr/  (created on first run)"
