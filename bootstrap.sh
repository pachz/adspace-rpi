#!/usr/bin/env bash
# =============================================================================
# AdSpace RPi — Bootstrap Script
# =============================================================================
# Runs ONCE on first boot. Fully provisions the Pi from scratch:
#   - Installs all packages
#   - Creates users and configures sudo/SSH
#   - Writes all scripts, systemd units, and config files
#   - Pulls the app binary + frontend from the latest GitHub Release
#   - Sets hostname from CPU serial
#   - Registers with Tailscale (or Headscale if HEADSCALE_LOGIN_SERVER is set)
#   - Reboots into kiosk mode
#
# Guarded by /etc/adspace-bootstrap-done — never runs twice.
# Triggered by adspace-bootstrap.service on first boot.
#
# GITHUB_REPO: awbalessa/adspace-rpi
# =============================================================================

set -euo pipefail

DONE_FLAG="/etc/adspace-bootstrap-done"
GITHUB_REPO="pachz/adspace-rpi"
TAILSCALE_OAUTH_SECRET="tskey-client-koZCgE2fK421CNTRL-WAfqtB3SRXSeqKSUgJTcWSjoD1vxFbGF"

# Headscale override: if HEADSCALE_LOGIN_SERVER is set (env, or
# /boot/firmware/adspace-tailnet.env), join that instead of Tailscale.com.
# Leave empty for production.
HEADSCALE_LOGIN_SERVER="${HEADSCALE_LOGIN_SERVER:-}"
HEADSCALE_AUTH_KEY="${HEADSCALE_AUTH_KEY:-}"
for _f in /boot/firmware/adspace-tailnet.env /boot/adspace-tailnet.env; do
    [[ -f "$_f" ]] || continue
    # shellcheck disable=SC1090
    source "$_f"
    break
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[bootstrap]${NC} $*"; logger -t adspace-bootstrap "$*"; }
warn() { echo -e "${YELLOW}[bootstrap]${NC} $*" >&2; logger -t adspace-bootstrap "WARN: $*"; }
die()  { echo -e "${RED}[bootstrap]${NC} ERROR: $*" >&2; logger -t adspace-bootstrap "ERROR: $*"; exit 1; }

[[ $EUID -eq 0 ]] || die "Must run as root"
[[ -f "$DONE_FLAG" ]] && { log "Already bootstrapped. Exiting."; exit 0; }

# Pi CPU serial is hardware-unique. QEMU/virt has none — fall back to machine-id.
device_serial() {
    local s
    s=$(awk '/^Serial/{print $3; exit}' /proc/cpuinfo)
    if [[ -z "$s" && -r /etc/machine-id ]]; then
        warn "No Pi CPU serial; using machine-id (QEMU/virt)"
        s=$(tr -d '\n' < /etc/machine-id)
    fi
    [[ -n "$s" ]] || die "Could not determine device serial"
    printf '%s' "${s: -8}"
}

log "========================================================"
log " AdSpace Bootstrap starting"
log "========================================================"

# ── 1. Wait for internet ──────────────────────────────────────────────────────
log "Waiting for internet connectivity..."
TRIES=0
until curl -sf --max-time 5 https://github.com > /dev/null 2>&1; do
    TRIES=$((TRIES + 1))
    log "  No internet yet (attempt $TRIES) — retrying in 10s..."
    sleep 10
done
log "Internet is up."

# ── 2. System packages ────────────────────────────────────────────────────────
log "Installing packages..."
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    chromium \
    rpi-chromium-mods \
    xwayland \
    caddy \
    network-manager \
    unclutter \
    unclutter-xfixes \
    curl \
    rsync \
    dnsmasq-base \
    grim \
    jq

# cage requires libwlroots-0.18 (RPi build) — must pin before installing cage.
# libwlroots-0.19 (labwc) SEGFAULTs on Pi 5 mode switch.
DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-downgrades \
    'libwlroots-0.18=0.18.2-3+rpt4+b1'
DEBIAN_FRONTEND=noninteractive apt-get install -y cage

# Remove labwc — conflicts with cage on Pi 5
DEBIAN_FRONTEND=noninteractive apt-get remove -y labwc 2>/dev/null || true

# ── 3. NetworkManager ─────────────────────────────────────────────────────────
log "Configuring NetworkManager..."
cat > /etc/NetworkManager/NetworkManager.conf << 'EOF'
[main]
dns=dnsmasq
plugins=ifupdown,keyfile

[ifupdown]
managed=false
EOF

systemctl enable --now NetworkManager

for svc in dhcpcd wpa_supplicant ifupdown; do
    systemctl disable "$svc" 2>/dev/null || true
    systemctl stop    "$svc" 2>/dev/null || true
done

# ── 4. Boot config — HDMI (Pi 5 KMS/DRM, not legacy firmware settings) ───────
log "Configuring boot/display..."
BOOT_CONFIG="/boot/firmware/config.txt"
# Remove any legacy Pi 4 HDMI settings — silently ignored on Pi 5
sed -i '/hdmi_force_hotplug/d' "$BOOT_CONFIG"
sed -i '/hdmi_group/d'         "$BOOT_CONFIG"
sed -i '/hdmi_mode/d'          "$BOOT_CONFIG"
sed -i '/# AdSpace: force HDMI/d' "$BOOT_CONFIG"
grep -q 'dtparam=hdmi_force_hotplug=1' "$BOOT_CONFIG" || cat >> "$BOOT_CONFIG" << 'EOF'

# AdSpace: force HDMI output even with no display detected (Pi 5 KMS/DRM)
[all]
dtparam=hdmi_force_hotplug=1
EOF

# ── 5. Users ──────────────────────────────────────────────────────────────────
log "Creating users..."

# adspace — runs kiosk and setup services
if ! id adspace &>/dev/null; then
    useradd -m -s /bin/bash adspace
fi
for grp in adm dialout cdrom sudo audio video plugdev games users input \
           render netdev spi i2c gpio; do
    getent group "$grp" &>/dev/null && usermod -aG "$grp" adspace
done

# pi — already exists on RPi OS, ensure passwordless sudo
cat > /etc/sudoers.d/010_pi-nopasswd << 'EOF'
pi ALL=(ALL) NOPASSWD:ALL
EOF
chmod 440 /etc/sudoers.d/010_pi-nopasswd

# Fleet-management SSH key (also baked into cloud-init user-data by embed.sh)
mkdir -p /home/pi/.ssh
chmod 700 /home/pi/.ssh
FLEET_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAID4b09qcgIfg0la+WsmLa7cFUyxIDvfzKbwtTMuFozOs adspace-fleet-management"
touch /home/pi/.ssh/authorized_keys
chmod 600 /home/pi/.ssh/authorized_keys
grep -qxF "$FLEET_KEY" /home/pi/.ssh/authorized_keys 2>/dev/null \
    || echo "$FLEET_KEY" >> /home/pi/.ssh/authorized_keys
chown -R pi:pi /home/pi/.ssh

# adspace — nmcli access for wifi-setup-api
cat > /etc/sudoers.d/adspace << 'EOF'
adspace ALL=(ALL) NOPASSWD: /usr/bin/nmcli
adspace ALL=(ALL) NOPASSWD: /sbin/reboot
adspace ALL=(ALL) NOPASSWD: /usr/sbin/reboot
EOF
chmod 440 /etc/sudoers.d/adspace

# aiagent — AI coding agent, full passwordless sudo, key-only SSH
if ! id aiagent &>/dev/null; then
    useradd -m -s /bin/bash aiagent
fi
usermod -aG pi aiagent
mkdir -p /home/aiagent/.ssh
chmod 700 /home/aiagent/.ssh
chown aiagent:aiagent /home/aiagent/.ssh
cat > /home/aiagent/.ssh/authorized_keys << 'EOF'
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKhyZmRF0Z688khDd/XOlbi7BGr27f03wpVGcBNzy68y coding agent
EOF
chmod 600 /home/aiagent/.ssh/authorized_keys
chown aiagent:aiagent /home/aiagent/.ssh/authorized_keys

cat > /etc/sudoers.d/aiagent << 'EOF'
aiagent ALL=(ALL) NOPASSWD: ALL
EOF
chmod 440 /etc/sudoers.d/aiagent

# ── 6. tty1 autologin ─────────────────────────────────────────────────────────
log "Configuring tty1 autologin..."
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf << 'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin adspace --noclear %I $TERM
EOF

# ── 7. /opt/adspace scripts ───────────────────────────────────────────────────
log "Writing /opt/adspace scripts..."
mkdir -p /opt/adspace/wifi-setup/dist

cat > /opt/adspace/watchdog.sh << 'WATCHDOG'
#!/usr/bin/env bash
# adspace-watchdog: always-on loop that drives kiosk ↔ setup transitions

CONFIG_JSON="/opt/adspace/wifi-setup/dist/config.json"
SETUP_FLAG="/tmp/adspace-setup-mode"
WIFI_SCAN_CACHE="/tmp/adspace-wifi-scan.json"

log() { echo "adspace-watchdog: $*"; logger -t adspace-watchdog "$*"; }

is_connected() {
    # Check NM's connectivity state — 'full' means actual internet, not just a profile activated.
    # The old approach (checking activated profiles) fails because NM keeps ethernet profiles
    # in 'activated' state even after the cable is unplugged, causing false positives.
    local state
    state=$(nmcli networking connectivity 2>/dev/null)
    [ "$state" = "full" ]
}

scan_networks() {
    log "Scanning for networks..."
    nmcli dev wifi rescan ifname wlan0 2>/dev/null || true
    sleep 3
    nmcli -t -f SSID,SIGNAL dev wifi list ifname wlan0 2>/dev/null \
        | grep -v '^\s*:' \
        | grep -v '^Adspace-TV-' \
        | awk -F: '!seen[$1]++ && $1!="" {
            gsub(/[^0-9]/, "", $2)
            printf "{\"ssid\":\"%s\",\"signal\":%s},", $1, ($2=="" ? "0" : $2)
          }' \
        | sed 's/,$//' \
        | (echo -n '['; cat; echo ']') \
        > "$WIFI_SCAN_CACHE"
    log "Scan complete: $(cat $WIFI_SCAN_CACHE)"
}

enter_kiosk() {
    log "Network up → kiosk mode"
    rm -f "$SETUP_FLAG"
    rm -f "$WIFI_SCAN_CACHE"
    systemctl stop caddy.service || true
    systemctl stop adspace-setup-api.service || true
    nmcli con down adspace-hotspot 2>/dev/null || true
    systemctl restart adspace-kiosk.service
}

enter_setup() {
    log "Network lost → setup mode"
    CPU_SERIAL=$(awk '/^Serial/{print $3; exit}' /proc/cpuinfo)
    if [[ -z "$CPU_SERIAL" && -r /etc/machine-id ]]; then
        CPU_SERIAL=$(tr -d '\n' < /etc/machine-id)
    fi
    CPU_SERIAL="${CPU_SERIAL: -8}"
    SSID="Adspace-TV-${CPU_SERIAL}"
    PASSWORD="${CPU_SERIAL}"

    scan_networks

    nmcli con modify adspace-hotspot \
        802-11-wireless.ssid "$SSID" \
        802-11-wireless-security.psk "$PASSWORD" 2>/dev/null || true

    cat > "$CONFIG_JSON" << JSONEOF
{
  "hotspotSSID": "$SSID",
  "hotspotPassword": "$PASSWORD",
  "setupURL": "http://192.168.4.1"
}
JSONEOF

    touch "$SETUP_FLAG"
    nmcli con up adspace-hotspot
    systemctl start adspace-setup-api.service
    systemctl start caddy.service
    systemctl restart adspace-kiosk.service
}

try_reconnect() {
    log "Trying to reconnect to saved networks..."
    nmcli con down adspace-hotspot 2>/dev/null || true
    sleep 20
    if is_connected; then
        log "Reconnected to saved network"
        return 0
    else
        log "No saved network found, restoring hotspot"
        nmcli con up adspace-hotspot 2>/dev/null || true
        return 1
    fi
}

last_state=""
setup_cycles=0
fail_count=0

while true; do
    if is_connected; then
        fail_count=0
        if [ "$last_state" != "kiosk" ]; then
            enter_kiosk
            last_state="kiosk"
            setup_cycles=0
        fi
    else
        fail_count=$((fail_count + 1))
        # Require 2 consecutive failed checks (~30s) before entering setup mode.
        # Prevents a momentary NM connectivity probe failure from triggering
        # a full setup mode transition.
        if [ "$fail_count" -lt 2 ]; then
            sleep 15
            continue
        fi
        fail_count=0
        if [ "$last_state" != "setup" ]; then
            enter_setup
            last_state="setup"
            setup_cycles=0
        else
            # Every 4 cycles (~60s) while in setup, try reconnecting to saved networks
            setup_cycles=$((setup_cycles + 1))
            if [ "$setup_cycles" -ge 4 ]; then
                setup_cycles=0
                if try_reconnect; then
                    enter_kiosk
                    last_state="kiosk"
                fi
            fi
        fi
    fi
    sleep 15
done
WATCHDOG

cat > /opt/adspace/start-display.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Call the chromium binary directly — bypasses RPi launcher wrapper which
# injects --js-flags=--no-decommit-pooled-pages (unsupported flag, causes crash)
unset CHROMIUM_FLAGS
CHROMIUM_BIN=/usr/lib/chromium/chromium

if [ -f /tmp/adspace-setup-mode ]; then
    # Wait for Caddy to be ready before launching browser
    for i in $(seq 1 10); do
        curl -sf http://localhost/ >/dev/null 2>&1 && break
        sleep 1
    done

    exec "$CHROMIUM_BIN" \
        --ozone-platform=wayland \
        --enable-features=UseOzonePlatform \
        --kiosk \
        --start-fullscreen \
        --noerrdialogs \
        --disable-infobars \
        --disable-session-crashed-bubble \
        --disable-features=TranslateUI \
        --disable-pinch \
        --overscroll-history-navigation=0 \
        --password-store=basic \
        --disk-cache-size=1 \
        --user-data-dir=/home/adspace/.config/adspace-setup-chromium \
        "http://localhost/tv"
else
    source /opt/adspace/kiosk.env
    exec "$CHROMIUM_BIN" \
        --ozone-platform=wayland \
        --enable-features=UseOzonePlatform \
        --kiosk \
        --start-fullscreen \
        --noerrdialogs \
        --disable-infobars \
        --disable-session-crashed-bubble \
        --disable-features=TranslateUI \
        --disable-pinch \
        --overscroll-history-navigation=0 \
        --password-store=basic \
        --user-data-dir=/home/adspace/.config/adspace-chromium \
        "$ADSPACE_URL"
fi
EOF

cat > /opt/adspace/kiosk.env << 'EOF'
ADSPACE_URL="https://screen.adspace.so"
EOF

chmod +x /opt/adspace/watchdog.sh /opt/adspace/start-display.sh
chown -R adspace:adspace /opt/adspace
mkdir -p /opt/adspace/wifi-setup/dist
chown -R pi:pi /opt/adspace/wifi-setup/dist
chmod -R 775 /opt/adspace/wifi-setup/dist

# ── 8. PAM for cage ───────────────────────────────────────────────────────────
log "Writing /etc/pam.d/cage..."
cat > /etc/pam.d/cage << 'EOF'
auth     required pam_unix.so nullok
account  required pam_unix.so
session  required pam_unix.so
session  required pam_systemd.so
EOF

# ── 9. Caddyfile ──────────────────────────────────────────────────────────────
log "Writing Caddyfile..."
cat > /etc/caddy/Caddyfile << 'EOF'
{
    auto_https off
}

:80 {
    handle /hotspot-detect.html {
        redir http://192.168.4.1/ 302
    }
    handle /library/test/success.html {
        redir http://192.168.4.1/ 302
    }
    handle /generate_204 {
        redir http://192.168.4.1/ 302
    }
    handle /gen_204 {
        redir http://192.168.4.1/ 302
    }
    handle /connecttest.txt {
        redir http://192.168.4.1/ 302
    }
    handle /redirect {
        redir http://192.168.4.1/ 302
    }

    handle /api/* {
        reverse_proxy localhost:3000
    }

    handle /config.json {
        root * /opt/adspace/wifi-setup/dist
        header Cache-Control "no-store, no-cache, must-revalidate"
        file_server
    }

    handle {
        root * /opt/adspace/wifi-setup/dist
        try_files {path} /index.html
        file_server
    }
}
EOF

systemctl disable caddy.service 2>/dev/null || true

# ── 10. Systemd units ─────────────────────────────────────────────────────────
log "Installing systemd units..."

cat > /etc/systemd/system/adspace-kiosk.service << 'EOF'
[Unit]
Description=AdSpace Wayland Kiosk
After=systemd-user-sessions.service dev-dri-card1.device
Wants=dev-dri-card1.device
Conflicts=getty@tty1.service
After=getty@tty1.service

[Service]
User=adspace
PAMName=cage
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=yes
StandardInput=tty-fail
StandardOutput=journal
StandardError=journal
WorkingDirectory=/home/adspace

Environment=XDG_SESSION_TYPE=wayland
Environment=WLR_RENDERER=gles2
Environment=WLR_DRM_DEVICES=/dev/dri/card1

ExecStartPre=/bin/sh -c 'until [ -e /dev/dri/card1 ]; do sleep 0.5; done'
ExecStartPre=/bin/sh -c 'uid=$(id -u adspace); mkdir -p /run/user/$uid; chmod 700 /run/user/$uid; chown adspace:adspace /run/user/$uid; rm -f /run/user/$uid/wayland-*'
ExecStartPre=/bin/sh -c 'rm -f /home/adspace/.config/adspace-chromium/SingletonLock /home/adspace/.config/adspace-setup-chromium/SingletonLock'
ExecStart=/usr/bin/cage -s -- /opt/adspace/start-display.sh

KillMode=control-group
TimeoutStopSec=10
Restart=always
RestartSec=8

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/adspace-watchdog.service << 'EOF'
[Unit]
Description=AdSpace Watchdog
After=NetworkManager.service
Wants=NetworkManager.service

[Service]
ExecStart=/opt/adspace/watchdog.sh
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/adspace-setup-api.service << 'EOF'
[Unit]
Description=AdSpace WiFi Setup API
After=network.target

[Service]
Type=simple
User=adspace
ExecStart=/opt/adspace/wifi-setup-api
Restart=on-failure
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable  adspace-watchdog.service
systemctl enable  adspace-kiosk.service
systemctl disable adspace-kiosk.service      # watchdog controls it, not boot
systemctl disable adspace-setup-api.service 2>/dev/null || true

# ── 11. Disable cloud-init ────────────────────────────────────────────────────
log "Disabling cloud-init..."
touch /etc/cloud/cloud-init.disabled
for svc in cloud-init cloud-init-local cloud-init-net cloud-init-final cloud-config cloud-final; do
    systemctl disable "${svc}.service" 2>/dev/null || true
done

# ── 12. Hostname from CPU serial ──────────────────────────────────────────────
log "Setting hostname..."
CPU_SERIAL=$(device_serial)
NEW_HOSTNAME="adspace-${CPU_SERIAL}"
[[ "$NEW_HOSTNAME" =~ ^adspace-[0-9a-fA-F]+$ ]] \
    || die "Invalid hostname derived from serial: $(printf %q "$NEW_HOSTNAME")"
echo "$NEW_HOSTNAME" > /etc/hostname
hostnamectl set-hostname "$NEW_HOSTNAME" || hostname "$NEW_HOSTNAME"
sed -i "s/127\.0\.1\.1\s.*$/127.0.1.1\t$NEW_HOSTNAME/" /etc/hosts 2>/dev/null || true
grep -q '127.0.1.1' /etc/hosts || echo -e "127.0.1.1\t$NEW_HOSTNAME" >> /etc/hosts
log "Hostname: $NEW_HOSTNAME"

# ── 13–14. WiFi country + hotspot (skip when no radio, e.g. QEMU) ─────────────
if [[ -e /sys/class/net/wlan0 ]]; then
    log "Setting WiFi country (AE)..."
    raspi-config nonint do_wifi_country AE
    /sbin/rfkill unblock wifi || true

    log "Creating hotspot nmcli profile..."
    nmcli con delete adspace-hotspot 2>/dev/null || true
    nmcli con add \
        type wifi \
        ifname wlan0 \
        con-name adspace-hotspot \
        autoconnect no \
        ssid "Adspace-TV-setup" \
        -- \
        wifi.mode ap \
        wifi.band bg \
        wifi.channel 6 \
        wifi-sec.key-mgmt wpa-psk \
        wifi-sec.psk "setupsetup" \
        ipv4.method shared \
        ipv4.addresses 192.168.4.1/24 \
        ipv6.method disabled
else
    warn "No wlan0 — skipping WiFi country and hotspot"
fi

# ── 15. Tailscale / Headscale ─────────────────────────────────────────────────
if ! command -v tailscale &>/dev/null; then
    log "Installing Tailscale client..."
    curl -fsSL https://tailscale.com/install.sh | sh
fi

# Stop the package's first start — on QEMU it crash-loops (no kernel
# modules for TUN/nftables) until we switch to userspace networking.
systemctl stop tailscaled 2>/dev/null || true

if systemd-detect-virt -q 2>/dev/null || ! grep -q '^Serial' /proc/cpuinfo; then
    warn "Virtualized/no Pi serial: Tailscale userspace networking (no TUN/nft)"
    mkdir -p /etc/default /etc/systemd/system/tailscaled.service.d
    if [[ -f /etc/default/tailscaled ]] && grep -q '^FLAGS=' /etc/default/tailscaled; then
        sed -i 's|^FLAGS=.*|FLAGS="--tun=userspace-networking"|' /etc/default/tailscaled
    else
        printf 'PORT="41641"\nFLAGS="--tun=userspace-networking"\n' > /etc/default/tailscaled
    fi
    cat > /etc/systemd/system/tailscaled.service.d/virt.conf << 'EOF'
[Service]
Environment=TS_DEBUG_FIREWALL_MODE=off
RestartSec=2
EOF
    systemctl daemon-reload
fi

systemctl enable tailscaled
systemctl start tailscaled

log "Waiting for tailscaled LocalAPI..."
_ts_sock=""
for _i in $(seq 1 60); do
    if [[ -S /run/tailscale/tailscaled.sock ]]; then
        _ts_sock=/run/tailscale/tailscaled.sock
    elif [[ -S /var/run/tailscale/tailscaled.sock ]]; then
        _ts_sock=/var/run/tailscale/tailscaled.sock
    else
        sleep 0.5
        continue
    fi
    _code=$(curl -sS -o /dev/null -w '%{http_code}' --unix-socket "$_ts_sock" \
        http://local-tailscaled.sock/localapi/v0/status || true)
    if [[ "$_code" == "200" ]]; then
        break
    fi
    sleep 0.5
done
[[ "${_code:-}" == "200" ]] \
    || die "tailscaled LocalAPI never became ready (last HTTP ${_code:-none})"
unset _ts_sock _code _i

if [[ -n "$HEADSCALE_LOGIN_SERVER" ]]; then
    [[ -n "$HEADSCALE_AUTH_KEY" ]] \
        || die "HEADSCALE_LOGIN_SERVER is set but HEADSCALE_AUTH_KEY is empty"
    log "Registering with Headscale at $HEADSCALE_LOGIN_SERVER..."
    tailscale up \
        --login-server="$HEADSCALE_LOGIN_SERVER" \
        --auth-key="$HEADSCALE_AUTH_KEY" \
        --hostname="$NEW_HOSTNAME" \
        --accept-routes
    log "Headscale registered as $NEW_HOSTNAME"
else
    log "Registering with Tailscale..."
    tailscale up \
        --auth-key="${TAILSCALE_OAUTH_SECRET}?ephemeral=false&preauthorized=true" \
        --advertise-tags=tag:rpi \
        --hostname="$NEW_HOSTNAME" \
        --accept-routes
    log "Tailscale registered as $NEW_HOSTNAME"
fi

# ── 16. Pull release artifacts from GitHub ────────────────────────────────────
fetch_github_release() {
    log "Fetching latest release from github.com/$GITHUB_REPO..."
    local api="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
    local code json
    code=$(curl -sS -o /tmp/adspace-release.json -w '%{http_code}' "$api" || true)
    if [[ "$code" != "200" ]]; then
        die "GitHub releases/latest returned HTTP ${code:-000} for $GITHUB_REPO (no published release?). Tag and push: git tag v0.1.0 && git push origin v0.1.0"
    fi
    json=$(cat /tmp/adspace-release.json)
    API_URL=$(echo "$json" | jq -r '.assets[] | select(.name == "wifi-setup-api") | .browser_download_url')
    DIST_URL=$(echo "$json" | jq -r '.assets[] | select(.name == "wifi-setup-dist.tar.gz") | .browser_download_url')
    RELEASE_TAG=$(echo "$json" | jq -r '.tag_name')
    [[ -n "$API_URL" && "$API_URL" != "null" ]]  || die "No wifi-setup-api asset in release $RELEASE_TAG"
    [[ -n "$DIST_URL" && "$DIST_URL" != "null" ]] || die "No wifi-setup-dist.tar.gz asset in release $RELEASE_TAG"

    log "Pulling release $RELEASE_TAG..."
    curl -fSL "$API_URL" -o /opt/adspace/wifi-setup-api
    chmod +x /opt/adspace/wifi-setup-api
    chown adspace:adspace /opt/adspace/wifi-setup-api
    log "wifi-setup-api downloaded"

    mkdir -p /opt/adspace/wifi-setup/dist
    curl -fSL "$DIST_URL" -o /tmp/wifi-setup-dist.tar.gz
    tar -xzf /tmp/wifi-setup-dist.tar.gz -C /opt/adspace/wifi-setup/dist
    rm /tmp/wifi-setup-dist.tar.gz
    rm -f /opt/adspace/wifi-setup/dist/config.json
    chown -R pi:pi /opt/adspace/wifi-setup/dist
    chmod -R 775 /opt/adspace/wifi-setup/dist
    log "Frontend deployed from release $RELEASE_TAG"
}

if systemd-detect-virt -q 2>/dev/null || ! grep -q '^Serial' /proc/cpuinfo; then
    warn "No GitHub release pull on VM — $GITHUB_REPO has no /releases/latest until you tag one"
    warn "On a real Pi, publish with: git tag v0.1.0 && git push origin v0.1.0"
else
    fetch_github_release
fi

# ── Done ──────────────────────────────────────────────────────────────────────
touch "$DONE_FLAG"

log "========================================================"
log " Bootstrap complete! Hostname: $NEW_HOSTNAME"
log " Rebooting into kiosk in 5 seconds..."
log "========================================================"

sleep 5
reboot
