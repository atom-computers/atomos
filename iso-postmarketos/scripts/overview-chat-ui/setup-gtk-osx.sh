#!/usr/bin/env bash
# Bootstrap GTK/macOS toolchain for local GTK preview runs.
# Uses GNOME's upstream gtk-osx setup helper.
set -euo pipefail

GTK_OSX_SETUP_URL="https://gitlab.gnome.org/GNOME/gtk-osx/-/raw/master/gtk-osx-setup.sh"
JHBUILD_BIN="${ATOMOS_OVERVIEW_CHAT_UI_JHBUILD_BIN:-$HOME/.new_local/bin/jhbuild}"
BOOTSTRAP_BREW_GTK4="${ATOMOS_OVERVIEW_CHAT_UI_BOOTSTRAP_BREW_GTK4:-1}"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/atomos-overview-chat-ui"
BREW_ENV_FILE="$CONFIG_DIR/macos-gtk.env"

if [ "$(uname -s)" != "Darwin" ]; then
    echo "setup-gtk-osx: this helper is for macOS only." >&2
    exit 2
fi

have_jhbuild_gtk4_stack() {
    [ -x "$JHBUILD_BIN" ] && "$JHBUILD_BIN" run pkg-config --exists gtk4 gdk-pixbuf-2.0 graphene-gobject-1.0 2>/dev/null
}

have_host_gtk4_stack() {
    command -v pkg-config >/dev/null 2>&1 &&
        pkg-config --exists gtk4 libadwaita-1 gdk-pixbuf-2.0 graphene-gobject-1.0
}

write_brew_env_file() {
    local prefixes=()
    local pc_paths=()
    local p
    local path_joined=""
    mkdir -p "$CONFIG_DIR"
    for p in gtk4 libadwaita gdk-pixbuf graphene; do
        if command -v brew >/dev/null 2>&1; then
            local prefix
            prefix="$(brew --prefix "$p" 2>/dev/null || true)"
            if [ -n "$prefix" ]; then
                prefixes+=("$prefix")
                if [ -d "$prefix/lib/pkgconfig" ]; then
                    pc_paths+=("$prefix/lib/pkgconfig")
                fi
                if [ -d "$prefix/share/pkgconfig" ]; then
                    pc_paths+=("$prefix/share/pkgconfig")
                fi
            fi
        fi
    done
    if [ "${#pc_paths[@]}" -eq 0 ]; then
        return 1
    fi
    path_joined="$(IFS=:; echo "${pc_paths[*]}")"
    cat > "$BREW_ENV_FILE" <<EOF
#!/usr/bin/env bash
export PKG_CONFIG_PATH="$path_joined\${PKG_CONFIG_PATH:+:\$PKG_CONFIG_PATH}"
EOF
    chmod +x "$BREW_ENV_FILE"
    return 0
}

if have_jhbuild_gtk4_stack; then
    echo "setup-gtk-osx: jhbuild environment already has GTK runtime pkg-config entries; skipping bootstrap."
    exit 0
fi

if have_host_gtk4_stack; then
    echo "setup-gtk-osx: gtk4/libadwaita already available via pkg-config; skipping bootstrap."
    exit 0
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "setup-gtk-osx: curl is required." >&2
    exit 1
fi

tmp_script="$(mktemp "${TMPDIR:-/tmp}/gtk-osx-setup.XXXXXX.sh")"
cleanup() {
    rm -f "$tmp_script"
}
trap cleanup EXIT

echo "setup-gtk-osx: downloading upstream bootstrap script..."
curl -fsSL "$GTK_OSX_SETUP_URL" -o "$tmp_script"
chmod +x "$tmp_script"

echo "setup-gtk-osx: running gtk-osx setup (this can take a while)..."
bash "$tmp_script"

if have_jhbuild_gtk4_stack || have_host_gtk4_stack; then
    echo "setup-gtk-osx: completed."
    exit 0
fi

if [ "$BOOTSTRAP_BREW_GTK4" = "1" ] && command -v brew >/dev/null 2>&1; then
    echo "setup-gtk-osx: gtk-osx defaults do not provide gtk4/libadwaita; installing Homebrew GTK4 stack..."
    brew install pkg-config gtk4 libadwaita gdk-pixbuf graphene
    if ! write_brew_env_file; then
        echo "setup-gtk-osx: failed to generate brew pkg-config environment file." >&2
        exit 1
    fi
    # shellcheck source=/dev/null
    source "$BREW_ENV_FILE"
    if have_host_gtk4_stack; then
        echo "setup-gtk-osx: completed with Homebrew GTK4 stack."
        echo "setup-gtk-osx: environment helper written to $BREW_ENV_FILE"
        exit 0
    fi
fi

echo "setup-gtk-osx: setup completed but gtk4/libadwaita pkg-config entries are still missing." >&2
echo "Try running manually:" >&2
echo "  brew install pkg-config gtk4 libadwaita gdk-pixbuf graphene" >&2
echo "Then re-run this script." >&2
exit 1
