#!/usr/bin/env bash
# =============================================================================
# AdSpace RPi — Bootstrap Script
# =============================================================================
# Runs ONCE on first boot. Fully provisions the Pi from scratch:
#   - Installs all packages
#   - Creates users and configures sudo/SSH
#   - Writes all scripts, systemd units, and config files
#   - Starts adspace-info (localhost:7224 device identity API)
#   - Pulls the app binary + frontend from the latest GitHub Release
#   - Sets hostname from CPU serial
#   - Registers with Tailscale (or Headscale if HEADSCALE_LOGIN_SERVER is set)
#   - Installs Beszel agent if BESZEL_HUB_URL / KEY / TOKEN are set
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

# Optional apt-cacher-ng (embed.sh writes this from APT_PROXY). Dev flash
# images bake in the office cacher; prod images leave this empty.
APT_PROXY="${APT_PROXY:-}"
for _f in /boot/firmware/adspace-apt.env /boot/adspace-apt.env; do
    [[ -f "$_f" ]] || continue
    # shellcheck disable=SC1090
    source "$_f"
    break
done
APT_PROXY="${APT_PROXY%/}"

# Optional kiosk URL (embed.sh writes this from ADSPACE_URL). Prod default
# is screen.adspace.so; the CI dev image sets https://dev.adspace.live.
ADSPACE_URL="${ADSPACE_URL:-}"
for _f in /boot/firmware/adspace-kiosk.env /boot/adspace-kiosk.env; do
    [[ -f "$_f" ]] || continue
    # shellcheck disable=SC1090
    source "$_f"
    break
done
ADSPACE_URL="${ADSPACE_URL:-https://screen.adspace.so}"
[[ "$ADSPACE_URL" =~ ^https?://[^[:space:]]+$ ]] \
    || die "Invalid ADSPACE_URL: $ADSPACE_URL"

# Optional image version (embed.sh writes this from the git tag / CI release).
ADSPACE_VERSION="${ADSPACE_VERSION:-}"
for _f in /boot/firmware/adspace-version.env /boot/adspace-version.env; do
    [[ -f "$_f" ]] || continue
    # shellcheck disable=SC1090
    source "$_f"
    break
done
ADSPACE_VERSION="${ADSPACE_VERSION:-dev}"
BASE_UA=""

# Optional Beszel hub (embed.sh writes this from BESZEL_*). Agent is skipped
# unless all three are set. Universal token registers each Pi by hostname.
BESZEL_HUB_URL="${BESZEL_HUB_URL:-}"
BESZEL_KEY="${BESZEL_KEY:-}"
BESZEL_TOKEN="${BESZEL_TOKEN:-}"
for _f in /boot/firmware/adspace-beszel.env /boot/adspace-beszel.env; do
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

# Chromium's real UA + " AdspaceTV/rpi-<tag>" (tag from image bake or GitHub release).
dump_chromium_base_ua() {
    local html
    html=$(/usr/lib/chromium/chromium --headless --no-sandbox --disable-gpu \
        --user-data-dir=/tmp/adspace-ua-dump --dump-dom \
        'data:text/html,<script>document.write(navigator.userAgent)</script>' \
        2>/dev/null || true)
    rm -rf /tmp/adspace-ua-dump
    BASE_UA=$(printf '%s' "$html" | tr '\n' ' ' | sed -n 's/.*<body>\(.*\)<\/body>.*/\1/p')
    BASE_UA=$(printf '%s' "$BASE_UA" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [[ -z "$BASE_UA" ]]; then
        warn "Could not dump Chromium user-agent — kiosk will use Chromium's default"
        return 0
    fi
    log "Chromium base UA: $BASE_UA"
}

write_chromium_ua() {
    local version="${1:-${ADSPACE_VERSION:-dev}}"
    local token="${version#v}"
    [[ -n "$BASE_UA" ]] || return 0
    mkdir -p /opt/adspace
    printf '%s AdspaceTV/rpi-%s\n' "$BASE_UA" "$token" > /opt/adspace/chromium-ua
    printf '%s\n' "$token" > /opt/adspace/version
    if id adspace >/dev/null 2>&1; then
        chown adspace:adspace /opt/adspace/chromium-ua /opt/adspace/version
    fi
    log "Chromium user-agent: $(tr -d '\n' < /opt/adspace/chromium-ua)"
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

# Optional LAN apt-cacher. Unreachable / invalid → apt goes direct (CI, venue).
if [[ -n "${APT_PROXY:-}" ]]; then
    if [[ "$APT_PROXY" =~ ^https?://[A-Za-z0-9._-]+(:[0-9]+)?/?$ ]]; then
        if curl -sS --max-time 3 -o /dev/null "$APT_PROXY"; then
            mkdir -p /etc/apt/apt.conf.d
            cat > /etc/apt/apt.conf.d/01adspace-proxy << EOF
Acquire::http::Proxy "${APT_PROXY}";
Acquire::https::Proxy "DIRECT";
EOF
            log "Using apt proxy ${APT_PROXY}"
        else
            warn "APT_PROXY unreachable (${APT_PROXY}) — apt will go direct"
        fi
    else
        warn "Ignoring invalid APT_PROXY: $APT_PROXY"
    fi
fi

# ── 2. System packages ────────────────────────────────────────────────────────
log "Installing packages..."
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    chromium \
    rpi-chromium-mods \
    xwayland \
    caddy \
    network-manager \
    python3 \
    python3-cryptography \
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

# Cage draws the pointer itself. Hide it with a fully-transparent Xcursor theme
# (unclutter is X11-only; labwc HideCursor does not exist in cage).
#
# Packaged cage (0.1.x) ignores XCURSOR_THEME and loads the theme named
# "default". wlroots does not follow index.theme Inherits= — if
# default/cursors/ is empty it loads a *built-in visible arrow*. The blank
# files must live in default/cursors/, not only in a named theme.
log "Installing invisible cursor theme..."
python3 - << 'PY'
import os, struct

theme = "/usr/share/icons/AdspaceBlank"
cdir = os.path.join(theme, "cursors")
os.makedirs(cdir, exist_ok=True)

size = 24
pixels = b"\x00" * (size * size * 4)
image_type = 0xFFFD0002
header_len, toc_len, image_header_len, ntoc = 16, 12, 36, 1
image_pos = header_len + toc_len * ntoc

buf = bytearray()
buf += b"Xcur"
buf += struct.pack("<III", header_len, 0x00010000, ntoc)
buf += struct.pack("<III", image_type, size, image_pos)
buf += struct.pack(
    "<IIIIIIIII",
    image_header_len, image_type, size, 1,
    size, size, 0, 0, 0,
)
buf += pixels

left_ptr = os.path.join(cdir, "left_ptr")
with open(left_ptr, "wb") as f:
    f.write(buf)

names = (
    "default", "arrow", "top_left_arrow", "left_arrow", "pointer",
    "hand", "hand1", "hand2", "grab", "grabbing", "openhand", "closedhand",
    "text", "xterm", "vertical-text", "crosshair", "cross", "tcross", "plus",
    "cell", "move", "all-scroll", "fleur", "size_all",
    "not-allowed", "no-drop", "crossed_circle", "pirate",
    "wait", "watch", "left_ptr_watch", "progress",
    "help", "question_arrow", "context-menu",
    "alias", "copy", "link", "dnd-copy", "dnd-move", "dnd-link",
    "dnd-none", "dnd-no-drop", "color-picker", "pencil", "draft",
    "zoom-in", "zoom-out",
    "col-resize", "row-resize", "n-resize", "e-resize", "s-resize", "w-resize",
    "ne-resize", "nw-resize", "se-resize", "sw-resize",
    "ew-resize", "ns-resize", "nesw-resize", "nwse-resize",
    "sb_h_double_arrow", "sb_v_double_arrow",
    "sb_up_arrow", "sb_down_arrow", "sb_left_arrow", "sb_right_arrow",
    "split_h", "split_v", "size_hor", "size_ver", "size_fdiag", "size_bdiag",
    "top_side", "bottom_side", "left_side", "right_side",
    "top_left_corner", "top_right_corner",
    "bottom_left_corner", "bottom_right_corner",
    "up_arrow", "center_ptr", "right_ptr",
)
for name in names:
    dest = os.path.join(cdir, name)
    if os.path.lexists(dest):
        os.remove(dest)
    os.symlink("left_ptr", dest)
PY

cat > /usr/share/icons/AdspaceBlank/index.theme << 'EOF'
[Icon Theme]
Name=AdspaceBlank
Comment=Invisible cursor for AdSpace kiosk
EOF

if [ -L /usr/share/icons/default ]; then
    rm /usr/share/icons/default
fi
mkdir -p /usr/share/icons/default
rm -rf /usr/share/icons/default/cursors
cp -a /usr/share/icons/AdspaceBlank/cursors /usr/share/icons/default/cursors
cat > /usr/share/icons/default/index.theme << 'EOF'
[Icon Theme]
Name=Default
Comment=Default cursor theme
Inherits=AdspaceBlank
EOF
# Overlay Adwaita too if present — some clients load it by name.
if [ -d /usr/share/icons/Adwaita/cursors ]; then
    cp -a /usr/share/icons/AdspaceBlank/cursors/. /usr/share/icons/Adwaita/cursors/
fi

# Chromium uploads its own cursor bitmap via wl_pointer.set_cursor, bypassing
# the compositor theme. Inject cursor:none so it requests a hidden pointer.
mkdir -p /opt/adspace/hide-cursor
cat > /opt/adspace/hide-cursor/manifest.json << 'EOF'
{
  "manifest_version": 3,
  "name": "AdSpace hide cursor",
  "version": "1.0",
  "content_scripts": [
    {
      "matches": ["<all_urls>"],
      "all_frames": true,
      "run_at": "document_start",
      "css": ["hide-cursor.css"]
    }
  ]
}
EOF
cat > /opt/adspace/hide-cursor/hide-cursor.css << 'EOF'
html, body, *, *::before, *::after { cursor: none !important; }
EOF

log "Capturing Chromium user-agent (AdspaceTV/rpi-${ADSPACE_VERSION#v})..."
dump_chromium_base_ua
write_chromium_ua "$ADSPACE_VERSION"

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

# adspace — nmcli (wifi-setup-api) + signed-command helpers
cat > /etc/sudoers.d/adspace << 'EOF'
adspace ALL=(ALL) NOPASSWD: /usr/bin/nmcli
adspace ALL=(ALL) NOPASSWD: /sbin/reboot
adspace ALL=(ALL) NOPASSWD: /usr/sbin/reboot
adspace ALL=(ALL) NOPASSWD: /opt/adspace/indicate.sh
adspace ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart adspace-kiosk.service
adspace ALL=(ALL) NOPASSWD: /bin/systemctl restart adspace-kiosk.service
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

# ── 7. /opt/adspace scripts (watchdog, start-display, indicate, kiosk.env) ───
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

UA_ARGS=()
if [ -s /opt/adspace/chromium-ua ]; then
    UA_ARGS=(--user-agent="$(tr -d '\n\r' < /opt/adspace/chromium-ua)")
fi

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
        --disable-features=TranslateUI,LocalNetworkAccessChecks,PrivateNetworkAccessRestrictions \
        --disable-pinch \
        --overscroll-history-navigation=0 \
        --password-store=basic \
        --disk-cache-size=1 \
        --load-extension=/opt/adspace/hide-cursor \
        --user-data-dir=/home/adspace/.config/adspace-setup-chromium \
        "${UA_ARGS[@]}" \
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
        --disable-features=TranslateUI,LocalNetworkAccessChecks,PrivateNetworkAccessRestrictions \
        --disable-pinch \
        --overscroll-history-navigation=0 \
        --password-store=basic \
        --load-extension=/opt/adspace/hide-cursor \
        --user-data-dir=/home/adspace/.config/adspace-chromium \
        "${UA_ARGS[@]}" \
        "$ADSPACE_URL"
fi
EOF

cat > /opt/adspace/indicate.sh << 'INDICATE_SH'
#!/usr/bin/env bash
# =============================================================================
# AdSpace identify — blink the ACT LED and flash this display's name
# =============================================================================
# Finds the physical TV attached to this Pi: the activity LED pulses and the
# HDMI screen (kiosk GUI or a console) flashes the hostname for a few seconds.
# Cage stays running — we switch to a spare VT and switch back.
#
# Also installed to /opt/adspace/indicate.sh by bootstrap.sh — keep both in sync.
#
# Usage:
#   sudo /opt/adspace/indicate.sh
#   ssh pi@adspace-{name} "sudo bash -s" < indicate.sh
#   make indicate PI_SSH=pi@adspace-{name}
#
# Optional: DURATION=6 sudo ./indicate.sh
# =============================================================================

set -euo pipefail

DURATION="${DURATION:-4}"
NAME="$(hostname)"
PREV_VT=""
USED_VT=""
LED=""
LED_TRIGGER=""
LED_BRIGHTNESS=""
VT_SCRIPT=""

cleanup() {
    if [[ -n "${TTY_BLINK_PID:-}" ]]; then
        kill "$TTY_BLINK_PID" 2>/dev/null || true
        wait "$TTY_BLINK_PID" 2>/dev/null || true
    fi
    if [[ -t 1 ]]; then
        printf '\e[?5l' 2>/dev/null || true
        printf '\e[0m' 2>/dev/null || true
    fi
    restore_led
    if [[ -n "$PREV_VT" ]]; then
        chvt "$PREV_VT" 2>/dev/null || chvt 1 2>/dev/null || true
    fi
    if [[ -n "$USED_VT" && "$USED_VT" != "$PREV_VT" ]]; then
        deallocvt "$USED_VT" 2>/dev/null || true
    fi
    [[ -z "$VT_SCRIPT" ]] || rm -f "$VT_SCRIPT"
}
trap cleanup EXIT INT TERM

die() { echo "ERROR: $*" >&2; exit 1; }

# ── Activity LED ──────────────────────────────────────────────────────────────

find_led() {
    local d
    for d in /sys/class/leds/ACT /sys/class/leds/led0 /sys/class/leds/mmc0::; do
        if [[ -w "$d/brightness" ]]; then
            LED="$d"
            return 0
        fi
    done
    return 1
}

read_led_trigger() {
    local raw
    raw="$(<"$LED/trigger")"
    if [[ "$raw" =~ \[([^]]+)\] ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    else
        printf 'none'
    fi
}

setup_led() {
    find_led || return 0
    LED_TRIGGER="$(read_led_trigger)"
    LED_BRIGHTNESS="$(<"$LED/brightness")"
    echo none >"$LED/trigger"
}

restore_led() {
    [[ -n "$LED" && -w "$LED/trigger" ]] || return 0
    echo "$LED_TRIGGER" >"$LED/trigger" 2>/dev/null || true
    if [[ -n "$LED_BRIGHTNESS" && -w "$LED/brightness" ]]; then
        echo "$LED_BRIGHTNESS" >"$LED/brightness" 2>/dev/null || true
    fi
}

led_set() {
    [[ -n "$LED" ]] || return 0
    echo "$1" >"$LED/brightness" 2>/dev/null || true
}

# ── 5×7 glyphs (a–z, 0–9, hyphen) ─────────────────────────────────────────────

glyph() {
    case "$1" in
        a) printf '%s\n' "01110" "10001" "10001" "11111" "10001" "10001" "10001" ;;
        b) printf '%s\n' "11110" "10001" "10001" "11110" "10001" "10001" "11110" ;;
        c) printf '%s\n' "01111" "10000" "10000" "10000" "10000" "10000" "01111" ;;
        d) printf '%s\n' "11110" "10001" "10001" "10001" "10001" "10001" "11110" ;;
        e) printf '%s\n' "11111" "10000" "10000" "11110" "10000" "10000" "11111" ;;
        f) printf '%s\n' "11111" "10000" "10000" "11110" "10000" "10000" "10000" ;;
        g) printf '%s\n' "01111" "10000" "10000" "10111" "10001" "10001" "01111" ;;
        h) printf '%s\n' "10001" "10001" "10001" "11111" "10001" "10001" "10001" ;;
        i) printf '%s\n' "01110" "00100" "00100" "00100" "00100" "00100" "01110" ;;
        j) printf '%s\n' "00111" "00010" "00010" "00010" "00010" "10010" "01100" ;;
        k) printf '%s\n' "10001" "10010" "10100" "11000" "10100" "10010" "10001" ;;
        l) printf '%s\n' "10000" "10000" "10000" "10000" "10000" "10000" "11111" ;;
        m) printf '%s\n' "10001" "11011" "10101" "10001" "10001" "10001" "10001" ;;
        n) printf '%s\n' "10001" "11001" "10101" "10011" "10001" "10001" "10001" ;;
        o) printf '%s\n' "01110" "10001" "10001" "10001" "10001" "10001" "01110" ;;
        p) printf '%s\n' "11110" "10001" "10001" "11110" "10000" "10000" "10000" ;;
        q) printf '%s\n' "01110" "10001" "10001" "10001" "10101" "10010" "01101" ;;
        r) printf '%s\n' "11110" "10001" "10001" "11110" "10100" "10010" "10001" ;;
        s) printf '%s\n' "01111" "10000" "10000" "01110" "00001" "00001" "11110" ;;
        t) printf '%s\n' "11111" "00100" "00100" "00100" "00100" "00100" "00100" ;;
        u) printf '%s\n' "10001" "10001" "10001" "10001" "10001" "10001" "01110" ;;
        v) printf '%s\n' "10001" "10001" "10001" "10001" "01010" "01010" "00100" ;;
        w) printf '%s\n' "10001" "10001" "10001" "10001" "10101" "11011" "10001" ;;
        x) printf '%s\n' "10001" "10001" "01010" "00100" "01010" "10001" "10001" ;;
        y) printf '%s\n' "10001" "10001" "01010" "00100" "00100" "00100" "00100" ;;
        z) printf '%s\n' "11111" "00001" "00010" "00100" "01000" "10000" "11111" ;;
        0) printf '%s\n' "01110" "10001" "10011" "10101" "11001" "10001" "01110" ;;
        1) printf '%s\n' "00100" "01100" "00100" "00100" "00100" "00100" "01110" ;;
        2) printf '%s\n' "01110" "10001" "00001" "00010" "00100" "01000" "11111" ;;
        3) printf '%s\n' "01110" "10001" "00001" "00110" "00001" "10001" "01110" ;;
        4) printf '%s\n' "00010" "00110" "01010" "10010" "11111" "00010" "00010" ;;
        5) printf '%s\n' "11111" "10000" "11110" "00001" "00001" "10001" "01110" ;;
        6) printf '%s\n' "01110" "10000" "10000" "11110" "10001" "10001" "01110" ;;
        7) printf '%s\n' "11111" "00001" "00010" "00100" "01000" "01000" "01000" ;;
        8) printf '%s\n' "01110" "10001" "10001" "01110" "10001" "10001" "01110" ;;
        9) printf '%s\n' "01110" "10001" "10001" "01111" "00001" "00001" "01110" ;;
        -) printf '%s\n' "00000" "00000" "00000" "11111" "00000" "00000" "00000" ;;
        *) printf '%s\n' "00000" "00000" "00000" "00000" "00000" "00000" "00000" ;;
    esac
}

banner_width() {
    local n=${#1} scale=$2
    echo $((n * (5 * scale + 1)))
}

draw_banner() {
    local text="$1" scale="$2"
    local i c r s line bit
    local -a bits
    local -a base=("" "" "" "" "" "" "")

    for ((i = 0; i < ${#text}; i++)); do
        c="${text:i:1}"
        mapfile -t bits < <(glyph "$c")
        for r in 0 1 2 3 4 5 6; do
            line=""
            for ((s = 0; s < 5; s++)); do
                bit="${bits[r]:s:1}"
                if [[ "$bit" == "1" ]]; then
                    line+=$(printf '%*s' "$scale" '' | tr ' ' '█')
                else
                    line+=$(printf '%*s' "$scale" '')
                fi
            done
            base[r]+="${line} "
        done
    done

    for r in 0 1 2 3 4 5 6; do
        for ((s = 0; s < scale; s++)); do
            printf '%s\n' "${base[r]}"
        done
    done
}

# ── Screen paint (linux console VT or any TTY) ────────────────────────────────

paint_loop() {
    local cols rows scale pad_x pad_y i
    local banner text
    text="$(printf '%s' "$NAME" | tr '[:upper:]' '[:lower:]')"
    local frames

    cols=$(stty size 2>/dev/null | awk '{print $2}')
    rows=$(stty size 2>/dev/null | awk '{print $1}')
    cols=${cols:-80}
    rows=${rows:-24}

    scale=$((cols / (${#text} * 6)))
    if ((scale < 1)); then scale=1; fi
    if ((scale > 5)); then scale=5; fi
    while ((scale > 1 && $(banner_width "$text" "$scale") > cols)); do
        scale=$((scale - 1))
    done
    if ((7 * scale > rows - 4)); then
        scale=$(( (rows - 4) / 7 ))
        if ((scale < 1)); then scale=1; fi
    fi

    banner="$(draw_banner "$text" "$scale")"
    pad_x=$(( (cols - $(banner_width "$text" "$scale")) / 2 ))
    if ((pad_x < 0)); then pad_x=0; fi
    pad_y=$(( (rows - 7 * scale) / 2 ))
    if ((pad_y < 1)); then pad_y=1; fi

    frames=$((DURATION * 10 / 4))
    if ((frames < 6)); then frames=6; fi

    printf '\e[?25l'
    for ((i = 0; i < frames; i++)); do
        if ((i % 2 == 0)); then
            printf '\e[107;30m'
            led_set 1
        else
            printf '\e[40;97m'
            led_set 0
        fi
        printf '\e[2J\e[H'
        printf '\e[%dB' "$pad_y"
        while IFS= read -r line; do
            printf '%*s%s\n' "$pad_x" '' "$line"
        done <<<"$banner"
        sleep 0.4
    done
    printf '\e[0m\e[2J\e[H\e[?25h'
    led_set 0
}

write_vt_script() {
    local dest=$1
    {
        echo '#!/usr/bin/env bash'
        echo 'set -euo pipefail'
        echo "NAME=$(printf '%q' "$NAME")"
        echo "DURATION=$(printf '%q' "$DURATION")"
        echo "LED=''"
        echo 'export LC_ALL=C.UTF-8'
        declare -f find_led led_set glyph banner_width draw_banner paint_loop
        echo 'find_led || true'
        echo 'if [[ -n "$LED" && -w "$LED/trigger" ]]; then echo none >"$LED/trigger"; fi'
        echo 'paint_loop'
    } >"$dest"
}

# ── Main ──────────────────────────────────────────────────────────────────────

[[ $EUID -eq 0 ]] || die "Run as root: sudo bash indicate.sh"

echo "Identifying display: $NAME"

setup_led

TTY_BLINK_PID=""
if [[ -t 1 ]]; then
    printf '\n    %s\n\n' "$NAME"
    (
        frames=$((DURATION * 10 / 4))
        if ((frames < 6)); then frames=6; fi
        for ((i = 0; i < frames; i++)); do
            if ((i % 2 == 0)); then printf '\e[?5h'; else printf '\e[?5l'; fi
            sleep 0.4
        done
        printf '\e[?5l'
    ) &
    TTY_BLINK_PID=$!
fi

PREV_VT="$(fgconsole 2>/dev/null || true)"

if command -v openvt >/dev/null && [[ -n "$PREV_VT" ]]; then
    VT_SCRIPT="$(mktemp /tmp/adspace-indicate.XXXXXX)"
    write_vt_script "$VT_SCRIPT"
    chmod +x "$VT_SCRIPT"
    openvt -f -s -w -- /bin/bash "$VT_SCRIPT" || paint_loop
    USED_VT="$(fgconsole 2>/dev/null || true)"
else
    paint_loop
fi

if [[ -n "$TTY_BLINK_PID" ]]; then
    wait "$TTY_BLINK_PID" 2>/dev/null || true
fi

echo "Done — $NAME"
INDICATE_SH

cat > /opt/adspace/device-info.py << 'DEVICE_INFO_PY'
#!/usr/bin/env python3
# =============================================================================
# AdSpace device info + signed commands — localhost:7224
# =============================================================================
# Always-on HTTP API with this Pi's version and hardware identity.
# Bound to 127.0.0.1 only. CPU serial is the unique id (not machine-id).
#
# Also installed to /opt/adspace/device-info.py by bootstrap.sh — keep both in sync.
#
#   GET  /            device info (identity + health)
#   GET  /api/info    same payload
#   GET  /health      {"ok": true, "health": {...}}
#   POST /api/command signed command packet (Ed25519)
#
# Command packet (JSON):
#   {
#     "command":   "reboot",
#     "timestamp": 1788770000,
#     "nonce":     "8f3c...",
#     "deviceId":  "4d919699",
#     "signature": "<hex or base64 Ed25519 sig>"
#   }
#
# Signature is Ed25519 over the UTF-8 message:
#   {command}.{timestamp}.{nonce}.{deviceId}
# Optional "args" object, when present, is appended:
#   {command}.{timestamp}.{nonce}.{deviceId}.{canonical_json_args}
# timestamp is the integer's decimal form (no leading zeros, no fraction).
# deviceId is this Pi's 8-char CPU serial (same as GET / serial).
# Public key: /opt/adspace/command-pubkey (32-byte hex), fleet-wide.
# =============================================================================

from __future__ import annotations

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import base64
import glob
import json
import os
import re
import socket
import subprocess
import threading
import time

LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = 7224
VERSION_PATH = "/opt/adspace/version"
SETUP_FLAG = "/tmp/adspace-setup-mode"
PUBKEY_PATH = "/opt/adspace/command-pubkey"
NONCE_PATH = "/tmp/adspace-command-nonces.json"
INDICATE_PATH = "/opt/adspace/indicate.sh"

# Fleet command-signing public key (Ed25519). Overridden by PUBKEY_PATH.
DEFAULT_PUBKEY_HEX = "8079e2154dcb576d3e6b0ba000c909f39ced3d1efe070c9ac8626edc460b6041"

TIMESTAMP_SKEW_SEC = 120
MAX_BODY = 16384
NONCE_RE = re.compile(r"^[0-9a-fA-F]{16,128}$")
COMMAND_RE = re.compile(r"^[a-z][a-z0-9-]{0,63}$")
HEX_RE = re.compile(r"^[0-9a-fA-F]+$")

_nonce_lock = threading.Lock()


class PacketError(Exception):
    def __init__(self, status, error, extra=None):
        super().__init__(error)
        self.status = status
        self.error = error
        self.extra = extra or {}


class CommandError(Exception):
    pass


def cpu_serial():
    """Last 8 chars of the Pi CPU serial, or machine-id on QEMU/virt."""
    try:
        with open("/proc/cpuinfo", encoding="utf-8") as f:
            for line in f:
                if line.startswith("Serial"):
                    serial = line.split(":", 1)[-1].strip()
                    if serial:
                        return serial[-8:]
    except OSError:
        pass
    try:
        with open("/etc/machine-id", encoding="utf-8") as f:
            mid = f.read().strip()
            if mid:
                return mid[-8:]
    except OSError:
        pass
    return ""


def version():
    try:
        with open(VERSION_PATH, encoding="utf-8") as f:
            token = f.read().strip()
            if token:
                return token
    except OSError:
        pass
    return "unknown"


def model():
    try:
        with open("/proc/device-tree/model", "rb") as f:
            return f.read().decode("utf-8", "replace").rstrip("\x00").strip()
    except OSError:
        return ""


def _read_text(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError:
        return None


def _read_int(path):
    text = _read_text(path)
    if text is None:
        return None
    try:
        return int(text.strip().split()[0], 0)
    except (ValueError, IndexError):
        return None


def _round(value, digits=1):
    if value is None:
        return None
    return round(float(value), digits)


# CPU% from /proc/stat deltas between requests — no sleep in the request path.
_cpu_lock = threading.Lock()
_cpu_prev = None  # (idle, total)
_cpu_percent = None


def _cpu_times():
    text = _read_text("/proc/stat")
    if not text:
        return None
    for line in text.splitlines():
        if not line.startswith("cpu "):
            continue
        parts = line.split()[1:]
        if len(parts) < 4:
            return None
        try:
            nums = [int(p) for p in parts[:8]]
        except ValueError:
            return None
        idle = nums[3] + (nums[4] if len(nums) > 4 else 0)
        return idle, sum(nums)
    return None


_cpu_prev = _cpu_times()


def cpu_percent():
    """Busy CPU since the previous sample. None until two samples exist."""
    global _cpu_prev, _cpu_percent
    times = _cpu_times()
    if times is None:
        return None
    with _cpu_lock:
        prev = _cpu_prev
        _cpu_prev = times
        if prev is None:
            return _cpu_percent
        idle_d = times[0] - prev[0]
        total_d = times[1] - prev[1]
        if total_d <= 0:
            return _cpu_percent
        busy = 1.0 - (idle_d / total_d)
        _cpu_percent = _round(max(0.0, min(100.0, busy * 100.0)), 1)
        return _cpu_percent


def loadavg():
    try:
        one, five, fifteen = os.getloadavg()
        return _round(one, 2), _round(five, 2), _round(fifteen, 2)
    except OSError:
        return None, None, None


def uptime_sec():
    text = _read_text("/proc/uptime")
    if not text:
        return None
    try:
        return int(float(text.split()[0]))
    except (ValueError, IndexError):
        return None


def cpu_temp_c():
    millideg = _read_int("/sys/class/thermal/thermal_zone0/temp")
    if millideg is None:
        return None
    return _round(millideg / 1000.0, 1)


def cpu_freq_mhz():
    freqs = []
    for path in glob.glob("/sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq"):
        val = _read_int(path)
        if val is not None and val > 0:
            freqs.append(val)
    if not freqs:
        return None
    return int(round(sum(freqs) / len(freqs) / 1000.0))


def meminfo_bytes():
    text = _read_text("/proc/meminfo")
    if not text:
        return {}
    fields = {}
    for line in text.splitlines():
        if ":" not in line:
            continue
        key, rest = line.split(":", 1)
        try:
            fields[key] = int(rest.strip().split()[0]) * 1024
        except (ValueError, IndexError):
            continue
    return fields


def memory_stats(fields):
    total = fields.get("MemTotal")
    available = fields.get("MemAvailable")
    if not total or available is None:
        return None
    used = max(0, total - available)
    return {
        "totalBytes": total,
        "usedBytes": used,
        "availableBytes": available,
        "percent": _round(used * 100.0 / total, 1),
    }


def swap_stats(fields):
    if not fields:
        return None
    total = fields.get("SwapTotal") or 0
    free = fields.get("SwapFree") or 0
    used = max(0, total - free)
    return {
        "totalBytes": total,
        "usedBytes": used,
        "percent": _round(used * 100.0 / total, 1) if total else 0.0,
    }


def disk_stats(path="/"):
    try:
        st = os.statvfs(path)
    except OSError:
        return None
    total = st.f_frsize * st.f_blocks
    available = st.f_frsize * st.f_bavail
    if total <= 0:
        return None
    used = max(0, total - available)
    return {
        "path": path,
        "totalBytes": total,
        "usedBytes": used,
        "availableBytes": available,
        "percent": _round(used * 100.0 / total, 1),
    }


def fan_rpm():
    for path in sorted(glob.glob("/sys/class/hwmon/hwmon*/fan1_input")):
        val = _read_int(path)
        if val is not None and val >= 0:
            return val
    return None


_THROTTLE_BITS = (
    ("underVoltage", 0),
    ("freqCapped", 1),
    ("throttled", 2),
    ("softTempLimit", 3),
    ("underVoltageOccurred", 16),
    ("freqCappedOccurred", 17),
    ("throttledOccurred", 18),
    ("softTempLimitOccurred", 19),
)


def _parse_throttled(raw):
    flags = {"raw": raw}
    for name, bit in _THROTTLE_BITS:
        flags[name] = bool(raw & (1 << bit))
    return flags


def throttle_stats():
    """Pi under-voltage / thermal throttle flags. Null on non-Pi or if unavailable."""
    text = _read_text("/sys/devices/platform/soc/soc:firmware/get_throttled")
    if text:
        try:
            return _parse_throttled(int(text.strip(), 0))
        except ValueError:
            pass
    try:
        result = subprocess.run(
            ["vcgencmd", "get_throttled"],
            capture_output=True,
            text=True,
            timeout=1,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    out = (result.stdout or "").strip()
    if "=" in out:
        out = out.split("=", 1)[-1]
    try:
        return _parse_throttled(int(out, 0))
    except ValueError:
        return None


def health():
    load1, load5, load15 = loadavg()
    mem = meminfo_bytes()
    return {
        "uptimeSec": uptime_sec(),
        "cpu": {
            "percent": cpu_percent(),
            "load1": load1,
            "load5": load5,
            "load15": load15,
            "tempC": cpu_temp_c(),
            "freqMhz": cpu_freq_mhz(),
        },
        "memory": memory_stats(mem),
        "swap": swap_stats(mem),
        "disk": disk_stats("/"),
        "fanRpm": fan_rpm(),
        "throttle": throttle_stats(),
    }


def info():
    return {
        "version": version(),
        "serial": cpu_serial(),
        "hostname": socket.gethostname(),
        "model": model(),
        "mode": "setup" if os.path.exists(SETUP_FLAG) else "kiosk",
        "health": health(),
    }


def _decode_bytes(value, expected_len, what):
    if not isinstance(value, str) or not value.strip():
        raise PacketError(400, f"invalid {what}")
    text = value.strip()
    raw = None
    if HEX_RE.fullmatch(text) and len(text) % 2 == 0:
        raw = bytes.fromhex(text)
    else:
        pad = "=" * (-len(text) % 4)
        for decoder in (base64.b64decode, base64.urlsafe_b64decode):
            try:
                raw = decoder(text + pad, validate=False)
                break
            except (ValueError, TypeError):
                continue
    if raw is None or (expected_len is not None and len(raw) != expected_len):
        raise PacketError(400, f"invalid {what}")
    return raw


def parse_ed25519_public_key(text):
    """32-byte hex/base64, or SPKI PEM (`-----BEGIN PUBLIC KEY-----`)."""
    if not isinstance(text, str) or not text.strip():
        raise PacketError(503, "invalid public key")
    text = text.strip().replace("\\n", "\n")
    if "BEGIN PUBLIC KEY" in text:
        try:
            from cryptography.hazmat.primitives import serialization
        except ImportError as exc:
            raise PacketError(503, "ed25519 unavailable") from exc
        try:
            key = serialization.load_pem_public_key(text.encode("utf-8"))
            raw = key.public_bytes(
                encoding=serialization.Encoding.Raw,
                format=serialization.PublicFormat.Raw,
            )
        except (ValueError, TypeError) as exc:
            raise PacketError(503, "invalid public key") from exc
        if len(raw) != 32:
            raise PacketError(503, "invalid public key")
        return raw
    lines = [
        line.strip()
        for line in text.splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]
    if not lines:
        raise PacketError(503, "invalid public key")
    return _decode_bytes(lines[0], 32, "public key")


def load_pubkey_bytes():
    text = DEFAULT_PUBKEY_HEX
    try:
        with open(PUBKEY_PATH, encoding="utf-8") as f:
            raw_text = f.read().strip()
            if raw_text:
                text = raw_text
    except OSError:
        pass
    return parse_ed25519_public_key(text)


def signed_message(command, timestamp, nonce, device_id, args=None):
    msg = f"{command}.{timestamp}.{nonce}.{device_id}"
    if args is not None:
        msg += "." + json.dumps(args, separators=(",", ":"), sort_keys=True)
    return msg.encode("utf-8")


def _load_nonces():
    try:
        with open(NONCE_PATH, encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, dict):
            return {str(k): int(v) for k, v in data.items()}
    except (OSError, ValueError, TypeError):
        pass
    return {}


def _save_nonces(nonces):
    tmp = NONCE_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(nonces, f, separators=(",", ":"))
    os.replace(tmp, NONCE_PATH)


def consume_nonce(nonce, timestamp, now):
    cutoff = now - TIMESTAMP_SKEW_SEC
    with _nonce_lock:
        nonces = _load_nonces()
        stale = [k for k, ts in nonces.items() if ts < cutoff]
        for k in stale:
            del nonces[k]
        if nonce in nonces:
            raise PacketError(401, "replay")
        nonces[nonce] = int(timestamp)
        _save_nonces(nonces)


def verify_signature(pubkey_bytes, signature, message):
    try:
        from cryptography.exceptions import InvalidSignature
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
    except ImportError as exc:
        raise PacketError(503, "ed25519 unavailable") from exc
    try:
        Ed25519PublicKey.from_public_bytes(pubkey_bytes).verify(signature, message)
    except (InvalidSignature, ValueError) as exc:
        raise PacketError(401, "invalid signature") from exc


def parse_and_verify(body):
    if not isinstance(body, dict):
        raise PacketError(400, "invalid json")

    command = body.get("command")
    if not isinstance(command, str) or not COMMAND_RE.fullmatch(command):
        raise PacketError(400, "invalid command")

    try:
        timestamp = int(body.get("timestamp"))
    except (TypeError, ValueError):
        raise PacketError(400, "invalid timestamp") from None

    nonce = body.get("nonce")
    if not isinstance(nonce, str) or not NONCE_RE.fullmatch(nonce):
        raise PacketError(400, "invalid nonce")

    device_id = body.get("deviceId")
    if not isinstance(device_id, str) or not device_id:
        raise PacketError(400, "invalid deviceId")

    args = body.get("args")
    if args is not None and not isinstance(args, dict):
        raise PacketError(400, "invalid args")

    signature = _decode_bytes(body.get("signature"), 64, "signature")
    message = signed_message(command, timestamp, nonce, device_id, args)
    verify_signature(load_pubkey_bytes(), signature, message)

    serial = cpu_serial()
    if not serial or device_id != serial:
        raise PacketError(401, "wrong device")

    now = int(time.time())
    if abs(now - timestamp) > TIMESTAMP_SKEW_SEC:
        raise PacketError(
            401,
            "expired",
            {"timestamp": timestamp, "serverTime": now},
        )

    consume_nonce(nonce, timestamp, now)
    return {
        "command": command,
        "timestamp": timestamp,
        "nonce": nonce,
        "deviceId": device_id,
        "args": args or {},
    }


def _sudo(argv, timeout=30):
    result = subprocess.run(
        ["sudo", "-n", *argv],
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    if result.returncode != 0:
        err = (result.stderr or result.stdout or "command failed").strip()
        raise CommandError(err)
    return (result.stdout or "").strip()


def _reboot_soon():
    time.sleep(0.4)
    subprocess.run(["sudo", "-n", "reboot"], check=False)


def cmd_info(_packet):
    return info()


def cmd_reboot(_packet):
    threading.Thread(target=_reboot_soon, daemon=True).start()
    return {"scheduled": True}


def cmd_indicate(_packet):
    output = _sudo([INDICATE_PATH], timeout=30)
    return {"output": output}


def cmd_restart_kiosk(_packet):
    _sudo(["systemctl", "restart", "adspace-kiosk.service"], timeout=30)
    return {"restarted": True}


COMMANDS = {
    "info": cmd_info,
    "reboot": cmd_reboot,
    "indicate": cmd_indicate,
    "restart-kiosk": cmd_restart_kiosk,
}


def dispatch(packet):
    handler = COMMANDS.get(packet["command"])
    if handler is None:
        raise PacketError(400, "unknown command")
    return handler(packet)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print(f"adspace-info: {self.address_string()} {fmt % args}", flush=True)

    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")

    def _send(self, status, body):
        data = json.dumps(body, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self._cors()
        self.end_headers()
        self.wfile.write(data)

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.end_headers()

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path in ("/", "/api", "/api/info"):
            self._send(200, info())
        elif path == "/health":
            self._send(200, {"ok": True, "health": health()})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        if path != "/api/command":
            self._send(404, {"error": "not found"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self._send(400, {"error": "invalid content-length"})
            return
        if length < 2 or length > MAX_BODY:
            self._send(400, {"error": "invalid body"})
            return
        raw = self.rfile.read(length)
        try:
            body = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            self._send(400, {"error": "invalid json"})
            return
        try:
            packet = parse_and_verify(body)
            result = dispatch(packet)
        except PacketError as exc:
            payload = {"error": exc.error}
            payload.update(exc.extra)
            self._send(exc.status, payload)
            return
        except subprocess.TimeoutExpired:
            self._send(504, {"error": "command timed out"})
            return
        except CommandError as exc:
            self._send(500, {"error": str(exc)})
            return
        except Exception as exc:
            print(f"adspace-info: command failed: {exc}", flush=True)
            self._send(500, {"error": "command failed"})
            return
        self._send(200, {"ok": True, "command": packet["command"], "result": result})


def main():
    try:
        pubkey_hex = load_pubkey_bytes().hex()
    except PacketError as exc:
        pubkey_hex = f"unavailable ({exc.error})"
    server = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), Handler)
    print(f"Adspace device info listening on {LISTEN_HOST}:{LISTEN_PORT}", flush=True)
    print(f"command pubkey {pubkey_hex}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
DEVICE_INFO_PY

cat > /opt/adspace/command-pubkey << 'EOF'
8079e2154dcb576d3e6b0ba000c909f39ced3d1efe070c9ac8626edc460b6041
EOF
chmod 644 /opt/adspace/command-pubkey

cat > /opt/adspace/kiosk.env << EOF
ADSPACE_URL="${ADSPACE_URL}"
EOF
log "Kiosk URL: $ADSPACE_URL"

chmod +x /opt/adspace/watchdog.sh /opt/adspace/start-display.sh /opt/adspace/indicate.sh /opt/adspace/device-info.py
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
Environment=XCURSOR_THEME=AdspaceBlank
Environment=XCURSOR_SIZE=24

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

cat > /etc/systemd/system/adspace-info.service << 'EOF'
[Unit]
Description=AdSpace Device Info API
After=network.target

[Service]
Type=simple
User=adspace
ExecStart=/usr/bin/python3 /opt/adspace/device-info.py
Restart=always
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
systemctl enable --now adspace-info.service

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
    if [[ -x /opt/adspace/tailscale-install.sh ]]; then
        sh /opt/adspace/tailscale-install.sh
    else
        warn "Bundled Tailscale installer missing — fetching from tailscale.com"
        curl -fsSL https://tailscale.com/install.sh | sh
    fi
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

# ── 16. Beszel agent (outbound WebSocket to hub) ──────────────────────────────
if [[ -n "${BESZEL_HUB_URL}${BESZEL_KEY}${BESZEL_TOKEN}" ]]; then
    [[ -n "$BESZEL_HUB_URL" && -n "$BESZEL_KEY" && -n "$BESZEL_TOKEN" ]] \
        || die "Beszel needs BESZEL_HUB_URL, BESZEL_KEY, and BESZEL_TOKEN"
    if [[ -x /opt/adspace/install-beszel.sh ]]; then
        log "Installing Beszel agent..."
        if ! BESZEL_HUB_URL="$BESZEL_HUB_URL" \
            BESZEL_KEY="$BESZEL_KEY" \
            BESZEL_TOKEN="$BESZEL_TOKEN" \
            /opt/adspace/install-beszel.sh; then
            warn "Beszel agent install failed — continuing without monitoring"
        fi
    else
        warn "install-beszel.sh missing — skip Beszel (re-embed the image to bake it in)"
    fi
else
    log "Beszel credentials not set — skip agent"
fi

# ── 17. Pull release artifacts from GitHub ────────────────────────────────────
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
    if [[ -n "${RELEASE_TAG:-}" && "$RELEASE_TAG" != "null" ]]; then
        write_chromium_ua "$RELEASE_TAG"
    fi
fi

# ── Done ──────────────────────────────────────────────────────────────────────
touch "$DONE_FLAG"

log "========================================================"
log " Bootstrap complete! Hostname: $NEW_HOSTNAME"
log " Rebooting into kiosk in 5 seconds..."
log "========================================================"

sleep 5
reboot
