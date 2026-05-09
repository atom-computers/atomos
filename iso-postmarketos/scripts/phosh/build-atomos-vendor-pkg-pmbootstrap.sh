#!/bin/bash
# Generic pmbootstrap-based builder for vendored Phosh-stack packages.
#
# Builds ONE Alpine community package (phoc / phosh-mobile-settings /
# phosh-wallpapers / similar) from a local source tree under
# iso-postmarketos/vendor/<pkg>/, then promotes the resulting APK into
# the rootfs chroot so subsequent `apk` queries resolve to our build.
#
# Usage:
#   bash scripts/phosh/build-atomos-vendor-pkg-pmbootstrap.sh \
#       <pkg> <vendor-src-dir> <profile-env>
#
# Example:
#   bash scripts/phosh/build-atomos-vendor-pkg-pmbootstrap.sh \
#       phoc iso-postmarketos/vendor/phoc config/fairphone-fp4.env
#
# Why this exists:
#   build-qemu.sh builds these packages directly via Meson + DESTDIR=/target
#   inside its heavy Alpine arm64 build container. The pmbootstrap path
#   (build-image.sh) uses pmbootstrap+abuild instead, which is the same
#   route postmarketOS itself uses for these packages on the FP4 install.
#   The phosh-specific helper at build-atomos-phosh-pmbootstrap.sh is 1009
#   lines because phosh has many quirks (subprojects gvc/libcall-ui,
#   gnome-settings-daemon virtual provider mismatches, etc). The other
#   three vendor packages have far fewer quirks, so this generic helper
#   handles them with one code path. If any specific vendor package needs
#   special handling (e.g. wlroots subproject pinning for phoc), add a
#   targeted hook below rather than forking the whole helper.
#
# Resolution order at runtime:
#   1. Validate args, source profile env, locate pmaports cache.
#   2. `pmbootstrap aportgen --fork-alpine <pkg>` if the recipe is not
#      already in pmaports cache (no-op when already present).
#   3. Patch APKBUILD: ensure maintainer comment, options !check, and
#      pkgver matching the source tree (where reasonable).
#   4. Run `pmbootstrap build --ignore-depends --src=<vendor-dir> --force <pkg>`.
#   5. Promote the resulting APK into the rootfs chroot so the rootfs
#      world resolves to our locally-built version.
#
# Skipped silently when:
#   - PMOS_UI is not "phosh"
#   - vendor source dir does not exist or has no meson.build
#   - ATOMOS_SKIP_VENDOR_PKG_BUILD=1 is set in the environment
#
# Exit codes: 0 success/skipped, !=0 hard failure that should fail the build.
set -euo pipefail

if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <pkg> <vendor-src-dir> <profile-env>" >&2
    exit 2
fi

PKG="$1"
SRC_DIR="$2"
PROFILE_ENV="$3"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROFILE_ENV_SOURCE="$PROFILE_ENV"
if [ ! -f "$PROFILE_ENV_SOURCE" ] && [ -f "$ROOT_DIR/$PROFILE_ENV" ]; then
    PROFILE_ENV_SOURCE="$ROOT_DIR/$PROFILE_ENV"
fi
if [ ! -f "$PROFILE_ENV_SOURCE" ]; then
    echo "build-atomos-vendor-pkg($PKG): profile env not found: $PROFILE_ENV" >&2
    exit 2
fi

# shellcheck source=/dev/null
source "$PROFILE_ENV_SOURCE"

if [ "${PMOS_UI:-}" != "phosh" ]; then
    echo "build-atomos-vendor-pkg($PKG): PMOS_UI=${PMOS_UI:-<unset>}, not phosh; skipping."
    exit 0
fi

if [ "${ATOMOS_SKIP_VENDOR_PKG_BUILD:-0}" = "1" ]; then
    echo "build-atomos-vendor-pkg($PKG): skip (ATOMOS_SKIP_VENDOR_PKG_BUILD=1)"
    exit 0
fi

# Allow the source dir argument to be relative to either CWD or ROOT_DIR.
if [ ! -d "$SRC_DIR" ] && [ -d "$ROOT_DIR/$SRC_DIR" ]; then
    SRC_DIR="$ROOT_DIR/$SRC_DIR"
fi
if [ ! -d "$SRC_DIR" ]; then
    echo "build-atomos-vendor-pkg($PKG): vendor dir not found: $SRC_DIR (skipping)."
    exit 0
fi
if [ ! -f "$SRC_DIR/meson.build" ]; then
    echo "build-atomos-vendor-pkg($PKG): $SRC_DIR/meson.build missing; nothing to build (skipping)."
    exit 0
fi

ARCH="${ATOMOS_VENDOR_PKG_BUILD_ARCH:-aarch64}"

# Mirror build-atomos-phosh-pmbootstrap.sh's pmb selection (host vs container).
PMB_HOST="$ROOT_DIR/scripts/pmb/pmb.sh"
PMB_CONTAINER="$ROOT_DIR/scripts/pmb/pmb-container.sh"
PMB="$PMB_HOST"
PROFILE_ENV_ARG="$PROFILE_ENV"
PMB_CONTAINER_ROOT=0
SRC_FOR_BUILD="$(cd "$SRC_DIR" && pwd)"
export PATH="${HOME}/.local/bin:${PATH}"
if [ "${PMB_USE_CONTAINER:-0}" = "1" ] || ! command -v pmbootstrap >/dev/null 2>&1; then
    PMB="$PMB_CONTAINER"
    PMB_CONTAINER_ROOT=1
    if [[ "$PROFILE_ENV_SOURCE" == "$ROOT_DIR/"* ]]; then
        PROFILE_ENV_ARG="${PROFILE_ENV_SOURCE#"$ROOT_DIR"/}"
    fi
    # Inside pmb-container, the workspace is mounted at /work.
    SRC_FOR_BUILD="/work/${SRC_DIR#"$ROOT_DIR"/}"
fi

pmaports_cache_dir() {
    local base="$HOME"
    if [ -n "${SUDO_USER:-}" ]; then
        base="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
    fi
    if [ "${PMB_USE_CONTAINER:-0}" = "1" ] || ! command -v pmbootstrap >/dev/null 2>&1; then
        local ch="${PMB_CONTAINER_HOME_DIR:-$base/.atomos-pmbootstrap-home}"
        echo "$ch/.local/var/pmbootstrap/cache_git/pmaports"
    else
        echo "$base/.local/var/pmbootstrap/cache_git/pmaports"
    fi
}

pkg_apkbuild_in_pmaports() {
    local cache="$1"
    [ -d "$cache" ] || return 1
    local found
    found="$(find "$cache" -maxdepth 4 -type f -name APKBUILD -path "*/$PKG/APKBUILD" 2>/dev/null | head -n 1 || true)"
    [ -n "$found" ]
}

pkg_apkbuild_path() {
    local cache="$1"
    find "$cache" -maxdepth 4 -type f -name APKBUILD -path "*/$PKG/APKBUILD" 2>/dev/null | head -n 1
}

# Patch the forked APKBUILD so abuild stops failing on:
#   - missing maintainer line (pmbootstrap auto-adds one for forks but
#     keep it idempotent here);
#   - test runs that are slow / require X11 (`options="!check"`);
#   - architecture restriction (`arch="all"` so cross-build to aarch64
#     succeeds even when the original recipe was noarch-only).
ensure_apkbuild_patches() {
    local apkbuild="$1"
    [ -f "$apkbuild" ] || return 0

    # 1. Maintainer line - abuild HARD-FAILS when an APKBUILD carries the
    # default placeholder ('YOUR NAME <EMAIL@ADDRESS> (CHANGEME!)') because
    # it is not an RFC822 address. pmbootstrap aportgen --fork-alpine drops
    # this placeholder verbatim into pmaports/temp/<pkg>/APKBUILD on first
    # fork. We therefore have to BOTH insert (when no line exists) AND
    # replace (when the line is the placeholder). The phosh helper uses the
    # same logic; mirroring it here keeps behavior consistent across phosh
    # / phoc / phosh-mobile-settings / phosh-wallpapers builds.
    local maint="${ATOMOS_VENDOR_PKG_MAINTAINER:-${ATOMOS_APKBUILD_MAINTAINER:-AtomOS Build <george@atomcomputers.org>}}"
    python3 - "$apkbuild" "$maint" "$PKG" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
maint = sys.argv[2]
pkg = sys.argv[3]
text = path.read_text(encoding="utf-8")

pattern = re.compile(r'^maintainer="([^"]*)"$', flags=re.M)
m = pattern.search(text)
if m:
    current = m.group(1)
    if "CHANGEME" in current or "<EMAIL@ADDRESS>" in current or current.strip() == "":
        text = pattern.sub(f'maintainer="{maint}"', text, count=1)
        path.write_text(text, encoding="utf-8")
        print(f"build-atomos-vendor-pkg({pkg}): replaced placeholder maintainer ({current!r}) -> {maint!r}")
    else:
        print(f"build-atomos-vendor-pkg({pkg}): keeping existing maintainer={current!r}")
else:
    # Insert as the first non-empty line so it sits at top with the other
    # APKBUILD identity metadata (matches abuild's expectations).
    lines = text.splitlines(keepends=True)
    insert_idx = 0
    for i, line in enumerate(lines):
        if line.lstrip().startswith("#") or not line.strip():
            continue
        insert_idx = i
        break
    lines.insert(insert_idx, f'maintainer="{maint}"\n')
    path.write_text("".join(lines), encoding="utf-8")
    print(f"build-atomos-vendor-pkg({pkg}): inserted maintainer={maint!r}")
PY

    # 2. options !check - skip the test phase, which on cross-build often
    # tries to run gtester / x11 / dbus tests that have no display.
    if ! grep -Eq '^options=.*!check' "$apkbuild"; then
        if grep -q '^options=' "$apkbuild"; then
            sed -i 's/^options="\(.*\)"$/options="\1 !check"/' "$apkbuild"
        else
            # Insert after the `arch=` line for visual locality.
            if grep -q '^arch=' "$apkbuild"; then
                sed -i '/^arch=/a options="!check"' "$apkbuild"
            else
                printf '\noptions="!check"\n' >> "$apkbuild"
            fi
        fi
        echo "build-atomos-vendor-pkg($PKG): added options=\"!check\""
    fi
}

# When pmbootstrap forks an Alpine package, it copies the recipe verbatim
# into pmaports/temp/<pkg>/. Subsequent runs need that dir to be writable
# by the user we run as, otherwise sed -i below fails.
ensure_writable_cache_path() {
    local path="$1"
    if [ -e "$path" ] && [ ! -w "$path" ]; then
        echo "build-atomos-vendor-pkg($PKG): making cache path writable: $path"
        if ! chmod -R u+w "$path" 2>/dev/null; then
            if command -v sudo >/dev/null 2>&1; then
                sudo chmod -R u+w "$path" 2>/dev/null || true
            fi
        fi
    fi
}

PMAPORTS_CACHE="$(pmaports_cache_dir)"

# --- Step 1: ensure recipe is in pmaports cache ---------------------------
if ! pkg_apkbuild_in_pmaports "$PMAPORTS_CACHE"; then
    echo "=== pmbootstrap aportgen --fork-alpine $PKG (recipe not yet in pmaports cache) ==="
    set +o pipefail
    if [ "$PMB_CONTAINER_ROOT" = "1" ]; then
        yes "" | PMB_CONTAINER_AS_ROOT=1 bash "$PMB" "$PROFILE_ENV_ARG" aportgen --fork-alpine "$PKG" || true
    else
        yes "" | bash "$PMB" "$PROFILE_ENV_ARG" aportgen --fork-alpine "$PKG" || true
    fi
    set -o pipefail
    if ! pkg_apkbuild_in_pmaports "$PMAPORTS_CACHE"; then
        echo "ERROR: $PKG is still missing under pmaports at $PMAPORTS_CACHE after aportgen." >&2
        echo "  Run manually: pmbootstrap aportgen --fork-alpine $PKG" >&2
        exit 1
    fi
fi
ensure_writable_cache_path "$PMAPORTS_CACHE"

APKBUILD_PATH="$(pkg_apkbuild_path "$PMAPORTS_CACHE")"
if [ -z "$APKBUILD_PATH" ]; then
    echo "ERROR: failed to locate $PKG APKBUILD in $PMAPORTS_CACHE." >&2
    exit 1
fi

ensure_apkbuild_patches "$APKBUILD_PATH"

# Neutralize prepare() when present. Alpine APKBUILDs frequently patch
# their subprojects/<name>-<version>/ tarball-extracted layout in
# prepare() (e.g. phoc patches subprojects/wlroots-0.19.x/). With
# pmbootstrap's --src=<vendor-dir>, the source tree is replaced with our
# vendored Meson workspace, which uses different (usually unversioned)
# subproject directory names AND often a different upstream version --
# the Alpine version-specific patch then either fails ("Can't change to
# directory subprojects/wlroots-0.19.x : No such file or directory") or
# fails to apply cleanly to a different upstream version.
#
# Replacing the body with `default_prepare` is safe because:
#   1. pmbootstrap's abuild_overrides.sh sets `source=""` and
#      `sha512sums=""` for --src builds, so default_prepare's patch loop
#      has nothing to do.
#   2. Vendor sources are already pre-prepared (subprojects checked out
#      at the right version, no tarball-vs-checkout layout mismatch).
#   3. Any APKBUILD-driven autoreconf / sed fixups in the original
#      prepare() were targeting Alpine's tarball-derived files, not our
#      vendored sources.
#
# Set ATOMOS_VENDOR_PKG_KEEP_PREPARE=1 to opt out, e.g. when adding a new
# vendor package whose prepare() does something other than subproject
# patching.
ensure_apkbuild_prepare_safe_for_vendor_src() {
    local apkbuild="$1"
    if [ "${ATOMOS_VENDOR_PKG_KEEP_PREPARE:-0}" = "1" ]; then
        echo "build-atomos-vendor-pkg($PKG): keeping original prepare() (ATOMOS_VENDOR_PKG_KEEP_PREPARE=1)"
        return 0
    fi
    [ -f "$apkbuild" ] || return 0
    python3 - "$apkbuild" "$PKG" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
pkg = sys.argv[2]
text = path.read_text(encoding="utf-8")

# Find a top-level `prepare() { ... }` block. Match the function header,
# then walk braces to find the matching closer (handles nested braces).
header_re = re.compile(r'^prepare\(\)\s*\{\s*$', flags=re.M)
m = header_re.search(text)
if not m:
    print(f"build-atomos-vendor-pkg({pkg}): no prepare() in APKBUILD; nothing to neutralize")
    raise SystemExit(0)

start = m.start()
i = m.end()
depth = 1
n = len(text)
while i < n and depth > 0:
    ch = text[i]
    if ch == '{':
        depth += 1
    elif ch == '}':
        depth -= 1
        if depth == 0:
            i += 1
            break
    i += 1

if depth != 0:
    print(f"build-atomos-vendor-pkg({pkg}): WARNING prepare() braces unbalanced; refusing to neutralize", file=sys.stderr)
    raise SystemExit(0)

old = text[start:i]
# Skip if already neutralized to keep idempotent re-runs noiseless.
if 'AtomOS-vendor-src: prepare() neutralized' in old:
    print(f"build-atomos-vendor-pkg({pkg}): prepare() already neutralized; nothing to do")
    raise SystemExit(0)

new = (
    'prepare() {\n'
    '\t# AtomOS-vendor-src: prepare() neutralized -- the original body\n'
    '\t# patched Alpine\'s versioned subproject layout (e.g.\n'
    '\t# subprojects/wlroots-0.19.x), which does not exist in the vendored\n'
    '\t# source tree pmbootstrap --src=... feeds in. default_prepare is a\n'
    '\t# no-op here because abuild_overrides.sh empties $source for --src.\n'
    '\tdefault_prepare\n'
    '}'
)
text = text[:start] + new + text[i:]
path.write_text(text, encoding="utf-8")
print(f"build-atomos-vendor-pkg({pkg}): neutralized prepare() (was {len(old.splitlines())} lines, now default_prepare)")
PY
}
ensure_apkbuild_prepare_safe_for_vendor_src "$APKBUILD_PATH"

# --- Step 2: build via pmbootstrap with --src override --------------------
# --ignore-depends is the same defensive flag the vendor-phosh helper uses:
# pmbootstrap`s install-step solver can refuse to build a package whose
# binary version is also present in the cached APKINDEX, claiming a
# cyclical dep. --ignore-depends sidesteps that for `pmb build`.
IGNORE_DEP=(--ignore-depends)
if [ "${ATOMOS_VENDOR_PKG_BUILD_IGNORE_DEPENDS:-1}" = "0" ]; then
    IGNORE_DEP=()
fi

echo "=== pmbootstrap build ${IGNORE_DEP[*]} --arch=$ARCH --src=$SRC_FOR_BUILD --force $PKG ==="
set +e
if [ "$PMB_CONTAINER_ROOT" = "1" ]; then
    PMB_CONTAINER_AS_ROOT=1 bash "$PMB" "$PROFILE_ENV_ARG" \
        build "${IGNORE_DEP[@]}" --arch="$ARCH" --src="$SRC_FOR_BUILD" --force "$PKG"
else
    bash "$PMB" "$PROFILE_ENV_ARG" \
        build "${IGNORE_DEP[@]}" --arch="$ARCH" --src="$SRC_FOR_BUILD" --force "$PKG"
fi
build_rc=$?
set -e
if [ "$build_rc" -ne 0 ]; then
    echo "ERROR: pmbootstrap build $PKG failed (exit $build_rc)." >&2
    if [ -n "${PMB_WORK_OVERRIDE:-}" ] && [ -f "${PMB_WORK_OVERRIDE}/log.txt" ]; then
        echo "  Last 80 lines of ${PMB_WORK_OVERRIDE}/log.txt:" >&2
        tail -n 80 "${PMB_WORK_OVERRIDE}/log.txt" >&2 || true
    fi
    exit "$build_rc"
fi

# --- Step 3: leave promotion to the main pipeline -------------------------
# The vendored APK now sits under
#   <PMB_WORK>/packages/edge/<arch>/<pkg>-<ver>.apk
# pmbootstrap install will pick it up automatically when it is the newest
# matching version available. Re-promotion AFTER pmb install (analogous
# to build-image.sh::promote_local_vendor_phosh_into_rootfs) is the
# caller's responsibility -- doing it here would fail because the rootfs
# chroot does not exist yet at this stage of build-image.sh.
echo "build-atomos-vendor-pkg($PKG): build complete; rely on pmbootstrap install to pick up local APK."
echo "  expected output dir: \${PMB_WORK_OVERRIDE:-~/.atomos-pmbootstrap-work/${PROFILE_NAME:-?}}/packages/edge/${ARCH}/"
