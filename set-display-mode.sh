#!/usr/bin/env bash
# =============================================================================
# AdSpace display mode — apply a site-preferred HDMI mode if advertised
# =============================================================================
# Cage/wlroots otherwise picks the EDID "preferred" mode (often 1920x1080).
# Some LED processor chains (Oxygen / Kramer) expose the canvas aspect as a
# non-preferred mode (e.g. 1920x960). Switching to that mode displays 2:1
# content without stretch or letterboxing.
#
# Do not hard-code one resolution fleet-wide. This script is a no-op unless
# /opt/adspace/display.env sets DISPLAY_MODE. If that mode is not in the
# current wlr-randr list, the compositor stays on its EDID-preferred mode.
#
# Packaged into adspace-host.tar.gz; start-display.sh runs it in the
# background after Cage is up. Safe to run by hand:
#
#   sudo /opt/adspace/set-display-mode.sh
#   sudo -u adspace env XDG_RUNTIME_DIR=/run/user/$(id -u adspace) \
#     WAYLAND_DISPLAY=wayland-0 wlr-randr
#
# display.env example (Oxygen):
#   DISPLAY_OUTPUT=HDMI-A-2
#   DISPLAY_MODE=1920x960
# =============================================================================

set -u

CONFIG="${DISPLAY_CONFIG:-/opt/adspace/display.env}"
log() { echo "set-display-mode: $*"; }

if [ "$(id -un 2>/dev/null || true)" != "adspace" ]; then
    if [ "$(id -u)" -eq 0 ] && id adspace >/dev/null 2>&1; then
        exec sudo -u adspace env \
            DISPLAY_CONFIG="$CONFIG" \
            XDG_RUNTIME_DIR="/run/user/$(id -u adspace)" \
            WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}" \
            "$0" "$@"
    fi
    log "run as adspace (or root) — skip"
    exit 0
fi

if [ ! -s "$CONFIG" ]; then
    exit 0
fi

# shellcheck disable=SC1090
source "$CONFIG"

MODE="$(printf '%s' "${DISPLAY_MODE:-}" | tr -d '\r')"
OUTPUT="$(printf '%s' "${DISPLAY_OUTPUT:-}" | tr -d '\r')"
RATE_OVERRIDE="$(printf '%s' "${DISPLAY_RATE:-}" | tr -d '\r')"
FALLBACK="$(printf '%s' "${DISPLAY_FALLBACK:-}" | tr -d '\r')"

if [ -z "$MODE" ]; then
    exit 0
fi

if ! printf '%s' "$MODE" | grep -Eq '^[0-9]+x[0-9]+$'; then
    log "invalid DISPLAY_MODE='$MODE' — skip"
    exit 0
fi
if [ -n "$OUTPUT" ] && ! printf '%s' "$OUTPUT" | grep -Eq '^[A-Za-z0-9-]+$'; then
    log "invalid DISPLAY_OUTPUT='$OUTPUT' — skip"
    exit 0
fi

if ! command -v wlr-randr >/dev/null 2>&1; then
    log "wlr-randr not installed — skip"
    exit 0
fi

ADSPACE_UID="$(id -u)"
RUNTIME="${XDG_RUNTIME_DIR:-/run/user/$ADSPACE_UID}"
export XDG_RUNTIME_DIR="$RUNTIME"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"

SOCKET="$RUNTIME/$WAYLAND_DISPLAY"
for _ in $(seq 1 30); do
    [ -S "$SOCKET" ] && break
    sleep 1
done
if [ ! -S "$SOCKET" ]; then
    log "no Wayland socket at $SOCKET — skip"
    exit 0
fi

MODES=""
for _ in $(seq 1 15); do
    MODES="$(wlr-randr 2>/dev/null || true)"
    if printf '%s\n' "$MODES" | grep -q ' px,'; then
        break
    fi
    sleep 1
done
if [ -z "$MODES" ]; then
    log "wlr-randr returned nothing — skip"
    exit 0
fi

# First advertised refresh for MODE on OUTPUT (or any output if unset).
rate_for() {
    local want_out="$1" want_mode="$2"
    printf '%s\n' "$MODES" | awk -v want_out="$want_out" -v want_mode="$want_mode" '
        /^[^[:space:]]/ { out=$1; next }
        $1 == want_mode && $2 == "px," {
            if (want_out == "" || out == want_out) {
                r = $3
                gsub(/,/, "", r)
                print out, r
                exit
            }
        }
    '
}

trim_rate() {
    printf '%s' "$1" | sed 's/0*$//;s/\.$//'
}

apply_mode() {
    local out="$1" mode="$2" rate="$3"
    local spec trimmed
    spec="${mode}@${rate}Hz"
    if wlr-randr --output "$out" --mode "$spec" >/dev/null 2>&1; then
        log "applied ${out} ${spec}"
        return 0
    fi
    trimmed="$(trim_rate "$rate")"
    if [ -n "$trimmed" ] && [ "$trimmed" != "$rate" ]; then
        spec="${mode}@${trimmed}Hz"
        if wlr-randr --output "$out" --mode "$spec" >/dev/null 2>&1; then
            log "applied ${out} ${spec}"
            return 0
        fi
    fi
    log "wlr-randr failed for ${out} ${mode}@${rate}Hz"
    return 1
}

pick="$(rate_for "$OUTPUT" "$MODE")"
if [ -z "$pick" ]; then
    log "mode ${MODE} not advertised${OUTPUT:+ on $OUTPUT} — leave EDID preferred"
    if [ -n "$FALLBACK" ] && printf '%s' "$FALLBACK" | grep -Eq '^[0-9]+x[0-9]+$'; then
        pick="$(rate_for "$OUTPUT" "$FALLBACK")"
        if [ -n "$pick" ]; then
            log "trying fallback ${FALLBACK}"
            apply_mode "${pick%% *}" "$FALLBACK" "${pick##* }" || true
            exit 0
        fi
        log "fallback ${FALLBACK} also missing — skip"
    fi
    exit 0
fi

out="${pick%% *}"
rate="${RATE_OVERRIDE:-${pick##* }}"
apply_mode "$out" "$MODE" "$rate" || true
exit 0
