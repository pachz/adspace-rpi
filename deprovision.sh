#!/usr/bin/env bash
# =============================================================================
# AdSpace RPi Deprovision Script
# =============================================================================
# Undoes everything bootstrap.sh did. Use to test bootstrap on an existing
# Pi WITHOUT reflashing the SD card.
#
# Usage:
#   ssh pi@<ip> "sudo bash -s" < deprovision.sh
#
# After running this, re-trigger bootstrap:
#   ssh pi@<ip> "sudo rm -f /etc/adspace-bootstrap-done && sudo reboot"
# Or run it directly:
#   ssh pi@<ip> "sudo /opt/adspace/bootstrap.sh"
#
# WARNING: This removes all adspace config, users, and services.
#          Only use on a dev/test Pi — never on a live device.
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}==>${NC} $*"; }
warn() { echo -e "${YELLOW}WARN${NC} $*"; }

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo bash deprovision.sh"; exit 1; }

log "Stopping services..."
systemctl stop adspace-watchdog.service  2>/dev/null || true
systemctl stop adspace-kiosk.service     2>/dev/null || true
systemctl stop adspace-setup-api.service 2>/dev/null || true
systemctl stop adspace-info.service      2>/dev/null || true
systemctl stop beszel-agent.service      2>/dev/null || true
systemctl stop caddy.service             2>/dev/null || true

log "Disabling services..."
systemctl disable adspace-watchdog.service   2>/dev/null || true
systemctl disable adspace-kiosk.service      2>/dev/null || true
systemctl disable adspace-setup-api.service  2>/dev/null || true
systemctl disable adspace-info.service       2>/dev/null || true
systemctl disable adspace-bootstrap.service  2>/dev/null || true
systemctl disable beszel-agent.service       2>/dev/null || true

log "Removing systemd units..."
rm -f /etc/systemd/system/adspace-watchdog.service
rm -f /etc/systemd/system/adspace-kiosk.service
rm -f /etc/systemd/system/adspace-setup-api.service
rm -f /etc/systemd/system/adspace-info.service
rm -f /etc/systemd/system/adspace-bootstrap.service
rm -f /etc/systemd/system/beszel-agent.service
rm -f /etc/systemd/system/getty@tty1.service.d/autologin.conf
rmdir /etc/systemd/system/getty@tty1.service.d 2>/dev/null || true
systemctl daemon-reload

log "Removing /opt/adspace..."
rm -rf /opt/adspace
rm -rf /opt/beszel-agent /etc/beszel /var/lib/beszel-agent

log "Resetting Caddyfile..."
cat > /etc/caddy/Caddyfile << 'EOF'
# Default Caddyfile — restored by deprovision.sh
:80 {
    respond "Caddy is running"
}
EOF

log "Removing nmcli hotspot profile..."
nmcli con delete adspace-hotspot 2>/dev/null || true

log "Removing runtime flags and bootstrap done flag..."
rm -f /tmp/adspace-setup-mode
rm -f /tmp/adspace-wifi-scan.json
rm -f /etc/adspace-bootstrap-done

log "Removing sudoers..."
rm -f /etc/sudoers.d/aiagent /etc/sudoers.d/ai-agent 2>/dev/null || true

log "Removing aiagent user..."
userdel -r aiagent 2>/dev/null || warn "aiagent user not found or already removed"

log "Removing adspace user..."
userdel -r adspace 2>/dev/null || warn "adspace user not found or already removed"

log "Removing PAM cage config..."
rm -f /etc/pam.d/cage

log "Removing invisible cursor theme..."
rm -rf /usr/share/icons/AdspaceBlank

log "Removing sudoers entries..."
rm -f /etc/sudoers.d/adspace
rm -f /etc/sudoers.d/aiagent
rm -f /etc/sudoers.d/ai-agent 2>/dev/null || true

log "Logging out of Tailscale..."
if command -v tailscale &>/dev/null; then
    tailscale logout 2>/dev/null || true
fi
# Note: we don't uninstall Tailscale itself — bootstrap.sh skips reinstall if already present

log "Removing beszel user..."
userdel beszel 2>/dev/null || warn "beszel user not found or already removed"

log ""
log "────────────────────────────────────────────────────────"
log "✓  Deprovision complete. Pi is back to bare OS state."
log ""
log "   Re-trigger bootstrap:"
log "   ssh pi@<ip> 'sudo rm -f /etc/adspace-bootstrap-done && sudo reboot'"
log ""
log "   Or run bootstrap directly:"
log "   ssh pi@<ip> 'sudo /opt/adspace/bootstrap.sh'"
log "────────────────────────────────────────────────────────"
