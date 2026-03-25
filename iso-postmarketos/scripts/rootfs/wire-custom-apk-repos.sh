#!/bin/bash
# Append custom APK repos + keys; optional apk add (pmbootstrap chroot only).
# Configure via profile env (see docs/PHOSH.md §1).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PMB_HOST="$ROOT_DIR/scripts/pmb/pmb.sh"
PMB_CONTAINER="$ROOT_DIR/scripts/pmb/pmb-container.sh"

load_profile() {
    local pe="$1"
    PROFILE_ENV_SOURCE="$pe"
    if [ ! -f "$PROFILE_ENV_SOURCE" ] && [ -f "$ROOT_DIR/$pe" ]; then
        PROFILE_ENV_SOURCE="$ROOT_DIR/$pe"
    fi
    if [ ! -f "$PROFILE_ENV_SOURCE" ]; then
        echo "Profile env not found: $pe" >&2
        exit 1
    fi
    # shellcheck source=/dev/null
    source "$PROFILE_ENV_SOURCE"
}

append_repos_to_file() {
    local repo_file="$1"
    mkdir -p "$(dirname "$repo_file")"
    touch "$repo_file"
    while IFS= read -r url; do
        url="${url#"${url%%[![:space:]]*}"}"
        url="${url%"${url##*[![:space:]]}"}"
        [ -z "$url" ] && continue
        if grep -qxF "$url" "$repo_file" 2>/dev/null; then
            continue
        fi
        echo "$url" >> "$repo_file"
        echo "  + repo: $url"
    done
}

copy_keys_to_rootfs() {
    local dest_root="$1"
    local keys_csv="$2"
    [ -z "$keys_csv" ] && return 0
    mkdir -p "$dest_root/etc/apk/keys"
    while IFS= read -r raw; do
        raw="${raw#"${raw%%[![:space:]]*}"}"
        raw="${raw%"${raw##*[![:space:]]}"}"
        [ -z "$raw" ] && continue
        local keypath="$raw"
        if [[ "$keypath" != /* ]]; then
            keypath="$ROOT_DIR/$keypath"
        fi
        if [ ! -f "$keypath" ]; then
            echo "ERROR: APK signing key file not found: $keypath" >&2
            exit 1
        fi
        local base
        base="$(basename "$keypath")"
        cp -f "$keypath" "$dest_root/etc/apk/keys/$base"
        echo "  + key: /etc/apk/keys/$base"
    done < <(echo "$keys_csv" | tr ',' '\n')
}

if [ "${1:-}" = "--rootfs" ]; then
    if [ "$#" -ne 3 ]; then
        echo "Usage: $0 --rootfs <rootfs-dir> <profile-env>" >&2
        exit 1
    fi
    ROOTFS="${2%/}"
    load_profile "$3"
    if [ ! -d "$ROOTFS" ]; then
        echo "ERROR: rootfs directory not found: $ROOTFS" >&2
        exit 1
    fi
    URLS_CSV="${PMOS_CUSTOM_APK_REPO_URLS:-}"
    KEYS_CSV="${PMOS_CUSTOM_APK_KEY_FILES:-}"
    if [ -z "$URLS_CSV$KEYS_CSV" ]; then
        echo "wire-custom-apk-repos: nothing configured (rootfs), skip"
        exit 0
    fi
    echo "wire-custom-apk-repos: rootfs $ROOTFS"
    copy_keys_to_rootfs "$ROOTFS" "$KEYS_CSV"
    if [ -n "$URLS_CSV" ]; then
        append_repos_to_file "$ROOTFS/etc/apk/repositories" < <(echo "$URLS_CSV" | tr ',' '\n')
    fi
    if [ -n "${PMOS_CUSTOM_APK_PACKAGES:-}" ]; then
        echo "NOTE: PMOS_CUSTOM_APK_PACKAGES is set but cannot run apk inside cross-arch rootfs here;" >&2
        echo "  install on device or use pmbootstrap chroot (make build) for apk add." >&2
    fi
    echo "wire-custom-apk-repos: done (rootfs)"
    exit 0
fi

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <profile-env> | $0 --rootfs <rootfs-dir> <profile-env>" >&2
    exit 1
fi

PROFILE_ENV="$1"
load_profile "$PROFILE_ENV"

URLS_CSV="${PMOS_CUSTOM_APK_REPO_URLS:-}"
KEYS_CSV="${PMOS_CUSTOM_APK_KEY_FILES:-}"
PKGS_CSV="${PMOS_CUSTOM_APK_PACKAGES:-}"
if [ -z "$URLS_CSV$KEYS_CSV$PKGS_CSV" ]; then
    echo "wire-custom-apk-repos: nothing configured, skip"
    exit 0
fi

PMB="$PMB_HOST"
PROFILE_ENV_ARG="$PROFILE_ENV"
PMB_CONTAINER_ROOT=0
if [ "${PMB_USE_CONTAINER:-0}" = "1" ] || ! command -v pmbootstrap >/dev/null 2>&1; then
    PMB="$PMB_CONTAINER"
    PMB_CONTAINER_ROOT=1
    if [[ "$PROFILE_ENV" == "$ROOT_DIR/"* ]]; then
        PROFILE_ENV_ARG="${PROFILE_ENV#"$ROOT_DIR"/}"
    fi
fi

if [ "${ATOMOS_WIRE_APK_DUMP_ONLY:-0}" = "1" ]; then
    echo "wire-custom-apk-repos: would configure repos/keys/packages for ${PROFILE_NAME}"
    exit 0
fi

echo "wire-custom-apk-repos: chroot (${PROFILE_NAME})"

if [ -n "$KEYS_CSV" ]; then
    while IFS= read -r raw; do
        raw="${raw#"${raw%%[![:space:]]*}"}"
        raw="${raw%"${raw##*[![:space:]]}"}"
        [ -z "$raw" ] && continue
        keypath="$raw"
        if [[ "$keypath" != /* ]]; then
            keypath="$ROOT_DIR/$keypath"
        fi
        if [ ! -f "$keypath" ]; then
            echo "ERROR: APK signing key file not found: $keypath" >&2
            exit 1
        fi
        base="$(basename "$keypath")"
        qbase="$(printf '%q' "$base")"
        if [ "$PMB_CONTAINER_ROOT" = "1" ]; then
            cat "$keypath" | PMB_CONTAINER_AS_ROOT=1 bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "mkdir -p /etc/apk/keys && cat > /etc/apk/keys/$qbase"
        else
            cat "$keypath" | bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "mkdir -p /etc/apk/keys && cat > /etc/apk/keys/$qbase"
        fi
    done < <(echo "$KEYS_CSV" | tr ',' '\n')
fi

URLS_TMP="$(mktemp)"
trap 'rm -f "$URLS_TMP"' EXIT
if [ -n "$URLS_CSV" ]; then
    echo "$URLS_CSV" | tr ',' '\n' | sed '/^$/d;s/^[[:space:]]*//;s/[[:space:]]*$//' > "$URLS_TMP"
fi

INNER_HEAD='set -eu
mkdir -p /etc/apk/keys
touch /etc/apk/repositories
'

INNER_LOOP=""
while IFS= read -r url; do
    [ -z "$url" ] && continue
    INNER_LOOP+=$(printf 'grep -qxF %q /etc/apk/repositories || echo %q >> /etc/apk/repositories\n' "$url" "$url")
done < "$URLS_TMP"

INNER_TAIL='apk update
'

if [ -n "$PKGS_CSV" ]; then
    PKGS_SPACE="$(echo "$PKGS_CSV" | tr ',' ' ')"
    INNER_TAIL+="apk add -q $PKGS_SPACE || apk add $PKGS_SPACE"$'\n'
fi

INNER_SCRIPT="$INNER_HEAD$INNER_LOOP$INNER_TAIL"

if [ "$PMB_CONTAINER_ROOT" = "1" ]; then
    PMB_CONTAINER_AS_ROOT=1 bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$INNER_SCRIPT"
else
    bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$INNER_SCRIPT"
fi

echo "wire-custom-apk-repos: done"
