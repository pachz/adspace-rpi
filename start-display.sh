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
        --load-extension=/opt/adspace/hide-cursor \
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
        --load-extension=/opt/adspace/hide-cursor \
        --user-data-dir=/home/adspace/.config/adspace-chromium \
        "$ADSPACE_URL"
fi
