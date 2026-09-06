#!/usr/bin/env bash
# =============================================================================
# AdSpace RPi — Embed Script
# =============================================================================
# Injects bootstrap.sh + adspace-bootstrap.service into a vanilla
# Raspberry Pi OS Lite 64-bit .img file so it self-provisions on first boot.
#
# USAGE:
#   ./embed.sh <path-to-rpios-lite.img> [output.img]
#
# EXAMPLE:
#   ./embed.sh ~/Downloads/2026-06-18-raspios-trixie-arm64-lite.img images/adspace-tv-v0.1.5.img
#
# REQUIREMENTS:
#   macOS:  hdiutil + python3 (built in)
#   Linux:  python3, sfdisk (util-linux), sudo for losetup/mount
#
# HOW IT WORKS:
#   This RPi OS Trixie image uses cloud-init (not the firstboot/firstrun.sh
#   mechanism). We replace user-data with a cloud-init config that:
#     - Creates the pi user with a known password
#     - Enables SSH with password authentication
#     - Copies bootstrap.sh into /opt/adspace/ via write_files
#     - Installs and enables adspace-bootstrap.service via write_files
#     - Runs bootstrap.sh on first boot via runcmd
#
#   All files also placed on the boot partition so cloud-init can reference them.
#
#   Optional: HEADSCALE_LOGIN_SERVER + HEADSCALE_AUTH_KEY (env or .env)
#   write adspace-tailnet.env onto the boot partition so bootstrap joins
#   Headscale instead of Tailscale.com. CI sources .env.example for this.
#
#   Optional: APT_PROXY (env or .env) writes adspace-apt.env so bootstrap
#   apt-get goes through a local apt-cacher-ng. The CI *dev* image sets
#   this; the prod image does not.
#
#   Optional: ADSPACE_URL (env or .env) writes adspace-kiosk.env so the
#   kiosk opens that URL. Default in bootstrap is https://screen.adspace.so.
#   The CI *dev* image sets https://dev.adspace.live.
#
#   ADSPACE_VERSION (env, or `git describe --tags --always`) is written to
#   adspace-version.env so bootstrap stamps Chromium's UA as AdspaceTV/rpi-<tag>.
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[embed]${NC} $*"; }
warn() { echo -e "${YELLOW}[embed]${NC} WARN: $*"; }
die()  { echo -e "${RED}[embed]${NC} ERROR: $*" >&2; exit 1; }

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OS="$(uname -s)"
if [[ -f "${REPO_DIR}/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "${REPO_DIR}/.env"
    set +a
fi

# ── Credentials ───────────────────────────────────────────────────────────────
PI_PASSWORD="adspace"

# ── Args ──────────────────────────────────────────────────────────────────────
INPUT_IMG="${1:-}"
OUTPUT_IMG="${2:-${REPO_DIR}/images/adspace-tv.img}"

[[ -n "$INPUT_IMG" ]]  || die "Usage: ./embed.sh <rpios-lite.img> [output.img]"
[[ -f "$INPUT_IMG" ]]  || die "Input image not found: $INPUT_IMG"
[[ -f "$REPO_DIR/bootstrap.sh" ]] \
    || die "bootstrap.sh not found in repo root"
[[ -f "$REPO_DIR/adspace-bootstrap.service" ]] \
    || die "adspace-bootstrap.service not found in repo root"
[[ "$OS" == "Darwin" || "$OS" == "Linux" ]] \
    || die "Unsupported OS: $OS (need macOS or Linux)"

log "Input:  $INPUT_IMG"
log "Output: $OUTPUT_IMG"

mkdir -p "$(dirname "$OUTPUT_IMG")"

# ── Copy image (skip when embedding in place) ─────────────────────────────────
INPUT_REAL=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$INPUT_IMG")
OUTPUT_REAL=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$OUTPUT_IMG")
if [[ "$INPUT_REAL" != "$OUTPUT_REAL" ]]; then
    log "Copying image..."
    cp "$INPUT_IMG" "$OUTPUT_IMG"
else
    log "Embedding in place (input and output are the same file)"
fi

# ── Attach + mount boot partition ─────────────────────────────────────────────
MOUNT_DIR=$(mktemp -d)
WHOLE_DISK=""
DISK_DEV=""
LOOP_DEV=""

cleanup() {
    sync 2>/dev/null || true
    if [[ -n "${MOUNT_DIR:-}" ]]; then
        if [[ "$OS" == "Darwin" ]]; then
            umount "$MOUNT_DIR" 2>/dev/null \
                || diskutil unmount force "${DISK_DEV:-}" 2>/dev/null \
                || true
        else
            sudo umount "$MOUNT_DIR" 2>/dev/null || true
        fi
        rmdir "$MOUNT_DIR" 2>/dev/null || true
    fi
    if [[ "$OS" == "Darwin" && -n "${WHOLE_DISK:-}" ]]; then
        hdiutil detach "$WHOLE_DISK" 2>/dev/null || true
    elif [[ -n "${LOOP_DEV:-}" ]]; then
        sudo losetup -d "$LOOP_DEV" 2>/dev/null || true
    fi
}
trap cleanup EXIT

log "Attaching image..."

if [[ "$OS" == "Darwin" ]]; then
    HDIUTIL_OUT=$(hdiutil attach "$OUTPUT_IMG" \
        -imagekey diskimage-class=CRawDiskImage -nomount 2>&1)

    WHOLE_DISK=$(echo "$HDIUTIL_OUT" | awk 'NR==1{print $1}')
    DISK_DEV=$(echo "$HDIUTIL_OUT"   | awk '/Windows_FAT/{print $1}' | head -1)

    [[ -n "$DISK_DEV" ]] || {
        hdiutil detach "$WHOLE_DISK" 2>/dev/null || true
        die "Could not find FAT32 boot partition.\nhdiutil output:\n$HDIUTIL_OUT"
    }

    mount_msdos "$DISK_DEV" "$MOUNT_DIR" \
        || die "Could not mount boot partition ($DISK_DEV)"
else
    command -v sfdisk >/dev/null 2>&1 || die "sfdisk not found (install util-linux)"

    LOOP_DEV=$(sudo losetup -P --find --show "$OUTPUT_IMG")
    BOOT_PART=""
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if [[ -b "${LOOP_DEV}p1" ]]; then
            BOOT_PART="${LOOP_DEV}p1"
            break
        fi
        sleep 0.3
    done

    if [[ -n "$BOOT_PART" ]]; then
        sudo mount -t vfat -o "uid=$(id -u),gid=$(id -g)" \
            "$BOOT_PART" "$MOUNT_DIR" \
            || die "Could not mount boot partition ($BOOT_PART)"
    else
        # Partition nodes did not appear — offset-mount partition 1 instead.
        START=$(sfdisk --json "$OUTPUT_IMG" | python3 -c \
            "import json,sys; print(json.load(sys.stdin)['partitiontable']['partitions'][0]['start'])")
        SECTOR=$(sfdisk --json "$OUTPUT_IMG" | python3 -c \
            "import json,sys; print(json.load(sys.stdin)['partitiontable'].get('sectorsize', 512))")
        sudo losetup -d "$LOOP_DEV" 2>/dev/null || true
        LOOP_DEV=""
        sudo mount -t vfat \
            -o "loop,offset=$((START * SECTOR)),uid=$(id -u),gid=$(id -g)" \
            "$OUTPUT_IMG" "$MOUNT_DIR" \
            || die "Could not mount boot partition (offset $((START * SECTOR)))"
    fi
fi

log "Mounted at $MOUNT_DIR"

# ── Hash the password ─────────────────────────────────────────────────────────
# LibreSSL (macOS /usr/bin/openssl) does not support `passwd -6` (SHA-512 crypt).
# Prefer OpenSSL 3 if present (Homebrew / Linux); otherwise a Python SHA-512 crypt.
hash_password() {
    local pw="$1" candidate hashed
    for candidate in \
        /opt/homebrew/opt/openssl@3/bin/openssl \
        /opt/homebrew/bin/openssl \
        /usr/local/opt/openssl@3/bin/openssl \
        openssl
    do
        if command -v "$candidate" >/dev/null 2>&1 \
            && hashed=$(printf '%s' "$pw" | "$candidate" passwd -6 -stdin 2>/dev/null) \
            && [[ "$hashed" == \$6\$* ]]; then
            printf '%s\n' "$hashed"
            return 0
        fi
    done
    python3 -c '
import hashlib, os, sys
ITOA64 = "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
def to64(v, n):
    r = []
    for _ in range(n):
        r.append(ITOA64[v & 0x3f]); v >>= 6
    return "".join(r)
password = sys.argv[1].encode()
salt = "".join(ITOA64[b % 64] for b in os.urandom(16)).encode()
rounds = 5000
digest_b = hashlib.sha512(password + salt + password).digest()
a = hashlib.sha512(password + salt)
i = len(password)
while i > 64:
    a.update(digest_b); i -= 64
a.update(digest_b[:i])
i = len(password)
while i:
    a.update(digest_b if i & 1 else password)
    i >>= 1
digest_a = a.digest()
da = hashlib.sha512()
for _ in range(len(password)):
    da.update(password)
da = da.digest()
ds = hashlib.sha512()
for _ in range(16 + digest_a[0]):
    ds.update(salt)
ds = ds.digest()
P = (da * (len(password) // 64 + 1))[:len(password)]
S = ds[:len(salt)]
C = digest_a
for i in range(rounds):
    ctx = hashlib.sha512()
    ctx.update(P if i & 1 else C)
    if i % 3: ctx.update(S)
    if i % 7: ctx.update(P)
    ctx.update(C if i & 1 else P)
    C = ctx.digest()
order = (
    (0,21,42),(22,43,1),(44,2,23),(3,24,45),(25,46,4),(47,5,26),
    (6,27,48),(28,49,7),(50,8,29),(9,30,51),(31,52,10),(53,11,32),
    (12,33,54),(34,55,13),(56,14,35),(15,36,57),(37,58,16),(59,17,38),
    (18,39,60),(40,61,19),(62,20,41),
)
out = "".join(to64((C[x] << 16) | (C[y] << 8) | C[z], 4) for x,y,z in order)
out += to64(C[63], 2)
print("$6$" + salt.decode() + "$" + out)
' "$pw"
}

HASHED=$(hash_password "$PI_PASSWORD")
[[ "$HASHED" == \$6\$* ]] || die "Failed to generate SHA-512 password hash"

# ── Write cloud-init user-data ────────────────────────────────────────────────
# Use Python to build user-data — avoids shell variable expansion mangling
# bootstrap.sh content (which contains $VAR, $(), etc.).
log "Writing cloud-init user-data..."
python3 - "$REPO_DIR/bootstrap.sh" \
          "$REPO_DIR/adspace-bootstrap.service" \
          "$MOUNT_DIR/user-data" \
          "$HASHED" << 'PYEOF'
import sys, textwrap

bootstrap_path, service_path, out_path, hashed = sys.argv[1:]

bootstrap = open(bootstrap_path).read()
service   = open(service_path).read()

def indent(text, spaces=6):
    pad = ' ' * spaces
    return '\n'.join(pad + line for line in text.splitlines())

user_data = f"""#cloud-config

# AdSpace — first boot provisioning via cloud-init

# Create pi user with known password and sudo access
users:
  - name: pi
    gecos: Pi User
    groups: [adm, dialout, cdrom, sudo, audio, video, plugdev, games, users, input, render, netdev, spi, i2c, gpio]
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    passwd: "{hashed}"
    ssh_authorized_keys:
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAID4b09qcgIfg0la+WsmLa7cFUyxIDvfzKbwtTMuFozOs adspace-fleet-management

# Enable SSH with password authentication
ssh_pwauth: true

# Write bootstrap.sh and service unit directly to the filesystem
write_files:
  - path: /opt/adspace/bootstrap.sh
    permissions: '0755'
    owner: root:root
    content: |
{indent(bootstrap)}

  - path: /etc/systemd/system/adspace-bootstrap.service
    permissions: '0644'
    owner: root:root
    content: |
{indent(service)}

# Enable SSH and bootstrap service
runcmd:
  - systemctl enable ssh
  - systemctl start ssh
  - systemctl enable adspace-bootstrap.service
  - systemctl start adspace-bootstrap.service
"""

open(out_path, 'w').write(user_data)
PYEOF

log "user-data written ($(wc -l < "$MOUNT_DIR/user-data") lines)"

if [[ -n "${HEADSCALE_LOGIN_SERVER:-}" ]]; then
    [[ -n "${HEADSCALE_AUTH_KEY:-}" ]] \
        || die "HEADSCALE_LOGIN_SERVER is set but HEADSCALE_AUTH_KEY is empty"
    cat > "$MOUNT_DIR/adspace-tailnet.env" << EOF
HEADSCALE_LOGIN_SERVER=${HEADSCALE_LOGIN_SERVER}
HEADSCALE_AUTH_KEY=${HEADSCALE_AUTH_KEY}
EOF
    log "Headscale: image will join ${HEADSCALE_LOGIN_SERVER}"
fi

if [[ -n "${APT_PROXY:-}" ]]; then
    cat > "$MOUNT_DIR/adspace-apt.env" << EOF
APT_PROXY=${APT_PROXY}
EOF
    log "Apt proxy: ${APT_PROXY}"
fi

if [[ -n "${ADSPACE_URL:-}" ]]; then
    [[ "$ADSPACE_URL" =~ ^https?://[^[:space:]]+$ ]] \
        || die "Invalid ADSPACE_URL: $ADSPACE_URL"
    cat > "$MOUNT_DIR/adspace-kiosk.env" << EOF
ADSPACE_URL=${ADSPACE_URL}
EOF
    log "Kiosk URL: ${ADSPACE_URL}"
fi

if [[ -z "${ADSPACE_VERSION:-}" ]]; then
    ADSPACE_VERSION=$(git -C "$REPO_DIR" describe --tags --always 2>/dev/null || true)
fi
if [[ -n "${ADSPACE_VERSION:-}" ]]; then
    cat > "$MOUNT_DIR/adspace-version.env" << EOF
ADSPACE_VERSION=${ADSPACE_VERSION}
EOF
    log "Version: ${ADSPACE_VERSION}"
fi

log "Boot partition key files:"
ls -lh "$MOUNT_DIR/user-data" "$MOUNT_DIR/meta-data" \
    "$MOUNT_DIR/adspace-tailnet.env" "$MOUNT_DIR/adspace-apt.env" \
    "$MOUNT_DIR/adspace-kiosk.env" "$MOUNT_DIR/adspace-version.env" \
    2>/dev/null || true

log "Unmounting..."

log ""
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "  Image ready: $OUTPUT_IMG"
log ""
log "  Flash with Raspberry Pi Imager — no customisation needed."
log "  pi user password: $PI_PASSWORD"
log ""
log "  On first boot (plug in ethernet):"
log "    Boot 1: cloud-init runs — creates pi user, enables SSH,"
log "            installs bootstrap.sh, starts adspace-bootstrap.service"
log "    ~10 min: bootstrap installs everything, registers Tailscale"
log "    After:   Kiosk is live at ${ADSPACE_URL:-https://screen.adspace.so}"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
