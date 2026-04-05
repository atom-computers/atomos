#!/bin/bash
# Build pmaports package "phosh" from vendor/phosh/phosh via pmbootstrap (Linux / container only).
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <profile-env>" >&2
    exit 1
fi

PROFILE_ENV="$1"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROFILE_ENV_SOURCE="$PROFILE_ENV"
if [ ! -f "$PROFILE_ENV_SOURCE" ] && [ -f "$ROOT_DIR/$PROFILE_ENV" ]; then
    PROFILE_ENV_SOURCE="$ROOT_DIR/$PROFILE_ENV"
fi
if [ ! -f "$PROFILE_ENV_SOURCE" ]; then
    echo "Profile env not found: $PROFILE_ENV" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$PROFILE_ENV_SOURCE"

if [ "${PMOS_UI:-}" != "phosh" ]; then
    echo "build-atomos-phosh: PMOS_UI is not phosh; skip"
    exit 0
fi

if [ "${ATOMOS_SKIP_VENDOR_PHOSH_BUILD:-0}" = "1" ]; then
    echo "build-atomos-phosh: skip (ATOMOS_SKIP_VENDOR_PHOSH_BUILD=1)"
    exit 0
fi

PHOSH_DIR="${ATOMOS_PHOSH_SRC:-$ROOT_DIR/vendor/phosh/phosh}"
if [ ! -d "$PHOSH_DIR/.git" ]; then
    echo "ERROR: Patched Phosh tree missing at $PHOSH_DIR — run make build from iso-postmarketos/ (runs checkout-phosh) or: bash scripts/phosh/checkout-phosh.sh" >&2
    exit 1
fi

ARCH="${ATOMOS_PHOSH_BUILD_ARCH:-aarch64}"

PMB_HOST="$ROOT_DIR/scripts/pmb/pmb.sh"
PMB_CONTAINER="$ROOT_DIR/scripts/pmb/pmb-container.sh"
PMB="$PMB_HOST"
PROFILE_ENV_ARG="$PROFILE_ENV"
PMB_CONTAINER_ROOT=0
export PATH="${HOME}/.local/bin:${PATH}"
if [ "${PMB_USE_CONTAINER:-0}" = "1" ] || ! command -v pmbootstrap >/dev/null 2>&1; then
    PMB="$PMB_CONTAINER"
    PMB_CONTAINER_ROOT=1
    if [[ "$PROFILE_ENV_SOURCE" == "$ROOT_DIR/"* ]]; then
        PROFILE_ENV_ARG="${PROFILE_ENV_SOURCE#"$ROOT_DIR"/}"
    fi
    PHOSH_FOR_BUILD="/work/vendor/phosh/phosh"
else
    PHOSH_FOR_BUILD="$(cd "$PHOSH_DIR" && pwd)"
fi

# pmbootstrap build PKG --src=... only works if PKG has an APKBUILD in pmaports.
# When Phosh is Alpine-only in the cache, fork it first (matches upstream error text).
atomos_pmaports_cache_dir() {
    local base="$HOME"
    if [ -n "${SUDO_USER:-}" ]; then
        base="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
    fi
    if [ "${PMB_USE_CONTAINER:-0}" = "1" ]; then
        local ch="${PMB_CONTAINER_HOME_DIR:-$base/.atomos-pmbootstrap-home}"
        echo "$ch/.local/var/pmbootstrap/cache_git/pmaports"
    else
        echo "$base/.local/var/pmbootstrap/cache_git/pmaports"
    fi
}

phosh_apkbuild_in_pmaports() {
    local cache="$1"
    local d
    # aportgen --fork-alpine places new aports under temp/<pkg>/ (see pmbootstrap log).
    for d in temp main community testing; do
        if [ -f "$cache/$d/phosh/APKBUILD" ]; then
            return 0
        fi
    done
    return 1
}

phosh_apkbuild_path() {
    local cache="$1"
    local d
    for d in temp main community testing; do
        if [ -f "$cache/$d/phosh/APKBUILD" ]; then
            echo "$cache/$d/phosh/APKBUILD"
            return 0
        fi
    done
    return 1
}

ensure_writable_pmaports_cache() {
    local cache="$1"
    [ -d "$cache" ] || return 0
    # Container-root pmbootstrap operations can leave cache_git files owned by root
    # on the host mount. Ensure local patching steps can update APKBUILD.
    local candidate=""
    local d
    for d in temp main community testing; do
        if [ -f "$cache/$d/phosh/APKBUILD" ]; then
            candidate="$cache/$d/phosh/APKBUILD"
            break
        fi
    done
    if [ -n "$candidate" ] && [ -w "$candidate" ]; then
        return 0
    fi
    echo "Fixing ownership for pmaports cache: $cache"
    if command -v sudo >/dev/null 2>&1; then
        sudo chown -R "$(id -u):$(id -g)" "$cache"
    else
        chown -R "$(id -u):$(id -g)" "$cache"
    fi
}

ensure_phosh_apkbuild_maintainer() {
    local apkbuild_path="$1"
    local maint="${ATOMOS_APKBUILD_MAINTAINER:-AtomOS Build <george@atomcomputers.org>}"
    python3 - "$apkbuild_path" "$maint" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
maint = sys.argv[2]
text = path.read_text(encoding="utf-8")

pattern = re.compile(r'^maintainer="([^"]*)"$', flags=re.M)
m = pattern.search(text)
if not m:
    print("maintainer line missing in APKBUILD", file=sys.stderr)
    sys.exit(1)

current = m.group(1)
if "CHANGEME" in current or "<EMAIL@ADDRESS>" in current:
    text = pattern.sub(f'maintainer="{maint}"', text, count=1)
    path.write_text(text, encoding="utf-8")
    print(f"Updated phosh APKBUILD maintainer: {current} -> {maint}")
else:
    print(f"Using phosh APKBUILD maintainer: {current}")
PY
}

ensure_phosh_apkbuild_skip_check() {
    local apkbuild_path="$1"
    if [ "${ATOMOS_PHOSH_SKIP_CHECK:-1}" != "1" ]; then
        return 0
    fi
    python3 - "$apkbuild_path" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

options_match = re.search(r'^options="([^"]*)"$', text, flags=re.M)
if options_match:
    options = options_match.group(1).split()
    if "!check" not in options:
        options.append("!check")
        new = 'options="' + " ".join(options) + '"'
        text = re.sub(r'^options="[^"]*"$', new, text, count=1, flags=re.M)
        path.write_text(text, encoding="utf-8")
        print("Updated phosh APKBUILD options: appended !check")
    else:
        print("Using phosh APKBUILD options: !check already set")
else:
    # Keep patch minimal: add options directly after package metadata.
    anchor = re.search(r'^(pkgrel=.*)$', text, flags=re.M)
    if not anchor:
        print("ERROR: could not locate pkgrel/options section in APKBUILD", file=sys.stderr)
        sys.exit(1)
    insert_at = anchor.end()
    text = text[:insert_at] + '\noptions="!check"' + text[insert_at:]
    path.write_text(text, encoding="utf-8")
    print("Updated phosh APKBUILD options: created options=\"!check\"")
PY
}

ensure_libcall_ui_subproject() {
    fetch_subproject_from_wrap "libcall-ui"
}

ensure_gvc_subproject() {
    fetch_subproject_from_wrap "gvc"
}

fetch_subproject_from_wrap() {
    local subproject="$1"
    local wraps_dir="$PHOSH_DIR/subprojects"
    local wrap_file="$wraps_dir/$subproject.wrap"
    local subdir="$wraps_dir/$subproject"

    if [ -d "$subdir" ]; then
        # Either a git checkout or a vendored source snapshot is fine.
        if [ -d "$subdir/.git" ]; then
            return 0
        fi
        if [ -f "$subdir/meson.build" ]; then
            return 0
        fi
        # Corrupt/partial directory from previous failed clone.
        rm -rf "$subdir"
    fi
    if [ ! -f "$wrap_file" ]; then
        echo "ERROR: missing $wrap_file required for phosh build ($subproject)." >&2
        exit 1
    fi
    if ! command -v git >/dev/null 2>&1; then
        echo "ERROR: git is required to fetch meson subproject $subproject." >&2
        exit 1
    fi

    local url revision depth
    url="$(awk -F= '/^url=/{print $2; exit}' "$wrap_file")"
    revision="$(awk -F= '/^revision=/{print $2; exit}' "$wrap_file")"
    depth="$(awk -F= '/^depth=/{print $2; exit}' "$wrap_file")"
    [ -n "$depth" ] || depth="1"
    if [ -z "$url" ] || [ -z "$revision" ]; then
        echo "ERROR: unable to parse url/revision from $wrap_file ($subproject)." >&2
        exit 1
    fi

    echo "Fetching phosh subproject $subproject ($revision) ..."
    if ! git clone --depth "$depth" "$url" "$subdir"; then
        echo "ERROR: git clone failed for $subproject from $url" >&2
        exit 1
    fi
    if ! git -C "$subdir" checkout -q "$revision"; then
        if ! git -C "$subdir" fetch --depth "$depth" origin "$revision"; then
            echo "ERROR: git fetch failed for $subproject revision $revision" >&2
            exit 1
        fi
        if ! git -C "$subdir" checkout -q FETCH_HEAD; then
            echo "ERROR: git checkout failed for $subproject revision $revision" >&2
            exit 1
        fi
    fi
}

ensure_phosh_gitignore_allows_subprojects() {
    local gi="$PHOSH_DIR/.gitignore"
    [ -f "$gi" ] || return 0
    # pmbootstrap --src rsync uses source .gitignore with --exclude-from.
    # Unlike gitignore, rsync exclude files do not support "!" negation the same
    # way. Remove excludes that strip required vendored paths/tools.
    if grep -qE '^(/subprojects/libcall-ui|/subprojects/gvc|/tools/?|tools/?|/tools/\*|tools/\*|/tools/check-exported-symbols)$' "$gi"; then
        python3 - "$gi" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines()
to_remove = {
    "/subprojects/libcall-ui",
    "!/subprojects/libcall-ui",
    "/subprojects/gvc",
    "!/subprojects/gvc",
    "/tools",
    "tools",
    "/tools/",
    "tools/",
    "/tools/*",
    "tools/*",
    "/tools/check-exported-symbols",
    "!/tools/check-exported-symbols",
}
filtered = [ln for ln in lines if ln.strip() not in to_remove]
path.write_text("\n".join(filtered) + "\n", encoding="utf-8")
PY
        echo "Updated phosh .gitignore: removed required paths rsync excludes"
    fi
}

ensure_phosh_tools_present() {
    local tools_dir="$PHOSH_DIR/tools"
    local check_syms="$tools_dir/check-exported-symbols"
    mkdir -p "$tools_dir"
    if [ ! -f "$check_syms" ]; then
        cat > "$check_syms" <<'EOF'
#!/bin/bash
#
# Make sure our binary only exports the wanted symbols.

BIN=${1:-"_build/src/phosh"}
PHOSH_SYMBOL_PREFIXES='phosh_(shell|wifi|wwan|mpris_manager|media_player|monitor|notification|notify_manager|quick_setting|status_icon|status_page|status_page_placholder|session_manager|util)_'

if objdump -T "$BIN" | grep 'g    DF .text' \
    | grep -v -E " (main$|${PHOSH_SYMBOL_PREFIXES}|gtk_(filter|sort)_list_model_)"; then
    echo "Found symbols that shouldn't be exported"
    exit 1
fi

exit 0
EOF
        echo "Created missing phosh tools/check-exported-symbols helper"
    fi
    chmod +x "$check_syms"
}

PMAPORTS_CACHE="$(atomos_pmaports_cache_dir)"
if ! phosh_apkbuild_in_pmaports "$PMAPORTS_CACHE"; then
    echo "=== pmbootstrap aportgen --fork-alpine phosh (required before build phosh --src) ==="
    set +o pipefail
    if [ "$PMB_CONTAINER_ROOT" = "1" ]; then
        yes "" | PMB_CONTAINER_AS_ROOT=1 bash "$PMB" "$PROFILE_ENV_ARG" aportgen --fork-alpine phosh || true
    else
        yes "" | bash "$PMB" "$PROFILE_ENV_ARG" aportgen --fork-alpine phosh || true
    fi
    set -o pipefail
    if ! phosh_apkbuild_in_pmaports "$PMAPORTS_CACHE"; then
        echo "ERROR: phosh is still missing under pmaports at $PMAPORTS_CACHE after aportgen." >&2
        echo "  Run manually: pmbootstrap aportgen --fork-alpine phosh" >&2
        exit 1
    fi
fi
ensure_writable_pmaports_cache "$PMAPORTS_CACHE"

PHOSH_APKBUILD_PATH="$(phosh_apkbuild_path "$PMAPORTS_CACHE")"
if [ -z "$PHOSH_APKBUILD_PATH" ]; then
    echo "ERROR: failed to locate phosh APKBUILD in $PMAPORTS_CACHE." >&2
    exit 1
fi
ensure_phosh_apkbuild_maintainer "$PHOSH_APKBUILD_PATH"
ensure_phosh_apkbuild_skip_check "$PHOSH_APKBUILD_PATH"
ensure_libcall_ui_subproject
ensure_gvc_subproject
ensure_phosh_gitignore_allows_subprojects
ensure_phosh_tools_present

# --src builds often hit "cyclical build dependency: building phosh with binary
# package of phosh". --ignore-depends skips runtime depends (still installs makedepends).
# Set ATOMOS_PHOSH_BUILD_IGNORE_DEPENDS=0 to omit the flag (stricter; may still fail).
IGNORE_DEP=(--ignore-depends)
if [ "${ATOMOS_PHOSH_BUILD_IGNORE_DEPENDS:-1}" = "0" ]; then
    IGNORE_DEP=()
fi

echo "=== pmbootstrap build ${IGNORE_DEP[*]} --arch=$ARCH --src=$PHOSH_FOR_BUILD --force phosh (install picks up local packages) ==="

atomos_work_log() {
    if [ -n "${PMB_WORK_OVERRIDE:-}" ] && [ -f "${PMB_WORK_OVERRIDE}/log.txt" ]; then
        echo "${PMB_WORK_OVERRIDE}/log.txt"
        return 0
    fi
    local base="$HOME"
    if [ -n "${SUDO_USER:-}" ]; then
        base="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
    fi
    local wd="${base}/.atomos-pmbootstrap-work/${PROFILE_NAME:-profile}/log.txt"
    if [ -f "$wd" ]; then
        echo "$wd"
        return 0
    fi
    echo ""
}

set +e
if [ "$PMB_CONTAINER_ROOT" = "1" ]; then
    PMB_CONTAINER_AS_ROOT=1 bash "$PMB" "$PROFILE_ENV_ARG" build "${IGNORE_DEP[@]}" --arch "$ARCH" --src "$PHOSH_FOR_BUILD" --force phosh
else
    bash "$PMB" "$PROFILE_ENV_ARG" build "${IGNORE_DEP[@]}" --arch "$ARCH" --src "$PHOSH_FOR_BUILD" --force phosh
fi
rc=$?
set -e

if [ "$rc" -ne 0 ]; then
    LOG_PATH="$(atomos_work_log)"
    echo "" >&2
    echo "ERROR: pmbootstrap build phosh failed (exit $rc). Cyclical-dep warnings are common; the real error is usually in the log above '^^^'." >&2
    if [ -n "$LOG_PATH" ]; then
        echo "=== Last 100 lines of $LOG_PATH ===" >&2
        tail -n 100 "$LOG_PATH" >&2 || true
    else
        echo "Log not found (set PMB_WORK_OVERRIDE or run from make build). Run: pmbootstrap log" >&2
    fi
    echo "" >&2
    echo "Hint: if the log shows abuild \"No private key\", run an up-to-date make build (it runs abuild-keygen in the native chroot first) or see iso-postmarketos/README.md." >&2
    exit "$rc"
fi
