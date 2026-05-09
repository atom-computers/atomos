#!/bin/sh
# scripts/_lib-greetd-guarantee-body.sh -- the in-container body of the
# "greetd guarantee" sweep. Runs as `sh /lib-greetd-guarantee-body.sh`.
#
# This is the LAST LINE OF DEFENCE against the FP4 boot loop:
#
#     ERROR: user.greetd failed to start
#
# The error has two known triggers, both repaired here:
#
#   1. greetd user/group/home missing or partial in /target/etc/{passwd,
#      group,shadow,/var/lib/greetd}. Cause: busybox adduser silently
#      no-op'd under qemu-user emulation during apk pre-install (see
#      _lib-rootfs-bootstrap.sh's pre-install warning audit). Symptom:
#      greetd.initd's start_pre runs `getent passwd greetd | cut -d: -f6`
#      to feed checkpath; with no greetd user the path is empty and
#      checkpath errors out, causing the service start to fail.
#
#   2. A stray `/etc/runlevels/default/user.greetd` symlink to
#      /etc/init.d/user pulled in from a cached rootfs or upstream
#      change. OpenRC's user-service wrapper logs "* Starting
#      user.greetd ... * ERROR: user.greetd failed to start" for that
#      service name, regardless of whether the regular `greetd` service
#      is also enabled. Remove it so only the plain `greetd` runlevel
#      link is active.
#
# This script is IDEMPOTENT: re-running it on a clean rootfs is a no-op.
# It uses direct file writes (NEVER busybox adduser/usermod), so it is
# unaffected by the qemu-user lockfile race that has plagued every
# prior fix. It also normalizes line termination on /etc/passwd /
# /etc/group / /etc/shadow before appending so a missing trailing
# newline can never concatenate the new row onto the previous one.
set -eu

PASSWD=/target/etc/passwd
GROUP=/target/etc/group
SHADOW=/target/etc/shadow

# Pure POSIX shell + busybox (awk, sed, grep, tail, od) -- DO NOT add
# python3 here. Earlier versions installed python3 with `apk add ... ||
# true`, which silently swallowed mirror-fetch failures and then
# crashed at first python3 call. Sticking to busybox-shipped tools
# means this body is unaffected by any apk-add hiccup.

# Pure awk replacement for the python "find lowest unused id in
# [LO,HI] from field 3 of a colon-separated file".
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

# Pure awk replacement for the python "append name to group's member
# list (4th colon field) if not already there". Atomic via rename.
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

# --- step 0: normalize trailing newlines so blind `>>` is safe ----------
ensure_trailing_newline() {
    f="$1"
    [ -s "$f" ] || return 0
    # POSIX-portable trailing-byte check.
    last=$(tail -c1 "$f" | od -An -c | tr -d ' \t')
    if [ "$last" != '\n' ]; then
        printf '\n' >> "$f"
        echo "  fixed: appended missing trailing newline to $f"
    fi
}
ensure_trailing_newline "$PASSWD"
ensure_trailing_newline "$GROUP"
ensure_trailing_newline "$SHADOW"

# --- step 1: scan known greetd config files for the actual session user --
# We hardcode "greetd" for the most common case but ALSO parse
# /etc/phrog/greetd-config.toml and /etc/greetd/config.toml to extract
# whatever user= they reference. Belt-and-suspenders so a phrog upstream
# rename to (say) "_greeter" wouldn't silently break us.
discover_session_users() {
    cfgs="/target/etc/phrog/greetd-config.toml /target/etc/greetd/config.toml"
    cfgd_path=$(awk -F= '/^[[:space:]]*cfgfile/{gsub(/["[:space:]]/,"",$2); print $2}' \
        /target/etc/conf.d/greetd 2>/dev/null | head -1)
    [ -n "$cfgd_path" ] && cfgs="/target${cfgd_path} $cfgs"
    found=""
    for c in $cfgs; do
        [ -f "$c" ] || continue
        u=$(awk -F= '/^[[:space:]]*user[[:space:]]*=/{gsub(/["[:space:]]/,"",$2); print $2; exit}' "$c")
        if [ -n "$u" ]; then
            case " $found " in *" $u "*) ;; *) found="$found $u" ;; esac
        fi
    done
    # Always include "greetd" -- it's what the OpenRC service start_pre
    # hardcodes (see vendor/aports/community/greetd/greetd.initd) even
    # if the TOML happens to use a different per-session user.
    case " $found " in *" greetd "*) ;; *) found="greetd $found" ;; esac
    echo "$found"
}

# --- step 2: ensure each user exists with home + group + shadow row -----
ensure_user() {
    name="$1"
    if grep -qE "^${name}:" "$PASSWD"; then
        uid=$(awk -F: -v n="$name" '$1==n{print $3; exit}' "$PASSWD")
        gid=$(awk -F: -v n="$name" '$1==n{print $4; exit}' "$PASSWD")
        : "${gid:=$uid}"
        echo "  guarantee: '$name' present in passwd (uid=$uid gid=$gid)"
    else
        uid=$(pick_id "$PASSWD")
        if grep -qE "^${name}:" "$GROUP"; then
            gid=$(awk -F: -v n="$name" '$1==n{print $3; exit}' "$GROUP")
        else
            # Pick gid independently from /etc/group. Match uid if free
            # there, otherwise next free gid -- avoids the bug where
            # uid=101 collided with an existing klogd:x:101: row.
            if ! awk -F: -v g="$uid" '$3 == g { found=1 } END { exit !found }' "$GROUP"; then
                gid="$uid"
            else
                gid=$(pick_id "$GROUP")
            fi
            printf '%s:x:%s:\n' "$name" "$gid" >> "$GROUP"
        fi
        printf '%s:x:%s:%s::%s:%s\n' "$name" "$uid" "$gid" "/var/lib/$name" "/sbin/nologin" >> "$PASSWD"
        echo "  guarantee: CREATED user '$name' (uid=$uid gid=$gid)"
    fi

    # Group row (sometimes the user exists in passwd but not group).
    if ! grep -qE "^${name}:" "$GROUP"; then
        printf '%s:x:%s:\n' "$name" "${gid:-$uid}" >> "$GROUP"
        echo "  guarantee: CREATED group '$name'"
    fi

    # Shadow row.
    if ! grep -qE "^${name}:" "$SHADOW"; then
        printf '%s:!:19000::::::\n' "$name" >> "$SHADOW"
        echo "  guarantee: CREATED shadow row for '$name' (locked)"
    fi

    # Home directory + ownership + mode (matches greetd.tmpfiles).
    home="/target/var/lib/$name"
    mkdir -p "$home"
    chown -R "$uid:${gid:-$uid}" "$home" 2>/dev/null || true
    chmod 0750 "$home" 2>/dev/null || true
    echo "  guarantee: ensured /var/lib/$name exists (mode 0750 owner=$uid:${gid:-$uid})"

    # Aux groups: greetd needs seat/video/input/render so wlroots
    # compositors can grab the seat + DRM + input devices.
    for g in seat video input render; do
        if ! grep -qE "^${g}:" "$GROUP"; then
            ggid=$(pick_id "$GROUP")
            printf '%s:x:%s:%s\n' "$g" "$ggid" "$name" >> "$GROUP"
        else
            add_to_group "$name" "$g"
        fi
    done
}

USERS=$(discover_session_users)
echo "build-fairphone4 guarantee: session users to ensure: $USERS"
for u in $USERS; do
    ensure_user "$u"
done

# --- step 3: remove stray user.<X> runlevel links -----------------------
# OpenRC's user-service wrapper convention: /etc/init.d/user.<X> is a
# symlink to /etc/init.d/user, and rc-update add user.<X> creates
# /etc/runlevels/default/user.<X> -> /etc/init.d/user.<X>. If THAT is
# in the rootfs (cached from a previous build, or pulled in by an
# upstream change) you get the exact "ERROR: user.greetd failed to
# start" countdown the user reported -- regardless of whether the
# regular `greetd` runlevel link is also there. Remove the user.<X>
# link aggressively; the regular `greetd` symlink is the right one.
for f in /target/etc/runlevels/*/user.greetd /target/etc/runlevels/*/user.* ; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    rm -f "$f"
    echo "  guarantee: removed stray runlevel link: $f"
done
for f in /target/etc/init.d/user.greetd; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    rm -f "$f"
    echo "  guarantee: removed stray init script: $f"
done

# --- step 3.5: ensure greetd runlevel link IS in default ----------------
# We use greetd+phrog (matches postmarketos-ui-phosh-openrc.post-install
# which does `rc-update add greetd default`). The wiki page describing
# tinydm is stale; current pmaports uses greetd.
#
# OPT-OUT: ATOMOS_FP4V2_DEBUG_NO_GREETD=1 suppresses the runlevel link
# AND removes any existing one. Use this when you need to SSH in
# (via usb-moded at 172.16.42.1) to debug greetd manually:
#   sudo rc-service greetd start  # watch the failure live
if [ "${ATOMOS_FP4V2_DEBUG_NO_GREETD:-0}" = "1" ]; then
    echo "  guarantee: ATOMOS_FP4V2_DEBUG_NO_GREETD=1 -- removing greetd runlevel links"
    for f in /target/etc/runlevels/*/greetd; do
        [ -e "$f" ] || [ -L "$f" ] || continue
        rm -f "$f"
        echo "  guarantee:   removed $f"
    done
elif [ -f /target/etc/init.d/greetd ] \
    && [ ! -L /target/etc/runlevels/default/greetd ] \
    && [ ! -e /target/etc/runlevels/default/greetd ]; then
    mkdir -p /target/etc/runlevels/default
    ln -sf ../../init.d/greetd /target/etc/runlevels/default/greetd
    echo "  guarantee: created runlevel link: /etc/runlevels/default/greetd -> ../../init.d/greetd"
fi
# Make sure tinydm is NOT also in default, so it doesn't race greetd
# for VT/seat. Either DM works but only ONE should run at a time.
for f in /target/etc/runlevels/*/tinydm; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    rm -f "$f"
    echo "  guarantee: removed tinydm runlevel link (using greetd instead): $f"
done

# --- step 4: validate greetd wiring (binary + PAM + config) -------------
# greetd checks pam_service_exists() and User::from_name() at startup.
# Either failure means greetd exits before writing its pidfile, OpenRC's
# command_background=yes hits its 60s timeout, and the service is
# reported as failed. Catch all of these at build time.
greetd_bin=""
for cand in /target/usr/sbin/greetd /target/usr/bin/greetd /target/sbin/greetd; do
    if [ -x "$cand" ]; then greetd_bin="$cand"; break; fi
done
if [ -z "$greetd_bin" ]; then
    echo "  FAIL: greetd binary missing in /target -- the apk install failed silently?" >&2
    ls -la /target/usr/sbin/ /target/usr/bin/ 2>/dev/null | grep -E "greet|phrog" >&2 || true
    exit 32
fi
echo "  guarantee: greetd binary: ${greetd_bin#/target}"

if [ ! -f /target/etc/pam.d/greetd ]; then
    echo "  FAIL: /etc/pam.d/greetd missing -- greetd will exit with PAM service missing" >&2
    ls -la /target/etc/pam.d/ 2>/dev/null | head -20 >&2 || true
    exit 33
fi
echo "  guarantee: greetd PAM service file present"

# /etc/conf.d/greetd should point at /etc/phrog/greetd-config.toml
# (postmarketos-ui-phosh-openrc ships this). Validate the cfgfile
# resolves to a real config with a user= the system actually has.
greetd_confd=/target/etc/conf.d/greetd
if [ ! -f "$greetd_confd" ]; then
    echo "  FAIL: /etc/conf.d/greetd missing -- postmarketos-ui-phosh-openrc did not install correctly" >&2
    exit 34
fi
cfg_path=$(awk -F= '/^[[:space:]]*cfgfile/{gsub(/["[:space:]]/,"",$2); print $2}' "$greetd_confd" | head -1)
cfg_path=${cfg_path:-/etc/greetd/config.toml}
if [ ! -f "/target${cfg_path}" ]; then
    echo "  FAIL: greetd cfgfile $cfg_path does not exist in rootfs" >&2
    ls -la /target/etc/phrog/ /target/etc/greetd/ 2>/dev/null >&2 || true
    exit 35
fi
echo "  guarantee: greetd config: $cfg_path"

# --- step 4.6: install early-boot diagnostic init service ---------------
# Real OpenRC service in the BOOT runlevel (not the default runlevel).
# It runs BEFORE tinydm / greetd / network / dbus, so the log lands
# even when default-runlevel services hang. Writes
# /var/log/atomos-dm-diag.log AND drops an MOTD pointer so SSH login
# (via USB ethernet at 172.16.42.1) surfaces the path immediately.
mkdir -p /target/var/log /target/etc/init.d /target/etc/runlevels/boot
cat > /target/etc/init.d/atomos-greetd-diag <<'DIAG_INITD'
#!/sbin/openrc-run
description="AtomOS first-boot display-manager state diagnostic"
depend() {
    need localmount
    before greetd seatd elogind dbus tinydm autologin
}
start() {
    LOG=/var/log/atomos-dm-diag.log
    ebegin "Capturing display-manager boot state to $LOG"
    {
        echo "=== atomos-dm-diag $(date) ==="
        echo "--- /etc/init.d/{tinydm,greetd,autologin,seatd,elogind} present? ---"
        for s in tinydm greetd autologin seatd elogind; do
            if [ -e "/etc/init.d/$s" ]; then echo "  ok  /etc/init.d/$s"
            else echo "  miss /etc/init.d/$s"; fi
        done
        echo "--- /etc/runlevels/default/ ---"
        ls -la /etc/runlevels/default/ 2>/dev/null
        echo "--- /etc/runlevels/boot/ ---"
        ls -la /etc/runlevels/boot/ 2>/dev/null
        echo "--- tinydm wiring ---"
        echo "  /etc/conf.d/tinydm:"
        cat /etc/conf.d/tinydm 2>/dev/null
        echo "  /etc/conf.d/autologin:"
        cat /etc/conf.d/autologin 2>/dev/null
        echo "  /var/lib/tinydm/default-session.desktop:"
        if [ -L /var/lib/tinydm/default-session.desktop ]; then
            tgt=$(readlink /var/lib/tinydm/default-session.desktop)
            echo "    -> $tgt"
            echo "    --- target Exec= ---"
            grep -E "^Exec=" "$tgt" 2>/dev/null || echo "    (no Exec= line)"
        else
            echo "    MISSING"
        fi
        echo "--- /usr/share/wayland-sessions/ ---"
        ls -la /usr/share/wayland-sessions/ 2>/dev/null
        echo "--- greetd state (should be DOWN; we use tinydm) ---"
        echo "  /etc/conf.d/greetd:"
        cat /etc/conf.d/greetd 2>/dev/null
        echo "  greetd session user (from config):"
        cfg=$(awk -F= '/^[[:space:]]*cfgfile/{gsub(/["[:space:]]/,"",$2); print $2}' /etc/conf.d/greetd 2>/dev/null | head -1)
        cfg=${cfg:-/etc/greetd/config.toml}
        if [ -f "$cfg" ]; then
            cat "$cfg"
            su=$(awk -F= '/^[[:space:]]*user[[:space:]]*=/{gsub(/["[:space:]]/,"",$2); print $2; exit}' "$cfg")
            echo "  session_user=$su"
            getent passwd "$su" 2>&1 | sed "s|^|    |"
        fi
        echo "--- getent passwd greetd / user ---"
        getent passwd greetd 2>&1
        getent passwd user 2>&1
        echo "--- /etc/init.d/user.* (should be empty) ---"
        ls -la /etc/init.d/user.* 2>/dev/null || echo "(none)"
        echo "--- /var/log/openrc.log tail ---"
        tail -80 /var/log/openrc.log 2>/dev/null
        echo "--- /var/log/messages tail ---"
        tail -120 /var/log/messages 2>/dev/null
        echo "=== end atomos-dm-diag ==="
    } > "$LOG" 2>&1
    chmod 0644 "$LOG"
    # MOTD pointer so SSH login surfaces the path immediately.
    cat > /etc/motd <<MOTD
*** AtomOS FP4 (USB ethernet ready at 172.16.42.1) ***

This image uses TINYDM + AUTOLOGIN -> PHOSH (the documented postmarketOS
Phosh boot path; greetd+phrog has been disabled). To debug:

  cat /var/log/atomos-dm-diag.log
  tail -F ~user/.local/state/tinydm.log
  sudo rc-service tinydm status
  sudo rc-service tinydm restart

To opt into greetd+phrog instead:
  sudo rc-update del tinydm
  sudo rc-update add greetd
  sudo reboot

MOTD
    eend 0
}
DIAG_INITD
chmod 0755 /target/etc/init.d/atomos-greetd-diag
ln -sf ../../init.d/atomos-greetd-diag /target/etc/runlevels/boot/atomos-greetd-diag 2>/dev/null || true
echo "  guarantee: installed /etc/init.d/atomos-greetd-diag (boot runlevel; writes /var/log/atomos-dm-diag.log)"

# --- step 5: verify with getent in chroot -------------------------------
echo "build-fairphone4 guarantee: post-sweep verification:"
for u in $USERS; do
    if chroot /target /bin/sh -c "getent passwd $u >/dev/null 2>&1"; then
        chroot /target /bin/sh -c "getent passwd $u" | sed 's/^/  ok  /'
    else
        echo "  FAIL: getent passwd $u still misses inside chroot" >&2
        echo "  /etc/passwd grep:" >&2
        grep -nE "^${u}:" "$PASSWD" >&2 || echo "    (no row)" >&2
        exit 30
    fi
done

# Also verify start_pre's exact getent line returns a non-empty homedir.
homedir=$(chroot /target /bin/sh -c "getent passwd greetd | cut -d: -f6")
if [ -z "$homedir" ]; then
    echo "  FAIL: greetd start_pre would see empty homedir; checkpath would error." >&2
    exit 31
fi
echo "  greetd start_pre input: getent passwd greetd | cut -d: -f6 = '$homedir'"

# Final dump of state for the build log.
echo "--- /etc/runlevels/default/ (greetd-relevant) ---"
ls -la /target/etc/runlevels/default/ | grep -E "(greetd|seatd|elogind|user\\.)" | sed 's/^/  /' || true
echo "--- greetd identity (chroot id) ---"
chroot /target /bin/sh -c "id greetd 2>&1" | sed 's/^/  /' || true

echo "build-fairphone4 guarantee: greetd state OK"
