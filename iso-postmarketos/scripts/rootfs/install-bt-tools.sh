#!/bin/bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <profile-env>" >&2
    exit 1
fi

PROFILE_ENV="$1"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIRECT_ROOTFS_DIR="${ROOTFS_DIR:-}"

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

PMB_HOST="$ROOT_DIR/scripts/pmb/pmb.sh"
PMB_CONTAINER="$ROOT_DIR/scripts/pmb/pmb-container.sh"
PMB="$PMB_HOST"
PROFILE_ENV_ARG="$PROFILE_ENV"
PMB_IS_CONTAINER=0
export PATH="$HOME/.local/bin:$PATH"
if [ "${PMB_USE_CONTAINER:-0}" = "1" ] || ! command -v pmbootstrap >/dev/null 2>&1; then
    PMB_IS_CONTAINER=1
    PMB="$PMB_CONTAINER"
    if [[ "$PROFILE_ENV_SOURCE" == "$ROOT_DIR/"* ]]; then
        PROFILE_ENV_ARG="${PROFILE_ENV_SOURCE#"$ROOT_DIR"/}"
    else
        PROFILE_ENV_ARG="$PROFILE_ENV_SOURCE"
    fi
fi

if [ "${ATOMOS_INSTALL_DUMP_ONLY:-0}" = "1" ]; then
    echo "would-install:badblue"
    echo "would-install:cerberusblue"
    echo "would-install:blue-deauth"
    echo "would-install:bluekit"
    echo "would-install:bluing"
    echo "would-install:whisperpair"
    echo "would-install:btle"
    echo "would-install:bleedingtooth"
    echo "would-install:bluebugger"
    echo "would-install:bluesploit"
    echo "would-install:bluespy"
    echo "would-install:btlejack"
    echo "would-install:bleeding"
    exit 0
fi

BADBLUE_SRC="$ROOT_DIR/../scripts/badblue.py"
CERBERUSBLUE_SRC="$ROOT_DIR/../scripts/Advanced-Bluetooth-Penetration-Testing-Tool/cerberusblue.py"
CERBERUSBLUE_REQ_SRC="$ROOT_DIR/../scripts/Advanced-Bluetooth-Penetration-Testing-Tool/requirements.txt"
BLUE_DEAUTH_SRC="$ROOT_DIR/../scripts/blue-deauth/blue_dos.sh"
BLUETOOLKIT_ROOT="$ROOT_DIR/../scripts/BlueToolkit"
BLUETOOLKIT_BLUEKIT_DIR="$BLUETOOLKIT_ROOT/bluekit"
BLUETOOLKIT_EXPLOITS_DIR="$BLUETOOLKIT_ROOT/exploits"
BLUETOOLKIT_HARDWARE_DIR="$BLUETOOLKIT_ROOT/hardware"
BLUING_ROOT="$ROOT_DIR/../scripts/bluing"
BLUING_SRC_DIR="$BLUING_ROOT/src"
WHISPERPAIR_ROOT="$ROOT_DIR/../scripts/CVE-2025-36911-exploit"
BTLE_ROOT="$ROOT_DIR/../scripts/BTLE"
BLEEDINGTOOTH_ROOT="$ROOT_DIR/../scripts/bleedingtooth"
BLUEBUGGER_ROOT="$ROOT_DIR/../scripts/Bluebugger"
BLUESPLOIT_ROOT="$ROOT_DIR/../scripts/bluesploit"
BLUESPY_ROOT="$ROOT_DIR/../scripts/BlueSpy"
BTLEJACK_ROOT="$ROOT_DIR/../scripts/btlejack"
BLEEDING_ROOT="$ROOT_DIR/../scripts/BLEeding"

if [ ! -f "$BADBLUE_SRC" ]; then
    echo "ERROR: badblue source script not found: $BADBLUE_SRC" >&2
    exit 1
fi
if [ ! -f "$CERBERUSBLUE_SRC" ]; then
    echo "ERROR: cerberusblue source script not found: $CERBERUSBLUE_SRC" >&2
    exit 1
fi
if [ ! -f "$CERBERUSBLUE_REQ_SRC" ]; then
    echo "ERROR: cerberusblue requirements not found: $CERBERUSBLUE_REQ_SRC" >&2
    exit 1
fi
if [ ! -f "$BLUE_DEAUTH_SRC" ]; then
    echo "ERROR: blue-deauth source script not found: $BLUE_DEAUTH_SRC" >&2
    exit 1
fi
if [ ! -d "$BLUETOOLKIT_BLUEKIT_DIR" ] || [ ! -d "$BLUETOOLKIT_EXPLOITS_DIR" ] || [ ! -d "$BLUETOOLKIT_HARDWARE_DIR" ]; then
    echo "ERROR: BlueToolkit sources missing (need bluekit/, exploits/, hardware/ under $BLUETOOLKIT_ROOT)." >&2
    exit 1
fi
if [ ! -d "$BLUING_SRC_DIR/bluing" ]; then
    echo "ERROR: bluing source package not found at $BLUING_SRC_DIR/bluing" >&2
    exit 1
fi
if [ ! -f "$WHISPERPAIR_ROOT/whisperpair-cli.py" ]; then
    echo "ERROR: whisperpair CLI not found at $WHISPERPAIR_ROOT/whisperpair-cli.py" >&2
    exit 1
fi
if [ ! -d "$BTLE_ROOT/python" ] || [ ! -d "$BTLE_ROOT/host" ]; then
    echo "ERROR: BTLE sources missing (need python/ and host/ under $BTLE_ROOT)." >&2
    exit 1
fi
if [ ! -f "$BLEEDINGTOOTH_ROOT/exploit.c" ]; then
    echo "ERROR: bleedingtooth exploit source not found at $BLEEDINGTOOTH_ROOT/exploit.c" >&2
    exit 1
fi
if [ ! -f "$BLUEBUGGER_ROOT/bluebugger.sh" ] || [ ! -f "$BLUEBUGGER_ROOT/Makefile" ]; then
    echo "ERROR: Bluebugger sources missing (need bluebugger.sh and Makefile under $BLUEBUGGER_ROOT)." >&2
    exit 1
fi
if [ ! -f "$BLUESPLOIT_ROOT/bluesploit.py" ] || [ ! -d "$BLUESPLOIT_ROOT/core" ] || [ ! -d "$BLUESPLOIT_ROOT/modules" ]; then
    echo "ERROR: Bluesploit sources missing (need bluesploit.py, core/, modules/ under $BLUESPLOIT_ROOT)." >&2
    exit 1
fi
if [ ! -f "$BLUESPY_ROOT/BlueSpy.py" ] || [ ! -f "$BLUESPY_ROOT/core.py" ] || [ ! -f "$BLUESPY_ROOT/interface.py" ]; then
    echo "ERROR: BlueSpy sources missing (need BlueSpy.py, core.py, interface.py under $BLUESPY_ROOT)." >&2
    exit 1
fi
if [ ! -f "$BTLEJACK_ROOT/btlejack/__init__.py" ] || [ ! -f "$BTLEJACK_ROOT/setup.py" ]; then
    echo "ERROR: btlejack sources missing (need btlejack/__init__.py and setup.py under $BTLEJACK_ROOT)." >&2
    exit 1
fi
if [ ! -f "$BLEEDING_ROOT/bleeding.py" ] || [ ! -f "$BLEEDING_ROOT/requirements.txt" ]; then
    echo "ERROR: BLEeding sources missing (need bleeding.py and requirements.txt under $BLEEDING_ROOT)." >&2
    exit 1
fi

if [ -n "$DIRECT_ROOTFS_DIR" ]; then
    install -d "$DIRECT_ROOTFS_DIR/usr/local/share/atomos"
    install -m 0644 "$BADBLUE_SRC" "$DIRECT_ROOTFS_DIR/usr/local/share/atomos/badblue.py"
    cat > "$DIRECT_ROOTFS_DIR/usr/local/bin/badblue" <<'EOF'
#!/bin/sh
exec python3 /usr/local/share/atomos/badblue.py "$@"
EOF
    chmod 0755 "$DIRECT_ROOTFS_DIR/usr/local/bin/badblue"
    ln -sf ../local/bin/badblue "$DIRECT_ROOTFS_DIR/usr/bin/badblue"

    install -d "$DIRECT_ROOTFS_DIR/usr/local/share/atomos/cerberusblue"
    install -m 0644 "$CERBERUSBLUE_SRC" "$DIRECT_ROOTFS_DIR/usr/local/share/atomos/cerberusblue/cerberusblue.py"
    install -m 0644 "$CERBERUSBLUE_REQ_SRC" "$DIRECT_ROOTFS_DIR/usr/local/share/atomos/cerberusblue/requirements.txt"
    cat > "$DIRECT_ROOTFS_DIR/usr/local/bin/cerberusblue" <<'EOF'
#!/bin/sh
exec python3 /usr/local/share/atomos/cerberusblue/cerberusblue.py "$@"
EOF
    chmod 0755 "$DIRECT_ROOTFS_DIR/usr/local/bin/cerberusblue"
    ln -sf ../local/bin/cerberusblue "$DIRECT_ROOTFS_DIR/usr/bin/cerberusblue"

    install -d "$DIRECT_ROOTFS_DIR/usr/local/share/atomos/blue-deauth"
    install -m 0755 "$BLUE_DEAUTH_SRC" "$DIRECT_ROOTFS_DIR/usr/local/share/atomos/blue-deauth/blue_dos.sh"
    cat > "$DIRECT_ROOTFS_DIR/usr/local/bin/blue-deauth" <<'EOF'
#!/bin/sh
exec /usr/local/share/atomos/blue-deauth/blue_dos.sh "$@"
EOF
    chmod 0755 "$DIRECT_ROOTFS_DIR/usr/local/bin/blue-deauth"
    ln -sf ../local/bin/blue-deauth "$DIRECT_ROOTFS_DIR/usr/bin/blue-deauth"

    install -d "$DIRECT_ROOTFS_DIR/usr/share/BlueToolkit"
    rm -rf "$DIRECT_ROOTFS_DIR/usr/share/BlueToolkit/bluekit" \
        "$DIRECT_ROOTFS_DIR/usr/share/BlueToolkit/exploits" \
        "$DIRECT_ROOTFS_DIR/usr/share/BlueToolkit/hardware"
    cp -a "$BLUETOOLKIT_BLUEKIT_DIR" "$DIRECT_ROOTFS_DIR/usr/share/BlueToolkit/bluekit"
    cp -a "$BLUETOOLKIT_EXPLOITS_DIR" "$DIRECT_ROOTFS_DIR/usr/share/BlueToolkit/exploits"
    cp -a "$BLUETOOLKIT_HARDWARE_DIR" "$DIRECT_ROOTFS_DIR/usr/share/BlueToolkit/hardware"
    cat > "$DIRECT_ROOTFS_DIR/usr/local/bin/bluekit" <<'EOF'
#!/bin/sh
if [ -n "${PYTHONPATH:-}" ]; then
    export PYTHONPATH="/usr/share/BlueToolkit/bluekit:$PYTHONPATH"
else
    export PYTHONPATH="/usr/share/BlueToolkit/bluekit"
fi
exec python3 -m bluekit.bluekit "$@"
EOF
    chmod 0755 "$DIRECT_ROOTFS_DIR/usr/local/bin/bluekit"
    ln -sf ../local/bin/bluekit "$DIRECT_ROOTFS_DIR/usr/bin/bluekit"

    install -d "$DIRECT_ROOTFS_DIR/usr/local/share/atomos/bluing"
    cp -a "$BLUING_SRC_DIR/bluing" "$DIRECT_ROOTFS_DIR/usr/local/share/atomos/bluing/bluing"
    for f in "$BLUING_ROOT"/setup.cfg "$BLUING_ROOT"/pyproject.toml "$BLUING_ROOT"/MANIFEST.in; do
        [ -f "$f" ] && install -m 0644 "$f" "$DIRECT_ROOTFS_DIR/usr/local/share/atomos/bluing/"
    done
    cp -a "$BLUING_ROOT/src/bluing/res" "$DIRECT_ROOTFS_DIR/usr/local/share/atomos/bluing/bluing/res" 2>/dev/null || true
    cat > "$DIRECT_ROOTFS_DIR/usr/local/bin/bluing" <<'EOF'
#!/bin/sh
if [ -n "${PYTHONPATH:-}" ]; then
    export PYTHONPATH="/usr/local/share/atomos/bluing:$PYTHONPATH"
else
    export PYTHONPATH="/usr/local/share/atomos/bluing"
fi
exec python3 -m bluing "$@"
EOF
    chmod 0755 "$DIRECT_ROOTFS_DIR/usr/local/bin/bluing"
    ln -sf ../local/bin/bluing "$DIRECT_ROOTFS_DIR/usr/bin/bluing"

    install -d "$DIRECT_ROOTFS_DIR/usr/local/share/atomos/whisperpair"
    install -m 0644 "$WHISPERPAIR_ROOT/whisperpair-cli.py" "$DIRECT_ROOTFS_DIR/usr/local/share/atomos/whisperpair/whisperpair-cli.py"
    cp -a "$WHISPERPAIR_ROOT/core" "$DIRECT_ROOTFS_DIR/usr/local/share/atomos/whisperpair/core"
    cp -a "$WHISPERPAIR_ROOT/utils" "$DIRECT_ROOTFS_DIR/usr/local/share/atomos/whisperpair/utils"
    cp -a "$WHISPERPAIR_ROOT/ui" "$DIRECT_ROOTFS_DIR/usr/local/share/atomos/whisperpair/ui"
    cat > "$DIRECT_ROOTFS_DIR/usr/local/bin/whisperpair" <<'EOF'
#!/bin/sh
exec python3 /usr/local/share/atomos/whisperpair/whisperpair-cli.py "$@"
EOF
    chmod 0755 "$DIRECT_ROOTFS_DIR/usr/local/bin/whisperpair"
    ln -sf ../local/bin/whisperpair "$DIRECT_ROOTFS_DIR/usr/bin/whisperpair"

    install -d "$DIRECT_ROOTFS_DIR/usr/local/share/atomos/btle"
    cp -a "$BTLE_ROOT/python" "$DIRECT_ROOTFS_DIR/usr/local/share/atomos/btle/python"
    cp -a "$BTLE_ROOT/host" "$DIRECT_ROOTFS_DIR/usr/local/share/atomos/btle/host"
    cat > "$DIRECT_ROOTFS_DIR/usr/local/bin/btle-python" <<'EOF'
#!/bin/sh
BTLE_DIR="/usr/local/share/atomos/btle"
if [ $# -eq 0 ]; then
    echo "Usage: btle-python <script.py> [args...]"
    echo "Available scripts in $BTLE_DIR/python/:"
    ls "$BTLE_DIR/python/"*.py 2>/dev/null | while read -r f; do basename "$f"; done
    exit 0
fi
exec python3 "$BTLE_DIR/python/$1" "${@:2}"
EOF
    chmod 0755 "$DIRECT_ROOTFS_DIR/usr/local/bin/btle-python"
    ln -sf ../local/bin/btle-python "$DIRECT_ROOTFS_DIR/usr/bin/btle-python"

    install -d "$DIRECT_ROOTFS_DIR/usr/local/share/atomos/bleedingtooth"
    install -m 0644 "$BLEEDINGTOOTH_ROOT/exploit.c" "$DIRECT_ROOTFS_DIR/usr/local/share/atomos/bleedingtooth/exploit.c"
    [ -f "$BLEEDINGTOOTH_ROOT/readme.md" ] && install -m 0644 "$BLEEDINGTOOTH_ROOT/readme.md" "$DIRECT_ROOTFS_DIR/usr/local/share/atomos/bleedingtooth/readme.md"
    [ -f "$BLEEDINGTOOTH_ROOT/writeup.md" ] && install -m 0644 "$BLEEDINGTOOTH_ROOT/writeup.md" "$DIRECT_ROOTFS_DIR/usr/local/share/atomos/bleedingtooth/writeup.md"
    cat > "$DIRECT_ROOTFS_DIR/usr/local/bin/bleedingtooth-exploit" <<'EOF'
#!/bin/sh
SRC_DIR="/usr/local/share/atomos/bleedingtooth"
SRC="$SRC_DIR/exploit.c"
BIN="$SRC_DIR/exploit"

if [ ! -x "$BIN" ] || [ "$SRC" -nt "$BIN" ]; then
    echo "[*] Building bleedingtooth exploit binary..."
    gcc -O2 -o "$BIN" "$SRC" -lbluetooth
fi

exec "$BIN" "$@"
EOF
    chmod 0755 "$DIRECT_ROOTFS_DIR/usr/local/bin/bleedingtooth-exploit"
    ln -sf ../local/bin/bleedingtooth-exploit "$DIRECT_ROOTFS_DIR/usr/bin/bleedingtooth-exploit"
    cat > "$DIRECT_ROOTFS_DIR/usr/local/bin/bleedingtooth-readme" <<'EOF'
#!/bin/sh
DOC="/usr/local/share/atomos/bleedingtooth/readme.md"
if [ -f "$DOC" ]; then
    exec sed -n '1,200p' "$DOC"
fi
echo "BleedingTooth readme not found at $DOC" >&2
exit 1
EOF
    chmod 0755 "$DIRECT_ROOTFS_DIR/usr/local/bin/bleedingtooth-readme"
    ln -sf ../local/bin/bleedingtooth-readme "$DIRECT_ROOTFS_DIR/usr/bin/bleedingtooth-readme"

    install -d "$DIRECT_ROOTFS_DIR/usr/local/share/atomos/bluebugger"
    cp -a "$BLUEBUGGER_ROOT/." "$DIRECT_ROOTFS_DIR/usr/local/share/atomos/bluebugger/"
    cat > "$DIRECT_ROOTFS_DIR/usr/local/bin/bluebugger" <<'EOF'
#!/bin/sh
APP_DIR="/usr/local/share/atomos/bluebugger"

if [ ! -x "$APP_DIR/src/bluebugger" ]; then
    echo "[*] Building bluebugger binary..."
    (cd "$APP_DIR" && make)
fi

cd "$APP_DIR"
exec bash "$APP_DIR/bluebugger.sh" "$@"
EOF
    chmod 0755 "$DIRECT_ROOTFS_DIR/usr/local/bin/bluebugger"
    ln -sf ../local/bin/bluebugger "$DIRECT_ROOTFS_DIR/usr/bin/bluebugger"

    install -d "$DIRECT_ROOTFS_DIR/usr/local/share/atomos/bluesploit"
    cp -a "$BLUESPLOIT_ROOT/." "$DIRECT_ROOTFS_DIR/usr/local/share/atomos/bluesploit/"
    cat > "$DIRECT_ROOTFS_DIR/usr/local/bin/bluesploit" <<'EOF'
#!/bin/sh
APP_DIR="/usr/local/share/atomos/bluesploit"
exec python3 "$APP_DIR/bluesploit.py" "$@"
EOF
    chmod 0755 "$DIRECT_ROOTFS_DIR/usr/local/bin/bluesploit"
    ln -sf ../local/bin/bluesploit "$DIRECT_ROOTFS_DIR/usr/bin/bluesploit"

    install -d "$DIRECT_ROOTFS_DIR/usr/local/share/atomos/bluespy"
    cp -a "$BLUESPY_ROOT/." "$DIRECT_ROOTFS_DIR/usr/local/share/atomos/bluespy/"
    cat > "$DIRECT_ROOTFS_DIR/usr/local/bin/bluespy" <<'EOF'
#!/bin/sh
APP_DIR="/usr/local/share/atomos/bluespy"
cd "$APP_DIR"
exec python3 "$APP_DIR/BlueSpy.py" "$@"
EOF
    chmod 0755 "$DIRECT_ROOTFS_DIR/usr/local/bin/bluespy"
    ln -sf ../local/bin/bluespy "$DIRECT_ROOTFS_DIR/usr/bin/bluespy"

    install -d "$DIRECT_ROOTFS_DIR/usr/local/share/atomos/btlejack"
    cp -a "$BTLEJACK_ROOT/." "$DIRECT_ROOTFS_DIR/usr/local/share/atomos/btlejack/"
    cat > "$DIRECT_ROOTFS_DIR/usr/local/bin/btlejack" <<'EOF'
#!/bin/sh
APP_DIR="/usr/local/share/atomos/btlejack"
if [ -n "${PYTHONPATH:-}" ]; then
    export PYTHONPATH="$APP_DIR:$PYTHONPATH"
else
    export PYTHONPATH="$APP_DIR"
fi
exec python3 -c 'import btlejack; btlejack.main()' "$@"
EOF
    chmod 0755 "$DIRECT_ROOTFS_DIR/usr/local/bin/btlejack"
    ln -sf ../local/bin/btlejack "$DIRECT_ROOTFS_DIR/usr/bin/btlejack"

    install -d "$DIRECT_ROOTFS_DIR/usr/local/share/atomos/bleeding"
    cp -a "$BLEEDING_ROOT/." "$DIRECT_ROOTFS_DIR/usr/local/share/atomos/bleeding/"
    cat > "$DIRECT_ROOTFS_DIR/usr/local/bin/bleeding" <<'EOF'
#!/bin/sh
APP_DIR="/usr/local/share/atomos/bleeding"
cd "$APP_DIR"
exec python3 "$APP_DIR/bleeding.py" "$@"
EOF
    chmod 0755 "$DIRECT_ROOTFS_DIR/usr/local/bin/bleeding"
    ln -sf ../local/bin/bleeding "$DIRECT_ROOTFS_DIR/usr/bin/bleeding"
    exit 0
fi

BADBLUE_PY_INSTALL_CMD='install -d /usr/local/share/atomos && cat > /usr/local/share/atomos/badblue.py && chmod 644 /usr/local/share/atomos/badblue.py'
CERBERUSBLUE_PY_INSTALL_CMD='install -d /usr/local/share/atomos/cerberusblue && cat > /usr/local/share/atomos/cerberusblue/cerberusblue.py && chmod 644 /usr/local/share/atomos/cerberusblue/cerberusblue.py'
CERBERUSBLUE_REQ_INSTALL_CMD='install -d /usr/local/share/atomos/cerberusblue && cat > /usr/local/share/atomos/cerberusblue/requirements.txt && chmod 644 /usr/local/share/atomos/cerberusblue/requirements.txt'
BLUE_DEAUTH_INSTALL_CMD='install -d /usr/local/share/atomos/blue-deauth && cat > /usr/local/share/atomos/blue-deauth/blue_dos.sh && chmod 755 /usr/local/share/atomos/blue-deauth/blue_dos.sh'
TOOLS_WRAPPER_INSTALL_CMD='install -d /usr/local/bin && printf "%s\n" "#!/bin/sh" "exec python3 /usr/local/share/atomos/badblue.py \"\$@\"" > /usr/local/bin/badblue && chmod 755 /usr/local/bin/badblue && ln -sf /usr/local/bin/badblue /usr/bin/badblue && printf "%s\n" "#!/bin/sh" "exec python3 /usr/local/share/atomos/cerberusblue/cerberusblue.py \"\$@\"" > /usr/local/bin/cerberusblue && chmod 755 /usr/local/bin/cerberusblue && ln -sf /usr/local/bin/cerberusblue /usr/bin/cerberusblue && printf "%s\n" "#!/bin/sh" "exec /usr/local/share/atomos/blue-deauth/blue_dos.sh \"\$@\"" > /usr/local/bin/blue-deauth && chmod 755 /usr/local/bin/blue-deauth && ln -sf /usr/local/bin/blue-deauth /usr/bin/blue-deauth && printf "%s\n" "#!/bin/sh" "if [ -n \"\${PYTHONPATH:-}\" ]; then export PYTHONPATH=\"/usr/share/BlueToolkit/bluekit:\$PYTHONPATH\"; else export PYTHONPATH=\"/usr/share/BlueToolkit/bluekit\"; fi" "exec python3 -m bluekit.bluekit \"\$@\"" > /usr/local/bin/bluekit && chmod 755 /usr/local/bin/bluekit && ln -sf /usr/local/bin/bluekit /usr/bin/bluekit'
BLUETOOLKIT_TREE_INSTALL_CMD='install -d /usr/share/BlueToolkit && tar -xf - -C /usr/share/BlueToolkit'
BLUING_TREE_INSTALL_CMD='install -d /usr/local/share/atomos/bluing && tar -xf - -C /usr/local/share/atomos/bluing'
BLUING_WRAPPER_INSTALL_CMD='install -d /usr/local/bin && printf "%s\n" "#!/bin/sh" "if [ -n \"\${PYTHONPATH:-}\" ]; then export PYTHONPATH=\"/usr/local/share/atomos/bluing:\$PYTHONPATH\"; else export PYTHONPATH=\"/usr/local/share/atomos/bluing\"; fi" "exec python3 -m bluing \"\$@\"" > /usr/local/bin/bluing && chmod 755 /usr/local/bin/bluing && ln -sf /usr/local/bin/bluing /usr/bin/bluing'
WHISPERPAIR_TREE_INSTALL_CMD='install -d /usr/local/share/atomos/whisperpair && tar -xf - -C /usr/local/share/atomos/whisperpair'
WHISPERPAIR_WRAPPER_INSTALL_CMD='install -d /usr/local/bin && printf "%s\n" "#!/bin/sh" "exec python3 /usr/local/share/atomos/whisperpair/whisperpair-cli.py \"\$@\"" > /usr/local/bin/whisperpair && chmod 755 /usr/local/bin/whisperpair && ln -sf /usr/local/bin/whisperpair /usr/bin/whisperpair'
BTLE_TREE_INSTALL_CMD='install -d /usr/local/share/atomos/btle && tar -xf - -C /usr/local/share/atomos/btle'
BTLE_WRAPPER_INSTALL_CMD='install -d /usr/local/bin && printf "%s\n" "#!/bin/sh" "BTLE_DIR=\"/usr/local/share/atomos/btle\"" "if [ \$# -eq 0 ]; then echo \"Usage: btle-python <script.py> [args...]\"; echo \"Available scripts in \$BTLE_DIR/python/:\"; ls \"\$BTLE_DIR/python/\"*.py 2>/dev/null | while read -r f; do basename \"\$f\"; done; exit 0; fi" "exec python3 \"\$BTLE_DIR/python/\$1\" \"\${@:2}\"" > /usr/local/bin/btle-python && chmod 755 /usr/local/bin/btle-python && ln -sf /usr/local/bin/btle-python /usr/bin/btle-python'
BLEEDINGTOOTH_TREE_INSTALL_CMD='install -d /usr/local/share/atomos/bleedingtooth && tar -xf - -C /usr/local/share/atomos/bleedingtooth'
BLEEDINGTOOTH_WRAPPER_INSTALL_CMD='install -d /usr/local/bin && printf "%s\n" "#!/bin/sh" "SRC_DIR=\"/usr/local/share/atomos/bleedingtooth\"" "SRC=\"\$SRC_DIR/exploit.c\"" "BIN=\"\$SRC_DIR/exploit\"" "if [ ! -x \"\$BIN\" ] || [ \"\$SRC\" -nt \"\$BIN\" ]; then echo \"[*] Building bleedingtooth exploit binary...\"; gcc -O2 -o \"\$BIN\" \"\$SRC\" -lbluetooth; fi" "exec \"\$BIN\" \"\$@\"" > /usr/local/bin/bleedingtooth-exploit && chmod 755 /usr/local/bin/bleedingtooth-exploit && ln -sf /usr/local/bin/bleedingtooth-exploit /usr/bin/bleedingtooth-exploit'
BLEEDINGTOOTH_README_WRAPPER_INSTALL_CMD='install -d /usr/local/bin && printf "%s\n" "#!/bin/sh" "DOC=\"/usr/local/share/atomos/bleedingtooth/readme.md\"" "if [ -f \"\$DOC\" ]; then exec sed -n '\''1,200p'\'' \"\$DOC\"; fi" "echo \"BleedingTooth readme not found at \$DOC\" >&2" "exit 1" > /usr/local/bin/bleedingtooth-readme && chmod 755 /usr/local/bin/bleedingtooth-readme && ln -sf /usr/local/bin/bleedingtooth-readme /usr/bin/bleedingtooth-readme'
BLUEBUGGER_TREE_INSTALL_CMD='install -d /usr/local/share/atomos/bluebugger && tar -xf - -C /usr/local/share/atomos/bluebugger'
BLUEBUGGER_WRAPPER_INSTALL_CMD='install -d /usr/local/bin && printf "%s\n" "#!/bin/sh" "APP_DIR=\"/usr/local/share/atomos/bluebugger\"" "if [ ! -x \"\$APP_DIR/src/bluebugger\" ]; then echo \"[*] Building bluebugger binary...\"; (cd \"\$APP_DIR\" && make); fi" "cd \"\$APP_DIR\"" "exec bash \"\$APP_DIR/bluebugger.sh\" \"\$@\"" > /usr/local/bin/bluebugger && chmod 755 /usr/local/bin/bluebugger && ln -sf /usr/local/bin/bluebugger /usr/bin/bluebugger'
BLUESPLOIT_TREE_INSTALL_CMD='install -d /usr/local/share/atomos/bluesploit && tar -xf - -C /usr/local/share/atomos/bluesploit'
BLUESPLOIT_WRAPPER_INSTALL_CMD='install -d /usr/local/bin && printf "%s\n" "#!/bin/sh" "APP_DIR=\"/usr/local/share/atomos/bluesploit\"" "exec python3 \"\$APP_DIR/bluesploit.py\" \"\$@\"" > /usr/local/bin/bluesploit && chmod 755 /usr/local/bin/bluesploit && ln -sf /usr/local/bin/bluesploit /usr/bin/bluesploit'
BLUESPY_TREE_INSTALL_CMD='install -d /usr/local/share/atomos/bluespy && tar -xf - -C /usr/local/share/atomos/bluespy'
BLUESPY_WRAPPER_INSTALL_CMD='install -d /usr/local/bin && printf "%s\n" "#!/bin/sh" "APP_DIR=\"/usr/local/share/atomos/bluespy\"" "cd \"\$APP_DIR\"" "exec python3 \"\$APP_DIR/BlueSpy.py\" \"\$@\"" > /usr/local/bin/bluespy && chmod 755 /usr/local/bin/bluespy && ln -sf /usr/local/bin/bluespy /usr/bin/bluespy'
BTLEJACK_TREE_INSTALL_CMD='install -d /usr/local/share/atomos/btlejack && tar -xf - -C /usr/local/share/atomos/btlejack'
BTLEJACK_WRAPPER_INSTALL_CMD='install -d /usr/local/bin && printf "%s\n" "#!/bin/sh" "APP_DIR=\"/usr/local/share/atomos/btlejack\"" "if [ -n \"\${PYTHONPATH:-}\" ]; then export PYTHONPATH=\"\$APP_DIR:\$PYTHONPATH\"; else export PYTHONPATH=\"\$APP_DIR\"; fi" "exec python3 -c '\''import btlejack; btlejack.main()'\'' \"\$@\"" > /usr/local/bin/btlejack && chmod 755 /usr/local/bin/btlejack && ln -sf /usr/local/bin/btlejack /usr/bin/btlejack'
BLEEDING_TREE_INSTALL_CMD='install -d /usr/local/share/atomos/bleeding && tar -xf - -C /usr/local/share/atomos/bleeding'
BLEEDING_WRAPPER_INSTALL_CMD='install -d /usr/local/bin && printf "%s\n" "#!/bin/sh" "APP_DIR=\"/usr/local/share/atomos/bleeding\"" "cd \"\$APP_DIR\"" "exec python3 \"\$APP_DIR/bleeding.py\" \"\$@\"" > /usr/local/bin/bleeding && chmod 755 /usr/local/bin/bleeding && ln -sf /usr/local/bin/bleeding /usr/bin/bleeding'
DEPENDENCY_INSTALL_CMD='for pkg in python3 py3-pip bluez bluez-deprecated bluez-hcidump rfkill figlet android-tools-adb git py3-cairo py3-dbus py3-gobject3 py3-serial dbus-dev libbluetooth-dev bluez-dev cmake py3-numpy build-base pipewire wireplumber; do apk add --no-interactive --quiet "$pkg" >/dev/null 2>&1 || apk add --no-interactive "$pkg" >/dev/null 2>&1 || echo "WARN: apk package unavailable: $pkg" >&2; done; if command -v python3 >/dev/null 2>&1 && python3 -m pip --version >/dev/null 2>&1; then python3 -m pip install --no-cache-dir rich requests pybluez tabulate colorama tqdm pyyaml psutil >/dev/null 2>&1 || echo "WARN: pip install for core Python deps failed" >&2; python3 -m pip install --no-cache-dir "pybtool @ git+https://github.com/sacca97/pybtool.git#egg=main" >/dev/null 2>&1 || echo "WARN: pip install for pybtool failed" >&2; python3 -m pip install --no-cache-dir docopt bluepy halo pyserial xpycommon bthci btsm btatt btgatt >/dev/null 2>&1 || echo "WARN: pip install for bluing Python deps failed" >&2; python3 -m pip install --no-cache-dir bleak cryptography >/dev/null 2>&1 || echo "WARN: pip install for whisperpair Python deps failed" >&2; python3 -m pip install --no-cache-dir pybluez2 scapy cmd2 asyncio-dgram >/dev/null 2>&1 || echo "WARN: pip install for bluesploit Python deps failed" >&2; python3 -m pip install --no-cache-dir btlejack >/dev/null 2>&1 || echo "WARN: pip install for btlejack Python deps failed" >&2; python3 -m pip install --no-cache-dir click colorama pybluez bleak >/dev/null 2>&1 || echo "WARN: pip install for bleeding Python deps failed" >&2; fi'

echo "Installing additional Bluetooth tools into pmbootstrap rootfs..."
if [ "$PMB_IS_CONTAINER" = "1" ]; then
    PMB_CONTAINER_AS_ROOT=1 bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$BADBLUE_PY_INSTALL_CMD" < "$BADBLUE_SRC"
    PMB_CONTAINER_AS_ROOT=1 bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$CERBERUSBLUE_PY_INSTALL_CMD" < "$CERBERUSBLUE_SRC"
    PMB_CONTAINER_AS_ROOT=1 bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$CERBERUSBLUE_REQ_INSTALL_CMD" < "$CERBERUSBLUE_REQ_SRC"
    PMB_CONTAINER_AS_ROOT=1 bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$BLUE_DEAUTH_INSTALL_CMD" < "$BLUE_DEAUTH_SRC"
    tar -C "$BLUETOOLKIT_ROOT" -cf - bluekit exploits hardware | PMB_CONTAINER_AS_ROOT=1 bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$BLUETOOLKIT_TREE_INSTALL_CMD"
    tar -C "$BLUING_SRC_DIR" -cf - bluing | PMB_CONTAINER_AS_ROOT=1 bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$BLUING_TREE_INSTALL_CMD"
    tar -C "$WHISPERPAIR_ROOT" -cf - whisperpair-cli.py core utils ui | PMB_CONTAINER_AS_ROOT=1 bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$WHISPERPAIR_TREE_INSTALL_CMD"
    tar -C "$BTLE_ROOT" -cf - python host | PMB_CONTAINER_AS_ROOT=1 bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$BTLE_TREE_INSTALL_CMD"
    tar -C "$BLEEDINGTOOTH_ROOT" -cf - exploit.c readme.md writeup.md | PMB_CONTAINER_AS_ROOT=1 bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$BLEEDINGTOOTH_TREE_INSTALL_CMD"
    tar -C "$BLUEBUGGER_ROOT" -cf - . | PMB_CONTAINER_AS_ROOT=1 bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$BLUEBUGGER_TREE_INSTALL_CMD"
    tar -C "$BLUESPLOIT_ROOT" -cf - . | PMB_CONTAINER_AS_ROOT=1 bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$BLUESPLOIT_TREE_INSTALL_CMD"
    tar -C "$BLUESPY_ROOT" -cf - . | PMB_CONTAINER_AS_ROOT=1 bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$BLUESPY_TREE_INSTALL_CMD"
    tar -C "$BTLEJACK_ROOT" -cf - . | PMB_CONTAINER_AS_ROOT=1 bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$BTLEJACK_TREE_INSTALL_CMD"
    tar -C "$BLEEDING_ROOT" -cf - . | PMB_CONTAINER_AS_ROOT=1 bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$BLEEDING_TREE_INSTALL_CMD"
    PMB_CONTAINER_AS_ROOT=1 bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$TOOLS_WRAPPER_INSTALL_CMD"
    PMB_CONTAINER_AS_ROOT=1 bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$BLUING_WRAPPER_INSTALL_CMD"
    PMB_CONTAINER_AS_ROOT=1 bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$WHISPERPAIR_WRAPPER_INSTALL_CMD"
    PMB_CONTAINER_AS_ROOT=1 bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$BTLE_WRAPPER_INSTALL_CMD"
    PMB_CONTAINER_AS_ROOT=1 bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$BLEEDINGTOOTH_WRAPPER_INSTALL_CMD"
    PMB_CONTAINER_AS_ROOT=1 bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$BLEEDINGTOOTH_README_WRAPPER_INSTALL_CMD"
    PMB_CONTAINER_AS_ROOT=1 bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$BLUEBUGGER_WRAPPER_INSTALL_CMD"
    PMB_CONTAINER_AS_ROOT=1 bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$BLUESPLOIT_WRAPPER_INSTALL_CMD"
    PMB_CONTAINER_AS_ROOT=1 bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$BLUESPY_WRAPPER_INSTALL_CMD"
    PMB_CONTAINER_AS_ROOT=1 bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$BTLEJACK_WRAPPER_INSTALL_CMD"
    PMB_CONTAINER_AS_ROOT=1 bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$BLEEDING_WRAPPER_INSTALL_CMD"
    PMB_CONTAINER_AS_ROOT=1 bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$DEPENDENCY_INSTALL_CMD"
else
    bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$BADBLUE_PY_INSTALL_CMD" < "$BADBLUE_SRC"
    bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$CERBERUSBLUE_PY_INSTALL_CMD" < "$CERBERUSBLUE_SRC"
    bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$CERBERUSBLUE_REQ_INSTALL_CMD" < "$CERBERUSBLUE_REQ_SRC"
    bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$BLUE_DEAUTH_INSTALL_CMD" < "$BLUE_DEAUTH_SRC"
    tar -C "$BLUETOOLKIT_ROOT" -cf - bluekit exploits hardware | bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$BLUETOOLKIT_TREE_INSTALL_CMD"
    tar -C "$BLUING_SRC_DIR" -cf - bluing | bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$BLUING_TREE_INSTALL_CMD"
    tar -C "$WHISPERPAIR_ROOT" -cf - whisperpair-cli.py core utils ui | bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$WHISPERPAIR_TREE_INSTALL_CMD"
    tar -C "$BTLE_ROOT" -cf - python host | bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$BTLE_TREE_INSTALL_CMD"
    tar -C "$BLEEDINGTOOTH_ROOT" -cf - exploit.c readme.md writeup.md | bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$BLEEDINGTOOTH_TREE_INSTALL_CMD"
    tar -C "$BLUEBUGGER_ROOT" -cf - . | bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$BLUEBUGGER_TREE_INSTALL_CMD"
    tar -C "$BLUESPLOIT_ROOT" -cf - . | bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$BLUESPLOIT_TREE_INSTALL_CMD"
    tar -C "$BLUESPY_ROOT" -cf - . | bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$BLUESPY_TREE_INSTALL_CMD"
    tar -C "$BTLEJACK_ROOT" -cf - . | bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$BTLEJACK_TREE_INSTALL_CMD"
    tar -C "$BLEEDING_ROOT" -cf - . | bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$BLEEDING_TREE_INSTALL_CMD"
    bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$TOOLS_WRAPPER_INSTALL_CMD"
    bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$BLUING_WRAPPER_INSTALL_CMD"
    bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$WHISPERPAIR_WRAPPER_INSTALL_CMD"
    bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$BTLE_WRAPPER_INSTALL_CMD"
    bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$BLEEDINGTOOTH_WRAPPER_INSTALL_CMD"
    bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$BLEEDINGTOOTH_README_WRAPPER_INSTALL_CMD"
    bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$BLUEBUGGER_WRAPPER_INSTALL_CMD"
    bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$BLUESPLOIT_WRAPPER_INSTALL_CMD"
    bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$BLUESPY_WRAPPER_INSTALL_CMD"
    bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$BTLEJACK_WRAPPER_INSTALL_CMD"
    bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$BLEEDING_WRAPPER_INSTALL_CMD"
    bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$DEPENDENCY_INSTALL_CMD"
fi

VERIFY_BADBLUE_CMD='test -s /usr/local/share/atomos/badblue.py && test -x /usr/local/bin/badblue && test -x /usr/bin/badblue'
VERIFY_EXTRA_TOOLS_CMD='test -s /usr/local/share/atomos/cerberusblue/cerberusblue.py && test -x /usr/local/bin/cerberusblue && test -x /usr/bin/cerberusblue && test -x /usr/local/share/atomos/blue-deauth/blue_dos.sh && test -x /usr/local/bin/blue-deauth && test -x /usr/bin/blue-deauth && test -x /usr/local/bin/bluekit && test -x /usr/bin/bluekit && test -d /usr/share/BlueToolkit/bluekit && test -d /usr/share/BlueToolkit/exploits && test -d /usr/share/BlueToolkit/hardware && test -d /usr/local/share/atomos/bluing/bluing && test -x /usr/local/bin/bluing && test -x /usr/bin/bluing && test -s /usr/local/share/atomos/whisperpair/whisperpair-cli.py && test -x /usr/local/bin/whisperpair && test -x /usr/bin/whisperpair && test -d /usr/local/share/atomos/btle/python && test -d /usr/local/share/atomos/btle/host && test -x /usr/local/bin/btle-python && test -x /usr/bin/btle-python && test -s /usr/local/share/atomos/bleedingtooth/exploit.c && test -x /usr/local/bin/bleedingtooth-exploit && test -x /usr/bin/bleedingtooth-exploit && test -x /usr/local/bin/bleedingtooth-readme && test -x /usr/bin/bleedingtooth-readme && test -f /usr/local/share/atomos/bluebugger/bluebugger.sh && test -x /usr/local/bin/bluebugger && test -x /usr/bin/bluebugger && test -f /usr/local/share/atomos/bluesploit/bluesploit.py && test -x /usr/local/bin/bluesploit && test -x /usr/bin/bluesploit && test -f /usr/local/share/atomos/bluespy/BlueSpy.py && test -x /usr/local/bin/bluespy && test -x /usr/bin/bluespy && test -f /usr/local/share/atomos/btlejack/btlejack/__init__.py && test -x /usr/local/bin/btlejack && test -x /usr/bin/btlejack && test -f /usr/local/share/atomos/bleeding/bleeding.py && test -x /usr/local/bin/bleeding && test -x /usr/bin/bleeding'
if [ "$PMB_IS_CONTAINER" = "1" ]; then
    PMB_CONTAINER_AS_ROOT=1 bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$VERIFY_BADBLUE_CMD"
    PMB_CONTAINER_AS_ROOT=1 bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$VERIFY_EXTRA_TOOLS_CMD"
else
    bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$VERIFY_BADBLUE_CMD"
    bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$VERIFY_EXTRA_TOOLS_CMD"
fi

echo "Installed badblue launcher at /usr/local/bin/badblue."
echo "Installed cerberusblue launcher at /usr/local/bin/cerberusblue."
echo "Installed blue-deauth launcher at /usr/local/bin/blue-deauth."
echo "Installed bluekit launcher at /usr/local/bin/bluekit."
echo "Installed bluing launcher at /usr/local/bin/bluing."
echo "Installed whisperpair launcher at /usr/local/bin/whisperpair."
echo "Installed btle-python launcher at /usr/local/bin/btle-python."
echo "  BTLE C tools (btle_tx/btle_rx) source at /usr/local/share/atomos/btle/host/ — build on-device with cmake."
echo "Installed bleedingtooth-exploit launcher at /usr/local/bin/bleedingtooth-exploit."
echo "Installed bleedingtooth-readme launcher at /usr/local/bin/bleedingtooth-readme."
echo "  BleedingTooth source at /usr/local/share/atomos/bleedingtooth/ (build occurs on first run)."
echo "Installed bluebugger launcher at /usr/local/bin/bluebugger."
echo "  Bluebugger source at /usr/local/share/atomos/bluebugger/ (build occurs on first run)."
echo "Installed bluesploit launcher at /usr/local/bin/bluesploit."
echo "  Bluesploit source at /usr/local/share/atomos/bluesploit/."
echo "Installed bluespy launcher at /usr/local/bin/bluespy."
echo "  BlueSpy source at /usr/local/share/atomos/bluespy/."
echo "Installed btlejack launcher at /usr/local/bin/btlejack."
echo "  btlejack source at /usr/local/share/atomos/btlejack/."
echo "Installed bleeding launcher at /usr/local/bin/bleeding."
echo "  BLEeding source at /usr/local/share/atomos/bleeding/."
