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
