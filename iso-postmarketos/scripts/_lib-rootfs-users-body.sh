#!/bin/sh
# scripts/_lib-rootfs-users-body.sh -- the in-container companion to
# _lib-rootfs-users.sh. Bind-mounted at
# /lib-users-body.sh and run as
# `sh /lib-users-body.sh` from the host wrapper.
#
# Why a separate file: nesting a python heredoc inside a shell heredoc
# inside a single-quoted host bash string was the worst part of the
# original build-fairphone4.sh. Extracting this lets sh -n catch
# syntax errors directly and makes the user-creation logic legible.
#
# Required env (set by the caller):
#   PMOS_USER_UID
#   INSTALL_PASSWORD
set -eu

# Install only what we need + DON'T mask failures. Earlier versions
# of this script masked apk add failures with `|| true` and then
# crashed with "python3: not found" on a transient mirror miss --
# noisy fail is better than silent crash. We deliberately use ONLY
# busybox-shipped tools (awk, sed, grep) for the rest of the script
# so a missing apk install of openssl is the only thing that can
# stop us, and that is needed only for the login user's password.
apk add --no-cache openssl >/dev/null 2>&1 \
    || apk update >/dev/null && apk add --no-cache openssl >/dev/null
command -v openssl >/dev/null || {
    echo "ERROR: failed to install openssl in alpine container; cannot hash login password" >&2
    exit 40
}

PASSWD=/target/etc/passwd
GROUP=/target/etc/group
SHADOW=/target/etc/shadow

# Pick the lowest unused id in [LO,HI] from the third colon-separated
# field of the named file. Pure awk -- no python required.
pick_id() {
    _f=$1; _lo=${2:-100}; _hi=${3:-499}
    awk -F: -v lo="$_lo" -v hi="$_hi" '
        $3 ~ /^[0-9]+$/ { used[$3] = 1 }
        END {
            for (u = lo; u <= hi; u++)
                if (!(u in used)) { print u; exit }
        }
    ' "$_f"
    unset _f _lo _hi
}

# Append $1 to $2's member list (4th colon field) if not already
# there. Idempotent. Pure awk + atomic rename, no python.
add_to_group() {
    _name=$1; _group=$2
    awk -F: -v OFS=: -v g="$_group" -v n="$_name" '
        $1 == g {
            split($4, arr, ",")
            found = 0
            for (i in arr) if (arr[i] == n) found = 1
            if (!found) {
                if ($4 == "") $4 = n
                else $4 = $4 "," n
            }
        }
        { print }
    ' "$GROUP" > "$GROUP.new"
    mv "$GROUP.new" "$GROUP"
    unset _name _group
}

# Auto-create a group if missing, then ensure the named user is a member.
ensure_group_with_member() {
    name="$1"; group="$2"
    if ! grep -qE "^${group}:" "$GROUP"; then
        ggid=$(pick_id "$GROUP")
        printf "%s:x:%s:%s\n" "$group" "$ggid" "$name" >> "$GROUP"
    else
        add_to_group "$name" "$group"
    fi
}

# Ensure a system user (uid<1000) named $1 exists with home $2, shell $3,
# and is a member of the (space-separated) groups in $4.
ensure_sysuser() {
    name=$1; home=$2; shell=$3; aux=$4
    if grep -qE "^${name}:" "$PASSWD"; then
        # User already present (greetd's apk pre-install ran cleanly
        # this run -- no qemu-user lockfile race). Pull both uid and
        # the recorded primary gid out of /etc/passwd so the chown
        # below has both halves under `set -u`.
        uid=$(awk -F: -v n="$name" '$1==n{print $3; exit}' "$PASSWD")
        gid=$(awk -F: -v n="$name" '$1==n{print $4; exit}' "$PASSWD")
        # Defensive: if the passwd row is somehow missing field 4,
        # fall back to gid==uid (matches what we would have written
        # ourselves on a clean create).
        : "${gid:=$uid}"
        echo "  user '$name' present (uid=$uid gid=$gid)"
        # Ensure the matching group row also exists. If apk pre-install
        # wrote /etc/passwd but a parallel write to /etc/group lost the
        # row, this re-creates it with the same numeric gid.
        if ! grep -qE "^${name}:" "$GROUP"; then
            printf "%s:x:%s:\n" "$name" "$gid" >> "$GROUP"
            echo "  REPAIRED missing group row for $name (gid=$gid)"
        fi
        # Ensure shadow row too -- locked, since system users do not log in.
        if ! grep -qE "^${name}:" "$SHADOW"; then
            printf "%s:!:19000::::::\n" "$name" >> "$SHADOW"
            echo "  REPAIRED missing shadow row for $name"
        fi
    else
        uid=$(pick_id "$PASSWD")
        if grep -qE "^${name}:" "$GROUP"; then
            # Group already exists with that name -- reuse its gid.
            gid=$(awk -F: -v n="$name" '$1==n{print $3; exit}' "$GROUP")
        else
            # Pick gid independently from /etc/group. If our chosen uid
            # happens to also be free in /etc/group we prefer matching
            # (Alpine convention for system users), otherwise use the
            # next free gid. This avoids the bug where we picked
            # uid=101 and forced gid=101 even though klogd was already
            # at gid 101 -> two rows at the same gid -> getent group <gid>
            # returns klogd, not greetd.
            if ! awk -F: -v g="$uid" '$3 == g { found=1 } END { exit !found }' "$GROUP"; then
                gid="$uid"
            else
                gid=$(pick_id "$GROUP")
                # Edge case: $uid happens to be the only free *id* in
                # /etc/group too (very rare); pick_id then returns the
                # same number. That is fine -- $uid is free in /etc/group
                # by definition (the awk above only takes this branch
                # when $uid is taken in /etc/group), so pick_id will
                # return something else.
            fi
            printf "%s:x:%s:\n" "$name" "$gid" >> "$GROUP"
        fi
        printf "%s:x:%s:%s::%s:%s\n" "$name" "$uid" "$gid" "$home" "$shell" >> "$PASSWD"
        printf "%s:!:19000::::::\n" "$name" >> "$SHADOW"
        echo "  CREATED system user $name (uid=$uid gid=$gid home=$home)"
    fi

    mkdir -p "/target$home"
    chown -R "$uid:${gid:-$uid}" "/target$home" 2>/dev/null || true
    chmod 0750 "/target$home" 2>/dev/null || true

    for g in $aux; do
        ensure_group_with_member "$name" "$g"
    done
}

# Ensure an unprivileged login user with the given uid + password.
ensure_login() {
    name=$1; uid=$2; password=$3; home=$4; aux=$5

    if ! grep -qE "^${name}:" "$PASSWD"; then
        if ! grep -qE "^${name}:" "$GROUP"; then
            printf "%s:x:%s:\n" "$name" "$uid" >> "$GROUP"
        fi
        printf "%s:x:%s:%s:AtomOS User:%s:/bin/bash\n" "$name" "$uid" "$uid" "$home" >> "$PASSWD"
    fi

    hash=$(openssl passwd -6 "$password" 2>/dev/null || true)
    if [ -z "$hash" ]; then
        hash=$(echo "$password" | mkpasswd -s -m sha-512 2>/dev/null || true)
    fi
    if [ -z "$hash" ]; then
        echo "ERROR: could not hash password for $name" >&2
        return 1
    fi
    awk -F: -v r="root" -v u="$name" -v h="$hash" \
        'BEGIN{OFS=":"} {if($1==r){$2=h} if($1==u){$2=h} print}' \
        "$SHADOW" > "$SHADOW.new"
    grep -qE "^${name}:" "$SHADOW.new" \
        || printf "%s:%s:19000:0:99999:7:::\n" "$name" "$hash" >> "$SHADOW.new"
    mv "$SHADOW.new" "$SHADOW"

    mkdir -p "/target$home/.config"
    {
        printf "export XDG_RUNTIME_DIR=/run/user/%s\n" "$uid"
        printf "export XDG_SESSION_TYPE=wayland\n"
        printf "export XDG_CURRENT_DESKTOP=Phosh:GNOME\n"
        printf "export WAYLAND_DISPLAY=wayland-0\n"
    } > "/target$home/.bash_profile"
    chown -R "$uid:$uid" "/target$home" 2>/dev/null || true

    for g in $aux; do
        ensure_group_with_member "$name" "$g"
    done

    mkdir -p "/target/run/user/$uid"
    chmod 700 "/target/run/user/$uid"
}

echo "-> ensure_sysuser greetd"
ensure_sysuser greetd /var/lib/greetd /sbin/nologin "seat video input render"

echo "-> ensure_login user (uid=$PMOS_USER_UID)"
ensure_login user "$PMOS_USER_UID" "$INSTALL_PASSWORD" /home/user \
    "wheel video render audio input plugdev seat netdev dialout bluetooth feedbackd"
