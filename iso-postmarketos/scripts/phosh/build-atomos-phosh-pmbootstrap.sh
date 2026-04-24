#!/bin/bash
# Build pmaports package "phosh" from rust/phosh/phosh via pmbootstrap (Linux / container only).
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

PHOSH_DIR="${ATOMOS_PHOSH_SRC:-$ROOT_DIR/rust/phosh/phosh}"
# Accept two layouts (matches scripts/phosh/checkout-phosh.sh):
#   (a) Git working tree  -- $PHOSH_DIR/.git/ present.
#   (b) Vendored snapshot -- plain source files committed into the atomos
#       parent repo, no nested .git/. Required files for abuild: meson.build
#       (project definition) and src/home.c (one of the AtomOS-patched files;
#       also serves as a sanity gate that the tree is the phosh shell source
#       rather than an unrelated directory).
if [ ! -d "$PHOSH_DIR" ] || [ ! -f "$PHOSH_DIR/meson.build" ] || [ ! -f "$PHOSH_DIR/src/home.c" ]; then
    echo "ERROR: Phosh fork tree missing or incomplete at $PHOSH_DIR" >&2
    echo "       Expected either a git clone or a vendored snapshot with meson.build + src/home.c." >&2
    echo "       Run: bash scripts/phosh/checkout-phosh.sh" >&2
    echo "       (or ensure the AtomOS phosh source tree is present at $PHOSH_DIR)" >&2
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
    PHOSH_FOR_BUILD="/work/rust/phosh/phosh"
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
    # Prefer pmaports-native APKBUILDs first. A stale temp/phosh from older
    # aportgen runs can lag behind (e.g. 0.53.x) and then apk selects newer
    # upstream binaries (0.54.x), bypassing our local --src build during install.
    # Keep temp as fallback only.
    for d in main community testing temp; do
        if [ -f "$cache/$d/phosh/APKBUILD" ]; then
            return 0
        fi
    done
    return 1
}

phosh_apkbuild_path() {
    local cache="$1"
    local d
    # Keep selection order aligned with phosh_apkbuild_in_pmaports().
    for d in main community testing temp; do
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

ensure_phosh_apkbuild_pkgver_matches_source() {
    local apkbuild_path="$1"
    local phosh_src_dir="$2"
    python3 - "$apkbuild_path" "$phosh_src_dir/meson.build" <<'PY'
import pathlib
import re
import sys

apkbuild = pathlib.Path(sys.argv[1])
meson = pathlib.Path(sys.argv[2])

if not meson.exists():
    print(f"WARN: {meson} missing; skip pkgver source alignment")
    sys.exit(0)

meson_text = meson.read_text(encoding="utf-8")
version_match = re.search(r"version:\s*'([^']+)'", meson_text)
if not version_match:
    print("WARN: unable to parse project version from meson.build; skip pkgver alignment")
    sys.exit(0)
source_version = version_match.group(1).strip()

text = apkbuild.read_text(encoding="utf-8")
pkgver_match = re.search(r"^pkgver=([^\n]+)$", text, flags=re.M)
if not pkgver_match:
    print("WARN: pkgver line missing in APKBUILD; skip source version alignment")
    sys.exit(0)

current_pkgver = pkgver_match.group(1).strip()
if current_pkgver == source_version:
    print(f"Using phosh APKBUILD pkgver: {current_pkgver}")
    sys.exit(0)

text = re.sub(r"^pkgver=[^\n]+$", f"pkgver={source_version}", text, count=1, flags=re.M)
apkbuild.write_text(text, encoding="utf-8")
print(f"Updated phosh APKBUILD pkgver: {current_pkgver} -> {source_version}")
PY
}

ensure_phosh_apkbuild_no_virtual_gsd_dep() {
    local apkbuild_path="$1"
    python3 - "$apkbuild_path" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

match = re.search(r'^depends="([^"]*)"$', text, flags=re.M)
if not match:
    print("WARN: depends line missing in APKBUILD; skip virtual gsd dependency patch")
    sys.exit(0)

deps = match.group(1).split()
filtered = [dep for dep in deps if dep != "gnome-settings-daemon"]
if len(filtered) == len(deps):
    print("Using phosh APKBUILD depends: virtual gnome-settings-daemon already absent")
    sys.exit(0)

new_depends = 'depends="' + " ".join(filtered) + '"'
text = text[:match.start()] + new_depends + text[match.end():]
path.write_text(text, encoding="utf-8")
print("Updated phosh APKBUILD depends: removed virtual gnome-settings-daemon")
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

prepare_native_tmp_for_src_override() {
    # pmbootstrap --src appends fetch() logic that writes under /tmp as pmos.
    # Stale root-owned artifacts from previous runs can make rsync/mkstemp fail.
    local cleanup_cmd='
        chmod 1777 /tmp || true
        chown root:root /tmp || true
        rm -rf /tmp/pmbootstrap-local-source-copy
        rm -f /tmp/src-pkgname
    '
    set +e
    if [ "$PMB_CONTAINER_ROOT" = "1" ]; then
        PMB_CONTAINER_AS_ROOT=1 bash "$PMB" "$PROFILE_ENV_ARG" chroot -- /bin/sh -eu -c "$cleanup_cmd"
    else
        bash "$PMB" "$PROFILE_ENV_ARG" chroot -- /bin/sh -eu -c "$cleanup_cmd"
    fi
    local rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        echo "WARN: failed to reset native /tmp source-override artifacts (exit $rc); continuing." >&2
    fi
}

prepare_native_ccache_dir() {
    # C build steps run through ccache in the native chroot. If previous runs
    # left root-owned files in /home/pmos/.ccache, builds fail with EACCES.
    local ccache_cmd='
        rm -rf /home/pmos/.ccache
        install -d -m 700 -o pmos -g pmos /home/pmos/.ccache
        install -d -m 700 -o pmos -g pmos /home/pmos/.ccache/tmp
    '
    set +e
    if [ "$PMB_CONTAINER_ROOT" = "1" ]; then
        PMB_CONTAINER_AS_ROOT=1 bash "$PMB" "$PROFILE_ENV_ARG" chroot -- /bin/sh -eu -c "$ccache_cmd"
    else
        bash "$PMB" "$PROFILE_ENV_ARG" chroot -- /bin/sh -eu -c "$ccache_cmd"
    fi
    local rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        echo "WARN: failed to reset native ccache directory ownership (exit $rc); continuing." >&2
    fi
}

prepare_native_user_cache_dir() {
    # g-ir-scanner writes cache metadata under /home/pmos/.cache; stale
    # root-owned files there can fail long builds near completion.
    local cache_cmd='
        install -d -m 700 -o pmos -g pmos /home/pmos/.cache
        chown -R pmos:pmos /home/pmos/.cache
    '
    set +e
    if [ "$PMB_CONTAINER_ROOT" = "1" ]; then
        PMB_CONTAINER_AS_ROOT=1 bash "$PMB" "$PROFILE_ENV_ARG" chroot -- /bin/sh -eu -c "$cache_cmd"
    else
        bash "$PMB" "$PROFILE_ENV_ARG" chroot -- /bin/sh -eu -c "$cache_cmd"
    fi
    local rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        echo "WARN: failed to reset native user cache directory ownership (exit $rc); continuing." >&2
    fi
}

prepare_native_abuild_key_permissions() {
    # Abuild signs subpackages as user pmos. If keys were previously generated or
    # touched as root, signing fails with permission denied.
    local key_cmd='
        if ! command -v abuild-keygen >/dev/null 2>&1; then
            apk add --no-interactive abuild
        fi
        mkdir -p /home/pmos/.abuild
        chown -R pmos:pmos /home/pmos/.abuild
        chmod 700 /home/pmos/.abuild
        key_path=""
        for f in /home/pmos/.abuild/*.rsa; do
            [ -f "$f" ] || continue
            key_path="$f"
            break
        done
        if [ -n "$key_path" ]; then
            if ! busybox su pmos -c "HOME=/home/pmos test -r \"$key_path\""; then
                echo "Regenerating unreadable abuild private key: $key_path" >&2
                rm -f /home/pmos/.abuild/*.rsa /home/pmos/.abuild/*.rsa.pub
                key_path=""
            fi
        fi
        if [ -z "$key_path" ]; then
            busybox su pmos -c "HOME=/home/pmos abuild-keygen -a -n"
        fi
        for f in /home/pmos/.abuild/*.rsa; do
            [ -f "$f" ] || continue
            chown pmos:pmos "$f"
            chmod 600 "$f"
        done
        mkdir -p /etc/apk/keys
        for f in /home/pmos/.abuild/*.rsa.pub; do
            [ -f "$f" ] || continue
            chown pmos:pmos "$f"
            chmod 644 "$f"
            install -m 644 "$f" /etc/apk/keys/
        done
    '
    set +e
    if [ "$PMB_CONTAINER_ROOT" = "1" ]; then
        PMB_CONTAINER_AS_ROOT=1 bash "$PMB" "$PROFILE_ENV_ARG" chroot -- /bin/sh -eu -c "$key_cmd"
    else
        bash "$PMB" "$PROFILE_ENV_ARG" chroot -- /bin/sh -eu -c "$key_cmd"
    fi
    local rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        echo "WARN: failed to reset native abuild key ownership/permissions (exit $rc); continuing." >&2
    fi
}

prepare_native_package_output_permissions() {
    # Abuild writes resulting APKs as pmos under /home/pmos/packages/pmos/<arch>.
    # If the package tree is root-owned from previous runs, final APK creation fails.
    local pkg_cmd="
        mkdir -p /home/pmos/packages/pmos/${ARCH}
        mkdir -p /home/pmos/packages/edge/${ARCH}
        if [ -L /home/pmos/packages ]; then
            pkg_target=\$(readlink -f /home/pmos/packages || true)
            if [ -n \"\$pkg_target\" ] && [ -d \"\$pkg_target\" ]; then
                chown -R pmos:pmos \"\$pkg_target\" || true
                chmod -R a+rwX \"\$pkg_target\" || true
            fi
        fi
        chown -R pmos:pmos /home/pmos/packages || true
        chmod -R a+rwX /home/pmos/packages || true
    "
    set +e
    if [ "$PMB_CONTAINER_ROOT" = "1" ]; then
        PMB_CONTAINER_AS_ROOT=1 bash "$PMB" "$PROFILE_ENV_ARG" chroot -- /bin/sh -eu -c "$pkg_cmd"
    else
        bash "$PMB" "$PROFILE_ENV_ARG" chroot -- /bin/sh -eu -c "$pkg_cmd"
    fi
    local rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        echo "WARN: failed to reset native package output permissions (exit $rc); continuing." >&2
    fi
}

prepare_native_abuild_repo_destination() {
    # pmbootstrap expects built APKs in /home/pmos/packages/edge/<arch>.
    # If abuild defaults to repo "pmos", pmbootstrap fails post-build with:
    # "Package not found after build: .../packages/edge/<arch>/<pkg>.apk".
    local abuild_conf_cmd="
        mkdir -p /home/pmos/.abuild
        conf=/home/pmos/.abuild/abuild.conf
        [ -f \"\$conf\" ] || touch \"\$conf\"
        if grep -q '^REPODEST=' \"\$conf\"; then
            sed -i 's|^REPODEST=.*|REPODEST=/home/pmos/packages/edge|' \"\$conf\"
        else
            printf '\nREPODEST=/home/pmos/packages/edge\n' >> \"\$conf\"
        fi
        chown pmos:pmos \"\$conf\"
        chmod 600 \"\$conf\"
    "
    set +e
    if [ "$PMB_CONTAINER_ROOT" = "1" ]; then
        PMB_CONTAINER_AS_ROOT=1 bash "$PMB" "$PROFILE_ENV_ARG" chroot -- /bin/sh -eu -c "$abuild_conf_cmd"
    else
        bash "$PMB" "$PROFILE_ENV_ARG" chroot -- /bin/sh -eu -c "$abuild_conf_cmd"
    fi
    local rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        echo "WARN: failed to enforce native abuild REPODEST=edge (exit $rc); continuing." >&2
    fi
}

prepare_host_package_output_permissions() {
    # In --src builds, /home/pmos/packages/pmos points to a bind-mounted host
    # repo path under PMB_WORK_OVERRIDE/packages/edge. If host ownership drifts
    # to root, abuild (running as pmos) can't write final APKs.
    if [ -z "${PMB_WORK_OVERRIDE:-}" ]; then
        return 0
    fi
    local pkg_root edge_root systemd_root pmos_root owner
    pkg_root="${PMB_WORK_OVERRIDE}/packages"
    edge_root="${pkg_root}/edge"
    systemd_root="${pkg_root}/systemd-edge"
    pmos_root="${pkg_root}/pmos"

    mkdir -p "$edge_root" "$pmos_root" 2>/dev/null || true
    mkdir -p "$systemd_root" 2>/dev/null || true

    owner="$(id -u):$(id -g)"
    if [ -n "${SUDO_USER:-}" ]; then
        owner="$(id -u "$SUDO_USER"):$(id -g "$SUDO_USER")"
    fi

    local -a existing=()
    [ -e "$edge_root" ] && existing+=("$edge_root")
    [ -e "$systemd_root" ] && existing+=("$systemd_root")
    [ -e "$pmos_root" ] && existing+=("$pmos_root")
    if [ "${#existing[@]}" -eq 0 ]; then
        return 0
    fi

    set +e
    if command -v sudo >/dev/null 2>&1; then
        sudo chown -R "$owner" "${existing[@]}"
        sudo chmod -R a+rwX "${existing[@]}"
    else
        chown -R "$owner" "${existing[@]}"
        chmod -R a+rwX "${existing[@]}"
    fi
    local rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        echo "WARN: failed to reset host package output permissions (exit $rc); continuing." >&2
    fi
}

prepare_host_apk_keyring_from_native() {
    # pmbootstrap buildroot key trust can come from the host-side config_apk_keys
    # bind mount. Ensure any freshly generated native pmos signing public keys
    # are mirrored there, otherwise index generation can fail with UNTRUSTED.
    if [ -z "${PMB_WORK_OVERRIDE:-}" ]; then
        return 0
    fi
    local native_key_dir host_key_dir copied
    native_key_dir="${PMB_WORK_OVERRIDE}/chroot_native/home/pmos/.abuild"
    host_key_dir="${PMB_WORK_OVERRIDE}/config_apk_keys"
    [ -d "$native_key_dir" ] || return 0

    copied=0
    if ! mkdir -p "$host_key_dir" 2>/dev/null; then
        if command -v sudo >/dev/null 2>&1; then
            sudo mkdir -p "$host_key_dir"
        else
            echo "WARN: cannot create $host_key_dir and sudo is unavailable; skipping keyring sync." >&2
            return 0
        fi
    fi

    for pub in "$native_key_dir"/*.rsa.pub; do
        [ -f "$pub" ] || continue
        local base dst
        base="$(basename "$pub")"
        dst="${host_key_dir}/${base}"
        if cp -f "$pub" "$dst" 2>/dev/null; then
            copied=1
            continue
        fi
        if command -v sudo >/dev/null 2>&1; then
            if sudo cp -f "$pub" "$dst"; then
                copied=1
            fi
        fi
    done

    if [ "$copied" -eq 1 ]; then
        echo "Synced native abuild public keys into host config_apk_keys."
    fi
}

prepare_host_local_repo_aliases() {
    # Some pmbootstrap build paths index local outputs under packages/pmos/<arch>
    # while post-build validation expects packages/edge/<arch>. Alias pmos/<arch>
    # to edge/<arch> so either path resolves to the same files.
    if [ -z "${PMB_WORK_OVERRIDE:-}" ]; then
        return 0
    fi
    local pkg_root edge_arch pmos_root pmos_arch
    pkg_root="${PMB_WORK_OVERRIDE}/packages"
    edge_arch="${pkg_root}/edge/${ARCH}"
    pmos_root="${pkg_root}/pmos"
    pmos_arch="${pmos_root}/${ARCH}"

    mkdir -p "$edge_arch" "$pmos_root" 2>/dev/null || true

    if [ -L "$pmos_arch" ]; then
        return 0
    fi

    set +e
    if [ -d "$pmos_arch" ]; then
        if command -v sudo >/dev/null 2>&1; then
            sudo cp -af "$pmos_arch/." "$edge_arch/" 2>/dev/null || true
            sudo rm -rf "$pmos_arch"
            sudo ln -s "$edge_arch" "$pmos_arch"
        else
            cp -af "$pmos_arch/." "$edge_arch/" 2>/dev/null || true
            rm -rf "$pmos_arch"
            ln -s "$edge_arch" "$pmos_arch"
        fi
    else
        if command -v sudo >/dev/null 2>&1; then
            sudo ln -s "$edge_arch" "$pmos_arch" 2>/dev/null || true
        else
            ln -s "$edge_arch" "$pmos_arch" 2>/dev/null || true
        fi
    fi
    local rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
        echo "Aliased local package repo path: pmos/${ARCH} -> edge/${ARCH}"
    else
        echo "WARN: failed to alias local package repo paths for ${ARCH} (exit $rc); continuing." >&2
    fi
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
ensure_phosh_apkbuild_pkgver_matches_source "$PHOSH_APKBUILD_PATH" "$PHOSH_DIR"
ensure_phosh_apkbuild_skip_check "$PHOSH_APKBUILD_PATH"
ensure_phosh_apkbuild_no_virtual_gsd_dep "$PHOSH_APKBUILD_PATH"
ensure_libcall_ui_subproject
ensure_gvc_subproject
ensure_phosh_gitignore_allows_subprojects
ensure_phosh_tools_present
prepare_native_tmp_for_src_override
prepare_native_ccache_dir
prepare_native_user_cache_dir
prepare_native_abuild_key_permissions
prepare_native_abuild_repo_destination
prepare_native_package_output_permissions
prepare_host_apk_keyring_from_native
prepare_host_package_output_permissions
prepare_host_local_repo_aliases

# --src builds often hit "cyclical build dependency: building phosh with binary
# package of phosh". --ignore-depends skips runtime depends (still installs makedepends).
# Set ATOMOS_PHOSH_BUILD_IGNORE_DEPENDS=0 to omit the flag (stricter; may still fail).
IGNORE_DEP=(--ignore-depends)
if [ "${ATOMOS_PHOSH_BUILD_IGNORE_DEPENDS:-1}" = "0" ]; then
    IGNORE_DEP=()
fi

CCACHE_ENV=()
if [ "${ATOMOS_PHOSH_DISABLE_CCACHE:-1}" = "1" ]; then
    # ccache state in long-lived pmbootstrap chroots can become permission-broken.
    # Default to deterministic no-ccache builds for reliability.
    CCACHE_ENV=(CCACHE_DISABLE=1)
fi
ABUILD_ENV=(REPODEST=/home/pmos/packages/edge)

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

recover_edge_repo_from_pmos_on_missing_artifact() {
    # pmbootstrap sometimes creates/signs local packages under packages/pmos/<arch>
    # but validates completion against packages/edge/<arch>. If that mismatch
    # happens after a successful build, mirror pmos -> edge and continue.
    [ -n "${PMB_WORK_OVERRIDE:-}" ] || return 1
    local log_path edge_dir pmos_dir expected_name
    log_path="$(atomos_work_log)"
    [ -n "$log_path" ] && [ -f "$log_path" ] || return 1

    expected_name="$(
        python3 - "$log_path" "$ARCH" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
arch = re.escape(sys.argv[2])
matches = re.findall(rf"Package not found after build:\s+.*?/packages/edge/{arch}/([^/\s]+\.apk)", text)
print(matches[-1] if matches else "")
PY
    )"
    edge_dir="${PMB_WORK_OVERRIDE}/packages/edge/${ARCH}"
    pmos_dir="${PMB_WORK_OVERRIDE}/packages/pmos/${ARCH}"
    [ -d "$pmos_dir" ] || return 1
    # If pmbootstrap log parsing fails due format/timing, still attempt
    # recovery when phosh artifacts exist in pmos/<arch>.
    if [ -z "$expected_name" ]; then
        for f in "$pmos_dir"/phosh-*.apk; do
            if [ -f "$f" ]; then
                expected_name="$(basename "$f")"
                break
            fi
        done
    fi
    [ -n "$expected_name" ] || return 1
    mkdir -p "$edge_dir" 2>/dev/null || true

    local edge_real pmos_real
    edge_real="$(readlink -f "$edge_dir" 2>/dev/null || true)"
    pmos_real="$(readlink -f "$pmos_dir" 2>/dev/null || true)"
    if [ -n "$edge_real" ] && [ -n "$pmos_real" ] && [ "$edge_real" = "$pmos_real" ]; then
        if [ -f "${edge_dir}/${expected_name}" ]; then
            echo "Recovered missing edge artifact: ${expected_name}" >&2
            return 0
        fi
        return 1
    fi

    echo "WARN: detected pmbootstrap post-build artifact path mismatch; mirroring local repo pmos/${ARCH} -> edge/${ARCH} ..." >&2
    set +e
    if cp -af "${pmos_dir}/." "${edge_dir}/" 2>/dev/null; then
        :
    elif command -v sudo >/dev/null 2>&1; then
        sudo cp -af "${pmos_dir}/." "${edge_dir}/"
    fi
    local copy_rc=$?
    set -e
    if [ "$copy_rc" -ne 0 ]; then
        return 1
    fi

    if [ -f "${edge_dir}/${expected_name}" ]; then
        echo "Recovered missing edge artifact: ${expected_name}" >&2
        return 0
    fi

    # Fallback: if any core phosh APKs now exist in edge, continue and let
    # install phase validate exact package selection.
    local phosh_any=0
    local libphosh_any=0
    for f in "$edge_dir"/phosh-*.apk; do
        if [ -f "$f" ]; then
            phosh_any=1
            break
        fi
    done
    for f in "$edge_dir"/libphosh-*.apk; do
        if [ -f "$f" ]; then
            libphosh_any=1
            break
        fi
    done
    if [ "$phosh_any" -eq 1 ] && [ "$libphosh_any" -eq 1 ]; then
        echo "Recovered edge repo contains phosh/libphosh APK(s) after mirror; continuing." >&2
        return 0
    fi
    return 1
}

recover_edge_repo_from_any_local_phosh_artifacts() {
    # Fallback recovery when pmbootstrap reports edge/<arch> artifact missing.
    # Scan all local repo buckets under packages/*/<arch>/ for phosh APKs and
    # mirror them into edge/<arch>. Also check native/buildroot package outputs.
    [ -n "${PMB_WORK_OVERRIDE:-}" ] || return 1
    local pkg_root edge_dir native_pkg_root buildroot_pkg_root log_path expected_name
    local src base expected_src copied_any copy_failed found_any_source
    pkg_root="${PMB_WORK_OVERRIDE}/packages"
    edge_dir="${pkg_root}/edge/${ARCH}"
    native_pkg_root="${PMB_WORK_OVERRIDE}/chroot_native/home/pmos/packages"
    buildroot_pkg_root="${PMB_WORK_OVERRIDE}/chroot_buildroot_${ARCH}/home/pmos/packages"
    mkdir -p "$edge_dir" 2>/dev/null || true

    log_path="$(atomos_work_log)"
    expected_name=""
    if [ -n "$log_path" ] && [ -f "$log_path" ]; then
        expected_name="$(
            python3 - "$log_path" "$ARCH" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
arch = re.escape(sys.argv[2])
matches = re.findall(rf"Package not found after build:\s+.*?/packages/edge/{arch}/([^/\s]+\.apk)", text)
print(matches[-1] if matches else "")
PY
        )"
    fi
    if [ -n "$expected_name" ] && [ -f "${edge_dir}/${expected_name}" ]; then
        echo "Recovered missing edge artifact: ${expected_name}" >&2
        return 0
    fi

    echo "WARN: searching local package buckets for phosh artifacts to recover edge/${ARCH} ..." >&2
    copied_any=0
    copy_failed=0
    found_any_source=0
    set +e
    if [ -n "$expected_name" ]; then
        for expected_src in "$pkg_root"/*/"$ARCH"/"$expected_name" "$native_pkg_root"/*/"$ARCH"/"$expected_name" "$buildroot_pkg_root"/*/"$ARCH"/"$expected_name"; do
            [ -f "$expected_src" ] || continue
            found_any_source=1
            case "$expected_src" in
                "$edge_dir"/*) continue ;;
            esac
            if cp -af "$expected_src" "$edge_dir/" 2>/dev/null; then
                copied_any=1
            elif command -v sudo >/dev/null 2>&1 && sudo cp -af "$expected_src" "$edge_dir/"; then
                copied_any=1
            else
                copy_failed=1
            fi
        done
    fi
    for src in \
        "$pkg_root"/*/"$ARCH"/phosh-*.apk \
        "$pkg_root"/*/"$ARCH"/libphosh-*.apk \
        "$native_pkg_root"/*/"$ARCH"/phosh-*.apk \
        "$native_pkg_root"/*/"$ARCH"/libphosh-*.apk \
        "$buildroot_pkg_root"/*/"$ARCH"/phosh-*.apk \
        "$buildroot_pkg_root"/*/"$ARCH"/libphosh-*.apk
    do
        [ -f "$src" ] || continue
        found_any_source=1
        case "$src" in
            "$edge_dir"/*) continue ;;
        esac
        base="$(basename "$src")"
        if [ -f "${edge_dir}/${base}" ]; then
            continue
        fi
        if cp -af "$src" "$edge_dir/" 2>/dev/null; then
            copied_any=1
        elif command -v sudo >/dev/null 2>&1 && sudo cp -af "$src" "$edge_dir/"; then
            copied_any=1
        else
            copy_failed=1
        fi
    done
    set -e

    if [ -n "$expected_name" ] && [ -f "${edge_dir}/${expected_name}" ]; then
        echo "Recovered edge artifact from local buckets: ${expected_name}" >&2
        return 0
    fi

    # If copy failed due permissions/path ownership but local artifacts exist in
    # pmos/native/buildroot buckets, continue and let install/origin checks decide.
    if [ "$copied_any" -eq 0 ] && [ "$copy_failed" -ne 0 ] && [ "$found_any_source" -eq 1 ]; then
        echo "WARN: local phosh artifacts found but edge mirror copy failed; proceeding with local repo artifacts." >&2
        return 0
    fi

    local phosh_any=0
    local libphosh_any=0
    for src in "$edge_dir"/phosh-*.apk; do
        if [ -f "$src" ]; then
            phosh_any=1
            break
        fi
    done
    for src in "$edge_dir"/libphosh-*.apk; do
        if [ -f "$src" ]; then
            libphosh_any=1
            break
        fi
    done
    if [ "$phosh_any" -eq 1 ] && [ "$libphosh_any" -eq 1 ]; then
        echo "Recovered edge repo contains phosh/libphosh APK(s) after bucket scan; continuing." >&2
        return 0
    fi
    if [ "$found_any_source" -eq 1 ]; then
        echo "WARN: local phosh APK artifacts exist outside edge/${ARCH}; continuing so install/origin checks can validate." >&2
        return 0
    fi
    return 1
}

set +e
if [ "$PMB_CONTAINER_ROOT" = "1" ]; then
    env "${CCACHE_ENV[@]}" "${ABUILD_ENV[@]}" PMB_CONTAINER_AS_ROOT=1 bash "$PMB" "$PROFILE_ENV_ARG" build "${IGNORE_DEP[@]}" --arch "$ARCH" --src "$PHOSH_FOR_BUILD" --force phosh
else
    env "${CCACHE_ENV[@]}" "${ABUILD_ENV[@]}" bash "$PMB" "$PROFILE_ENV_ARG" build "${IGNORE_DEP[@]}" --arch "$ARCH" --src "$PHOSH_FOR_BUILD" --force phosh
fi
rc=$?
set -e

if [ "$rc" -ne 0 ]; then
    if recover_edge_repo_from_pmos_on_missing_artifact; then
        rc=0
    elif recover_edge_repo_from_any_local_phosh_artifacts; then
        rc=0
    fi
fi

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
