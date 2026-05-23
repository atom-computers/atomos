# shellcheck shell=bash
# Shared checks: vendor Phosh must include AtomOS org.atomos.PhoshHome D-Bus.
#
# Sourced by:
#   scripts/phosh/verify-vendor-phosh-build.sh
#   scripts/_lib-build-container-body.sh (after ninja install)
#   scripts/build-image.sh (host-side source contract)

atomos_phosh_src_dir() {
    printf '%s\n' "${1:-/work/iso-postmarketos/rust/phosh/phosh}"
}

atomos_verify_phosh_source_atomos_dbus() {
    local src
    src="$(atomos_phosh_src_dir "${1:-}")"
    echo "=== Verify Phosh source: org.atomos.PhoshHome ==="
    test -f "$src/meson.build"
    test -f "$src/src/dbus/org.atomos.PhoshHome.xml"
    test -f "$src/src/dbus/meson.build"
    test -f "$src/src/atomos-phosh-home-dbus.c"
    test -f "$src/src/atomos-phosh-home-dbus.h"
    grep -q 'atomos-phosh-home-dbus' "$src/src/meson.build"
    grep -q 'phosh_atomos_phosh_home_dbus_set_exported' "$src/src/shell.c"
    grep -q 'atomos_phosh_home_dbus' "$src/src/shell.c"
    grep -q 'SetFolded' "$src/src/dbus/org.atomos.PhoshHome.xml"
    grep -q 'SetUnfolded' "$src/src/dbus/org.atomos.PhoshHome.xml"
    grep -q 'Do NOT --show on unfold' "$src/src/home.c"
    echo "  ok  Phosh source includes AtomOS home D-Bus + handler lifecycle contract"
}

atomos_find_libphosh_so() {
    local root="${1:-/target}"
    find "$root/usr/lib" "$root/lib" -maxdepth 2 -name 'libphosh-*.so*' ! -name '*.a' 2>/dev/null \
        | head -n 1
}

atomos_verify_built_libphosh_has_atomos_dbus() {
    local lib="${1:-}"
    if [ -z "$lib" ] || [ ! -f "$lib" ]; then
        lib="$(atomos_find_libphosh_so /target)"
    fi
    if [ -z "$lib" ] || [ ! -f "$lib" ]; then
        lib="$(atomos_find_libphosh_so /usr)"
    fi
    if [ -z "$lib" ] || [ ! -f "$lib" ]; then
        echo "ERROR: libphosh shared library not found under /target or /usr" >&2
        return 1
    fi
    echo "=== Verify built libphosh: AtomOS D-Bus symbols ($lib) ==="
    if ! strings "$lib" | grep -q 'org.atomos.PhoshHome'; then
        echo "ERROR: $lib missing string org.atomos.PhoshHome (Phosh built without AtomOS D-Bus?)" >&2
        return 1
    fi
    if ! strings "$lib" | grep -q 'SetFolded'; then
        echo "ERROR: $lib missing SetFolded (gdbus codegen not linked?)" >&2
        return 1
    fi
    if ! strings "$lib" | grep -q 'SetUnfolded'; then
        echo "ERROR: $lib missing SetUnfolded" >&2
        return 1
    fi
    echo "  ok  $lib contains org.atomos.PhoshHome + SetFolded/SetUnfolded"
}

atomos_verify_phosh_meson_build_has_atomos_dbus() {
    local build_dir="${1:-/cache/phosh}"
    echo "=== Verify Phosh meson build: atomos-phosh-home-dbus artifacts ==="
    if [ ! -d "$build_dir" ]; then
        echo "ERROR: Phosh build directory missing: $build_dir" >&2
        return 1
    fi
    local header
    header="$(find "$build_dir" -name 'phosh-atomos-home-dbus.h' 2>/dev/null | head -n 1)"
    if [ -z "$header" ]; then
        echo "ERROR: phosh-atomos-home-dbus.h not generated (meson gdbus codegen failed?)" >&2
        return 1
    fi
    grep -q 'handle_set_folded' "$header"
    grep -q 'handle_set_unfolded' "$header"
    local obj
    obj="$(find "$build_dir" -path '*atomos-phosh-home-dbus.c.o' 2>/dev/null | head -n 1)"
    if [ -z "$obj" ]; then
        echo "WARN: atomos-phosh-home-dbus.c.o not found; full libphosh link check still required" >&2
    else
        echo "  ok  compiled $obj"
    fi
    echo "  ok  generated $header"
}
