#!/usr/bin/env bash
# =============================================================================
# AdSpace RPi — Beszel agent installer
# =============================================================================
# Downloads the official arm64/amd64 binary, writes a systemd unit, and
# registers with the hub over an outbound WebSocket (no inbound SSH).
#
# Credentials (all three required):
#   BESZEL_HUB_URL   Hub URL, e.g. https://beszel.example.com
#   BESZEL_KEY       Hub public key from Add System / Settings → Tokens
#   BESZEL_TOKEN     Universal token from Hub → Settings → Tokens
#
# Source order if env vars are unset:
#   /boot/firmware/adspace-beszel.env
#   /boot/adspace-beszel.env
#   /tmp/adspace-beszel.env
#
# Usage:
#   sudo BESZEL_HUB_URL=... BESZEL_KEY=... BESZEL_TOKEN=... ./install-beszel.sh
#   sudo ./install-beszel.sh          # after baking adspace-beszel.env
#   make deploy-beszel PI_SSH=pi@adspace-{serial}
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[beszel]${NC} $*"; }
warn() { echo -e "${YELLOW}[beszel]${NC} $*" >&2; }
die()  { echo -e "${RED}[beszel]${NC} ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Must run as root"

if [[ -z "${BESZEL_HUB_URL:-}" || -z "${BESZEL_KEY:-}" || -z "${BESZEL_TOKEN:-}" ]]; then
    for _f in /boot/firmware/adspace-beszel.env /boot/adspace-beszel.env /tmp/adspace-beszel.env; do
        [[ -f "$_f" ]] || continue
        # shellcheck disable=SC1090
        source "$_f"
        break
    done
fi

[[ -n "${BESZEL_HUB_URL:-}" && -n "${BESZEL_KEY:-}" && -n "${BESZEL_TOKEN:-}" ]] \
    || die "Need BESZEL_HUB_URL, BESZEL_KEY, and BESZEL_TOKEN"
[[ "$BESZEL_HUB_URL" =~ ^https?://[^[:space:]]+$ ]] \
    || die "Invalid BESZEL_HUB_URL: $BESZEL_HUB_URL"

SYSTEM_NAME="$(hostname)"
[[ -n "$SYSTEM_NAME" ]] || die "Could not determine hostname for SYSTEM_NAME"

os=$(uname -s | tr '[:upper:]' '[:lower:]')
arch=$(uname -m | sed -e 's/x86_64/amd64/' -e 's/armv6l/arm/' -e 's/armv7l/arm/' -e 's/aarch64/arm64/')
ASSET="beszel-agent_${os}_${arch}.tar.gz"
URL="https://github.com/henrygd/beszel/releases/latest/download/${ASSET}"

if ! id -u beszel >/dev/null 2>&1; then
    log "Creating beszel system user..."
    useradd --system --home-dir /var/lib/beszel-agent --create-home \
        --shell /usr/sbin/nologin beszel
fi

log "Downloading $ASSET..."
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
curl -fSL "$URL" -o "$tmpdir/$ASSET"
tar -xzf "$tmpdir/$ASSET" -C "$tmpdir" beszel-agent
[[ -x "$tmpdir/beszel-agent" ]] || die "Archive did not contain beszel-agent"

mkdir -p /opt/beszel-agent
install -m 0755 -o root -g root "$tmpdir/beszel-agent" /opt/beszel-agent/beszel-agent
log "Installed /opt/beszel-agent/beszel-agent"

mkdir -p /etc/beszel
umask 077
{
    printf 'HUB_URL=%s\n' "$BESZEL_HUB_URL"
    printf 'KEY="%s"\n' "$BESZEL_KEY"
    printf 'TOKEN=%s\n' "$BESZEL_TOKEN"
    printf 'LISTEN=127.0.0.1:45876\n'
    printf 'DISABLE_SSH=true\n'
    printf 'SYSTEM_NAME=%s\n' "$SYSTEM_NAME"
    printf 'SERVICE_PATTERNS=%s\n' 'adspace-*.service,caddy.service'
} > /etc/beszel/beszel-agent.env
chmod 600 /etc/beszel/beszel-agent.env
chown root:root /etc/beszel/beszel-agent.env
log "Wrote /etc/beszel/beszel-agent.env (SYSTEM_NAME=$SYSTEM_NAME)"

cat > /etc/systemd/system/beszel-agent.service << 'EOF'
[Unit]
Description=Beszel Agent
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
Type=simple
User=beszel
ExecStart=/opt/beszel-agent/beszel-agent
EnvironmentFile=/etc/beszel/beszel-agent.env
Restart=on-failure
RestartSec=5
StateDirectory=beszel-agent

# Security/sandboxing settings
KeyringMode=private
LockPersonality=yes
NoNewPrivileges=yes
ProtectClock=yes
ProtectHome=read-only
ProtectHostname=yes
ProtectKernelLogs=yes
ProtectSystem=strict
RemoveIPC=yes
RestrictSUIDSGID=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable beszel-agent.service
systemctl restart beszel-agent.service
log "beszel-agent enabled and running as $SYSTEM_NAME → $BESZEL_HUB_URL"
