# shellcheck shell=bash
# scripts/_lib-pmos-repo.sh -- postmarketOS APK mirror + signing key handling.
#
# Sourced by build-fairphone4-v2.sh. All functions are pure (no side
# effects on source); the orchestrator calls them in sequence.
#
# Required globals at call time:
#   ROOT_DIR              -- iso-postmarketos directory
#   WORK_DIR              -- per-profile work dir under build/
#   PMOS_CHANNEL          -- pmOS channel id (master|main|edge|<branch>)
#   PMOS_MIRROR           -- mirror base URL (default: https://mirror.postmarketos.org/postmarketos/)
#
# Exports on success:
#   PMOS_KEY_HOST         -- path to the vendored signing key
#   PMOS_REPO_URL         -- effective <mirror>/<branch> URL
#   REPOSITORIES_FILE     -- path to the etc_apk_repositories file we will mount

# Resolve the path to the vendored postmarketOS signing key. Hard-fails
# if the key is missing because pmOS APK index verification needs it.
atomos_pmos_resolve_key() {
    PMOS_KEY_HOST="$ROOT_DIR/pmaports/main/postmarketos-keys/build.postmarketos.org.rsa.pub"
    if [ ! -f "$PMOS_KEY_HOST" ]; then
        echo "ERROR: missing postmarketOS signing key: $PMOS_KEY_HOST" >&2
        echo "  Restore from upstream pmaports (main/postmarketos-keys/) and retry." >&2
        return 2
    fi
    export PMOS_KEY_HOST
}

# Map the pmbootstrap channel id to the matching mirror branch URL.
# pmaports/channels.cfg maps the "edge" channel to branch_pmaports=main
# (NOT master, despite the channel id), so master/main/edge all collapse
# to <mirror>/main. Anything else is taken literally.
atomos_pmos_resolve_repo_url() {
    local mirror="${PMOS_MIRROR%/}"
    case "$PMOS_CHANNEL" in
        master|main|edge) PMOS_REPO_URL="${mirror}/main" ;;
        *) PMOS_REPO_URL="${mirror}/${PMOS_CHANNEL}" ;;
    esac
    export PMOS_REPO_URL
}

# Write the etc_apk_repositories file that gets bind-mounted into the
# bootstrap container. Order: Alpine edge {main,community,testing} first
# so vanilla Alpine resolution wins, then the pmOS mirror for pmOS-only
# packages (device-fairphone-fp4, postmarketos-base, etc.).
atomos_pmos_write_repositories_file() {
    REPOSITORIES_FILE="$WORK_DIR/etc_apk_repositories"
    cat > "$REPOSITORIES_FILE" <<EOF
https://dl-cdn.alpinelinux.org/alpine/edge/main
https://dl-cdn.alpinelinux.org/alpine/edge/community
https://dl-cdn.alpinelinux.org/alpine/edge/testing
$PMOS_REPO_URL
EOF
    export REPOSITORIES_FILE
}

# One-shot: resolve key + URL + write file. Use this from the orchestrator.
atomos_pmos_setup() {
    atomos_pmos_resolve_key
    atomos_pmos_resolve_repo_url
    atomos_pmos_write_repositories_file
    echo "build-fairphone4-v2: pmOS repo: $PMOS_REPO_URL"
    echo "build-fairphone4-v2: pmOS key:  $PMOS_KEY_HOST"
    echo "build-fairphone4-v2: repos file: $REPOSITORIES_FILE"
}
