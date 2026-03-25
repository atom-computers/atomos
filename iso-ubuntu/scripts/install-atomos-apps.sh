#!/bin/bash
# Install desktop applications required by atomos-agents tool adapters.
#
# Each adapter in core/atomos-agents/src/tools/ checks
#   shutil.which("<binary>")
# at startup.  This script ensures the binaries are present where
# possible — via apt, Flatpak, or the Google Cloud apt repo.
#
# IMPORTANT: This script is intentionally non-fatal.  Every install is
# best-effort so that a network hiccup or missing repo never aborts the
# chroot build and prevents boot-critical scripts from running.
# ---------------------------------------------------------------------------

# Explicitly disable errexit — every command is allowed to fail.
set +e

echo "Installing AtomOS application dependencies (best-effort)..."

# ── helpers ───────────────────────────────────────────────────────────────

try_apt() {
    local pkg="$1"
    local binary="${2:-$1}"
    if apt-get install -y --no-install-recommends "$pkg" 2>/dev/null; then
        echo "  ✓ ${binary} (apt: ${pkg})"
        return 0
    fi
    return 1
}

install_flatpak_app() {
    local app_id="$1"
    local binary_name="$2"

    if ! command -v flatpak >/dev/null 2>&1; then
        echo "  ✗ ${binary_name} — flatpak not available, skipping"
        return 1
    fi

    # Ensure Flathub remote exists (idempotent).
    flatpak remote-add --if-not-exists flathub \
        https://dl.flathub.org/repo/flathub.flatpakrepo 2>/dev/null

    echo "  Installing Flatpak: ${app_id} → ${binary_name}..."
    if flatpak install -y --system --noninteractive flathub "${app_id}" 2>/dev/null; then
        cat > "/usr/local/bin/${binary_name}" <<WRAPPER
#!/bin/sh
exec flatpak run ${app_id} "\$@"
WRAPPER
        chmod +x "/usr/local/bin/${binary_name}"
        echo "    ✓ ${binary_name}"
        return 0
    else
        echo "    ✗ ${binary_name} — Flatpak install failed, skipping"
        return 1
    fi
}

# ── 1. APT-first installs ────────────────────────────────────────────────
# Try apt; if the package isn't in the configured repos, fall through to
# Flatpak silently.

# Loupe — GNOME image viewer (Ubuntu 24.04 universe)
try_apt loupe loupe || install_flatpak_app "org.gnome.Loupe" "loupe"

# Chatty — messaging (Ubuntu 24.04 universe, Phosh stack)
try_apt chatty chatty || install_flatpak_app "org.sigxcpu.Chatty" "chatty"

# GNOME Podcasts
try_apt gnome-podcasts gnome-podcasts || install_flatpak_app "org.gnome.Podcasts" "gnome-podcasts"

# ── 2. Flatpak-only installs ─────────────────────────────────────────────

# Amberol — music player (MPRIS2)
install_flatpak_app "io.bassi.Amberol" "amberol"

# Notejot — notes
install_flatpak_app "io.github.lainsce.Notejot" "notejot"

# Authenticator — TOTP / 2FA
install_flatpak_app "com.belmoussaoui.Authenticator" "authenticator"

# Secrets → exposed as "passes" (password manager, Secret Service D-Bus)
install_flatpak_app "org.gnome.World.Secrets" "passes"

# NewsFlash → exposed as "pidif" (RSS/Atom feed reader)
install_flatpak_app "io.gitlab.news_flash.NewsFlash" "pidif"

# ── 3. Google Cloud CLI ──────────────────────────────────────────────────

echo "  Installing Google Cloud CLI..."
if curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
        | gpg --batch --yes --dearmor -o /usr/share/keyrings/cloud.google.gpg 2>/dev/null \
   && echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
        > /etc/apt/sources.list.d/google-cloud-sdk.list \
   && apt-get update -o Dir::Etc::sourcelist=/etc/apt/sources.list.d/google-cloud-sdk.list \
                     -o Dir::Etc::sourceparts="-" \
                     -o APT::Get::List-Cleanup="0" 2>/dev/null \
   && apt-get install -y --no-install-recommends google-cloud-cli 2>/dev/null; then
    echo "    ✓ gcloud"
else
    # Clean up partial gcloud repo config so it doesn't break future apt runs.
    rm -f /etc/apt/sources.list.d/google-cloud-sdk.list
    rm -f /usr/share/keyrings/cloud.google.gpg
    echo "    ✗ gcloud — install failed, Google Workspace tools will be unavailable"
fi

echo "AtomOS application dependencies pass complete."

# Always exit 0 — this script must never abort the chroot build.
exit 0
