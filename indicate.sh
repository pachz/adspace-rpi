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
