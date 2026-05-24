#!/bin/sh
# scripts/_lib-meson-cache-body.sh -- Meson/ninja helpers for the heavy
# aarch64 build container. Sourced from _lib-build-container-body.sh and
# build-qemu.sh's container script.
#
# Optional env:
#   ATOMOS_BUILD_LOG_PREFIX   log prefix (default: atomos-build)

atomos_meson_args_hash() {
    _src_dir="$1"
    shift
    # shellcheck disable=SC2124
    printf "%s\n" "$_src_dir" "CC=${CC:-}" "CXX=${CXX:-}" "AR=${AR:-}" "$@" \
        | sha256sum | cut -d" " -f1
}

# Content hash of all regular files under a source tree (sorted paths).
# Ignores .git only; build artifacts live under /cache, not in-tree.
atomos_tree_content_hash() {
    _root="$1"
    if [ ! -d "$_root" ]; then
        echo "ERROR: atomos_tree_content_hash: not a directory: $_root" >&2
        exit 1
    fi
    find "$_root" \
        \( -path "$_root/.git" -o -path "$_root/.git/*" \) -prune -o \
        -type f -print \
        | LC_ALL=C sort \
        | while IFS= read -r _f; do
            [ -n "$_f" ] || continue
            sha256sum "$_f"
        done \
        | sha256sum | cut -d" " -f1
}

meson_cache_setup() {
    _mcs_build_dir="$1"
    shift
    _mcs_src_dir="$1"
    shift
    _hash=$(atomos_meson_args_hash "$_mcs_src_dir" "$@")
    _marker="$_mcs_build_dir/.atomos-meson-args"
    _mcs_pfx="${ATOMOS_BUILD_LOG_PREFIX:-atomos-build}"
    if [ -f "$_mcs_build_dir/build.ninja" ] && [ -f "$_marker" ] \
        && [ "$(cat "$_marker" 2>/dev/null)" = "$_hash" ]; then
        echo "$_mcs_pfx: reusing meson cache: $_mcs_build_dir"
    elif [ -f "$_mcs_build_dir/build.ninja" ]; then
        echo "$_mcs_pfx: meson args changed -> reconfigure: $_mcs_build_dir"
        meson setup --reconfigure "$_mcs_build_dir" "$_mcs_src_dir" "$@"
        printf "%s" "$_hash" > "$_marker"
    else
        rm -rf "$_mcs_build_dir"
        mkdir -p "$(dirname "$_mcs_build_dir")"
        meson setup "$_mcs_build_dir" "$_mcs_src_dir" "$@"
        printf "%s" "$_hash" > "$_marker"
    fi
    unset _mcs_build_dir _mcs_src_dir _hash _marker _mcs_pfx
}

# meson setup (if needed), ninja compile unless source tree + ninja graph are
# both up to date, then install to host /usr and DESTDIR=/target.
# Usage: atomos_meson_ninja_build_install <label> <build_dir> <src_dir> [meson args...]
atomos_meson_ninja_build_install() {
    _label="$1"
    shift
    _build_dir="$1"
    shift
    _src_dir="$1"
    shift
    _pfx="${ATOMOS_BUILD_LOG_PREFIX:-atomos-build}"

    meson_cache_setup "$_build_dir" "$_src_dir" "$@"

    _args_hash=$(atomos_meson_args_hash "$_src_dir" "$@")
    _src_hash=$(atomos_tree_content_hash "$_src_dir")
    _args_marker="$_build_dir/.atomos-meson-args"
    _src_stamp="$_build_dir/.atomos-src-tree-hash"
    _ok_stamp="$_build_dir/.atomos-build-ok"

    _skip_compile=0
    if [ -f "$_build_dir/build.ninja" ] \
        && [ -f "$_args_marker" ] && [ "$(cat "$_args_marker" 2>/dev/null)" = "$_args_hash" ] \
        && [ -f "$_src_stamp" ] && [ "$(cat "$_src_stamp" 2>/dev/null)" = "$_src_hash" ] \
        && [ -f "$_ok_stamp" ]; then
        if ninja -C "$_build_dir" -n -q 2>/dev/null; then
            echo "$_pfx: $_label: unchanged source tree, skipping compile ($_build_dir)"
            _skip_compile=1
        else
            echo "$_pfx: $_label: source tree unchanged but ninja has work; compiling"
        fi
    fi

    if [ "$_skip_compile" = 0 ]; then
        ninja -C "$_build_dir"
        printf "%s" "$_src_hash" > "$_src_stamp"
        : > "$_ok_stamp"
    fi

    ninja -C "$_build_dir" install
    DESTDIR=/target ninja -C "$_build_dir" install

    unset _label _build_dir _src_dir _pfx _args_hash _src_hash
    unset _args_marker _src_stamp _ok_stamp _skip_compile
}
