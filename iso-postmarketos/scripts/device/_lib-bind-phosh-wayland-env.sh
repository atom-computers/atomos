# shellcheck shell=sh
# Shared helper: import Wayland session env from the logged-in phosh process,
# with fallbacks when /proc/$pid/environ is unreadable (hidepid, wrong pgrep match).

bind_phosh_wayland_env() {
    uid="$(id -u 2>/dev/null || true)"
    runtime=""
    if [ -n "$uid" ] && [ -d "/run/user/$uid" ]; then
        runtime="/run/user/$uid"
        export XDG_RUNTIME_DIR="$runtime"
    fi

    if command -v pgrep >/dev/null 2>&1; then
        # Prefer same-UID phosh; avoid matching unrelated root helpers.
        for pid in $(pgrep -u "$uid" -x phosh 2>/dev/null || true) \
                   $(pgrep -u "$uid" phosh 2>/dev/null || true); do
            [ -n "$pid" ] || continue
            [ -r "/proc/$pid/environ" ] || continue
            for v in WAYLAND_DISPLAY XDG_RUNTIME_DIR DISPLAY DBUS_SESSION_BUS_ADDRESS; do
                cur=""
                case "$v" in
                    WAYLAND_DISPLAY) cur="${WAYLAND_DISPLAY:-}" ;;
                    XDG_RUNTIME_DIR) cur="${XDG_RUNTIME_DIR:-}" ;;
                    DISPLAY) cur="${DISPLAY:-}" ;;
                    DBUS_SESSION_BUS_ADDRESS) cur="${DBUS_SESSION_BUS_ADDRESS:-}" ;;
                esac
                if [ -z "$cur" ]; then
                    line="$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null \
                        | awk -F= -v k="$v" '$1 == k { print; exit }' || true)"
                    [ -n "$line" ] && export "$line"
                fi
            done
            [ -n "${WAYLAND_DISPLAY:-}" ] && break
        done
    fi

    if [ -z "${XDG_RUNTIME_DIR:-}" ] && [ -n "$runtime" ]; then
        export XDG_RUNTIME_DIR="$runtime"
    fi
    if [ -z "${WAYLAND_DISPLAY:-}" ] && [ -n "${XDG_RUNTIME_DIR:-}" ]; then
        for wl in wayland-1 wayland-0; do
            if [ -S "${XDG_RUNTIME_DIR}/${wl}" ]; then
                export WAYLAND_DISPLAY="$wl"
                break
            fi
        done
    fi
}
