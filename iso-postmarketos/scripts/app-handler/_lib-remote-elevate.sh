# shellcheck shell=bash
# Remote root elevation for SSH hotfixes (postmarketOS / Alpine).
#
# OpenDoas on Alpine only supports [-Lns]; there is no doas -S. Use doas -n when
# /etc/doas.d/99-atomos-dev.conf grants nopass for :wheel, else expect + ssh -tt.
#
# Caller must set: SSH_CMD, SCP_CMD, REMOTE_SUDO_PASSWORD, ATOMOS_DEVICE_SSH_PORT (optional)
#
#   atomos_remote_run_elevated "$SSH_TARGET" "$shell_script_body"

atomos_remote_run_elevated() {
    local target="$1" inner="$2"
    local remote_path local_path port

    if [ -z "${SSH_CMD[*]:-}" ] || [ -z "${SCP_CMD[*]:-}" ]; then
        echo "atomos_remote_run_elevated: SSH_CMD and SCP_CMD must be set" >&2
        return 1
    fi

    port="${ATOMOS_DEVICE_SSH_PORT:-22}"
    remote_path="/tmp/atomos-elevate-$$.$RANDOM.sh"
    local_path="$(mktemp "${TMPDIR:-/tmp}/atomos-elevate.XXXXXX")"
    trap 'rm -f "$local_path"' RETURN

    printf '%s\n' "$inner" >"$local_path"
    "${SCP_CMD[@]}" "$local_path" "$target:$remote_path"
    "${SSH_CMD[@]}" "$target" "chmod 0755 '$remote_path'"

    # 1) doas nopass (:wheel dev overlay or root)
    if "${SSH_CMD[@]}" "$target" "doas -n true" >/dev/null 2>&1; then
        "${SSH_CMD[@]}" "$target" "doas /bin/sh -eu '$remote_path'; rm -f '$remote_path'"
        return 0
    fi

    # 2) sudo -S
    if "${SSH_CMD[@]}" "$target" "command -v sudo >/dev/null 2>&1"; then
        "${SSH_CMD[@]}" "$target" \
            "printf '%s\n' '$REMOTE_SUDO_PASSWORD' | sudo -S -p '' -k -- /bin/sh -eu '$remote_path'; rm -f '$remote_path'"
        return 0
    fi

    # 3) doas + password over TTY via expect (OpenDoas has no -S)
    if command -v expect >/dev/null 2>&1; then
        ATOMOS_ELEVATE_TARGET="$target" \
        ATOMOS_ELEVATE_REMOTE="$remote_path" \
        ATOMOS_ELEVATE_PASS="$REMOTE_SUDO_PASSWORD" \
        ATOMOS_ELEVATE_PORT="$port" \
        expect <<'EXPECTEOF'
set timeout 120
log_user 1
set pass $env(ATOMOS_ELEVATE_PASS)
set remote_path $env(ATOMOS_ELEVATE_REMOTE)
set target $env(ATOMOS_ELEVATE_TARGET)
set port $env(ATOMOS_ELEVATE_PORT)
set ssh_opts [list -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR]
spawn sshpass -p $pass ssh -tt -p $port {*}$ssh_opts $target "doas /bin/sh -eu $remote_path"
expect {
    -re -nocase {password:} {
        send "$pass\r"
        exp_continue
    }
    eof
}
catch wait result
set exit_code [lindex $result 3]
if {$exit_code eq ""} { set exit_code 0 }
spawn sshpass -p $pass ssh -tt -p $port {*}$ssh_opts $target "rm -f $remote_path"
expect eof
exit $exit_code
EXPECTEOF
        return $?
    fi

    echo "Remote elevation failed: doas needs a TTY or nopass for :wheel." >&2
    echo "  Install expect and re-run, resync image with /etc/doas.d/99-atomos-dev.conf, or:" >&2
    echo "  ssh -tt -p $port $target 'doas /bin/sh -eu $remote_path'" >&2
    "${SSH_CMD[@]}" "$target" "rm -f '$remote_path'" || true
    return 1
}
