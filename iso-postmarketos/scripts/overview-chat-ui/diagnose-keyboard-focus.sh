#!/bin/sh
# Diagnostic tool to investigate virtual keyboard (OSK) focus under Phosh/phoc.
set -eu

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0;0m'

log_pass() { echo "  [${GREEN}OK${NC}] $1"; }
log_fail() { echo "  [${RED}FAIL${NC}] $1"; }
log_info() { echo "  [${BLUE}INFO${NC}] $1"; }
log_warn() { echo "  [${YELLOW}WARN${NC}] $1"; }

header() {
    echo ""
    echo "=================================================="
    echo "  $1"
    echo "=================================================="
}

header "1. Probing System Keyboard and Compositor Processes"

# Check if squeekboard, stevia, or phosh-osk-stub are running
osk_found=0
for osk in squeekboard stevia phosh-osk-stub; do
    if pgrep -x "$osk" >/dev/null; then
        log_pass "Virtual keyboard process '$osk' is running."
        osk_found=1
    fi
done

if [ "$osk_found" -eq 0 ]; then
    log_warn "No running virtual keyboard (squeekboard, stevia, phosh-osk-stub) detected!"
fi

# Check if phoc (compositor) and phosh (shell) are running
if pgrep -x "phoc" >/dev/null; then
    log_pass "Compositor (phoc) is running."
else
    log_fail "Compositor (phoc) is not running!"
fi

if pgrep -x "phosh" >/dev/null; then
    log_pass "Shell (phosh) is running."
else
    log_fail "Shell (phosh) is not running!"
fi


header "2. Probing Overview Chat-UI Application State"

# Find running instances of overview-chat-ui
chat_pid=$(pgrep -f '/usr/local/bin/atomos-overview-chat-ui' 2>/dev/null | head -n1 || true)

if [ -n "$chat_pid" ]; then
    log_pass "Found running overview-chat-ui process (PID: $chat_pid)."
    
    # Read environment of the process
    if [ -r "/proc/$chat_pid/environ" ]; then
        log_info "Active environment variables for PID $chat_pid:"
        tr '\000' '\n' < "/proc/$chat_pid/environ" 2>/dev/null | grep -E '^ATOMOS_OVERVIEW_CHAT_UI_' || true
    else
        log_warn "Could not read environment of PID $chat_pid (/proc holds restricted permissions)."
    fi
else
    log_fail "overview-chat-ui is NOT running."
fi


header "3. Checking Application Logs"

log_file=""
for dir in "/run/user/$(id -u)" /run/user/*; do
    if [ -f "$dir/atomos-overview-chat-ui.log" ]; then
        log_file="$dir/atomos-overview-chat-ui.log"
        break
    fi
done

if [ -n "$log_file" ] && [ -f "$log_file" ]; then
    log_pass "Found application log at: $log_file"
    log_info "Last 15 log entries:"
    echo "--------------------------------------------------"
    tail -n 15 "$log_file"
    echo "--------------------------------------------------"
else
    log_warn "No atomos-overview-chat-ui.log found under /run/user/*."
fi


header "4. Recommended Focus & OSK Diagnosis Sequence"

echo "If the keyboard still fails to open, it typically means the compositor (phoc)"
echo "restricts or ignores 'OnDemand' keyboard mode for layer-shell surfaces on"
echo "your specific mobile shell configuration/version."
echo ""
echo "To test and confirm if 'Exclusive' keyboard mode bypasses this compositor limit,"
echo "run the following command on the device to temporarily launch with Exclusive focus:"
echo ""
echo "  ${YELLOW}killall atomos-overview-chat-ui || true${NC}"
echo "  ${YELLOW}ATOMOS_OVERVIEW_CHAT_UI_LAYER=overlay ATOMOS_OVERVIEW_CHAT_UI_KEYBOARD_MODE=exclusive /usr/local/bin/atomos-overview-chat-ui${NC}"
echo ""
echo "If Squeekboard immediately unfolds with the exclusive mode override, it confirms"
echo "the compositor's OnDemand layer focus restrictions are the root cause."
echo "=================================================="
