#!/usr/bin/env bash
# =============================================================================
# AdSpace RPi Device Rename Script
# =============================================================================
# Sets a permanent, human-readable hostname for a Pi after it's installed
# at a venue. Hostname is used by Tailscale for SSH access.
#
# Usage:
#   ssh pi@<ip> "sudo bash -s <new-name>" < rename-device.sh
#
# Example:
#   ssh pi@192.168.1.50 "sudo bash -s adspace-dubai-mall-01" < rename-device.sh
#
# Naming convention:
#   adspace-{city/venue slug}-{2-digit index}
#   e.g. adspace-dubai-mall-01
#        adspace-riyadh-airport-02
#        adspace-cairo-downtown-01
#
# After rename, SSH access becomes:
#   ssh pi@adspace-dubai-mall-01   (via Tailscale)
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
log() { echo -e "${GREEN}==>${NC} $*"; }
die() { echo -e "${RED}ERROR${NC} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root: sudo bash rename-device.sh <name>"
[[ $# -ge 1 ]] || die "Usage: sudo bash rename-device.sh <new-hostname>"

NEW_NAME="$1"
OLD_NAME="$(hostname)"

# Validate: lowercase letters, numbers, hyphens only
[[ "$NEW_NAME" =~ ^[a-z0-9-]+$ ]] || die "Hostname must be lowercase letters, numbers, hyphens only"

log "Renaming $OLD_NAME → $NEW_NAME"

# Set hostname
hostnamectl set-hostname "$NEW_NAME"

# Update /etc/hosts
sed -i "s/127\.0\.1\.1\s.*$/127.0.1.1\t$NEW_NAME/" /etc/hosts
# Add if not present
grep -q "127.0.1.1" /etc/hosts || echo "127.0.1.1	$NEW_NAME" >> /etc/hosts

# Update Tailscale hostname if enrolled
if command -v tailscale &>/dev/null; then
    tailscale set --hostname "$NEW_NAME" 2>/dev/null || true
    log "Tailscale hostname updated"
fi

# Keep Beszel SYSTEM_NAME in sync (used on next registration / restart)
if [[ -f /etc/beszel/beszel-agent.env ]]; then
    if grep -q '^SYSTEM_NAME=' /etc/beszel/beszel-agent.env; then
        sed -i "s/^SYSTEM_NAME=.*/SYSTEM_NAME=$NEW_NAME/" /etc/beszel/beszel-agent.env
    else
        printf 'SYSTEM_NAME=%s\n' "$NEW_NAME" >> /etc/beszel/beszel-agent.env
    fi
    systemctl restart beszel-agent.service 2>/dev/null || true
    log "Beszel SYSTEM_NAME updated"
fi

log ""
log "────────────────────────────────────────────────────────"
log "✓  Renamed to: $NEW_NAME"
log "   Reboot for all changes to take effect:"
log "   sudo reboot"
log ""
log "   After reboot, SSH via Tailscale:"
log "   ssh pi@$NEW_NAME"
log "────────────────────────────────────────────────────────"
