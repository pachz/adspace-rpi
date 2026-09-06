#!/usr/bin/env bash
# =============================================================================
# AdSpace RPi — QEMU runner (Mac)
# =============================================================================
# Boots the embedded image in QEMU so you can watch cloud-init + bootstrap
# without flashing an SD card.
#
# USAGE:
#   bash qemu-run.sh                         # default: images/adspace-tv-v0.1.9.img
#   bash qemu-run.sh images/adspace-tv.img   # explicit image
#   bash qemu-run.sh --fresh                 # recopy from source (re-run first boot)
#   bash qemu-run.sh --gui                   # Cocoa window instead of serial-only
#   bash qemu-run.sh --fresh --gui
#   make qemu
#   make qemu-gui
#
# SSH (from another terminal, once cloud-init has enabled ssh):
#   ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null pi@127.0.0.1
#   password: adspace
#
# Quit serial mode:  Ctrl-A then X
# Quit GUI mode:     close the QEMU window
#
# HOW IT WORKS:
#   QEMU cannot emulate a Pi 5. We boot the disk image on a generic ARM64
#   `virt` machine with Apple Hypervisor (fast on Apple Silicon) and a
#   Ubuntu ARM64 cloud kernel that has virtio built in. The Pi kernel from
#   the image is BCM-only and cannot see virtio disks/NICs.
#
#   A working copy is used (never mutates the source image). It is grown to
#   16G so apt/chromium during bootstrap has room.
#
#   Apt .deb files are cached. If APT_PROXY is set in .env (apt-cacher-ng on
#   the LAN), the guest uses that. Otherwise a local HTTP proxy on the Mac
#   (images/qemu/apt-proxy/). --fresh still recopies the disk, but packages
#   are served from cache after the first download.
#
# WHAT THIS TESTS:
#   cloud-init, SSH, apt, most of bootstrap.sh, Headscale/Tailscale (if
#   bootstrap gets that far). If HEADSCALE_LOGIN_SERVER is set in .env,
#   the guest joins Headscale instead of Tailscale.com.
#
# WHAT THIS CANNOT TEST:
#   cage / Chromium / HDMI, wlan0 hotspot, WiFi client. Bootstrap may abort
#   at `raspi-config` / `nmcli ... ifname wlan0` because there is no WiFi
#   radio. That is expected — SSH in and read journalctl -u adspace-bootstrap.
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[qemu]${NC} $*"; }
warn() { echo -e "${YELLOW}[qemu]${NC} WARN: $*"; }
die()  { echo -e "${RED}[qemu]${NC} ERROR: $*" >&2; exit 1; }

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${REPO_DIR}/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "${REPO_DIR}/.env"
    set +a
fi
CACHE_DIR="${REPO_DIR}/images/qemu"
WORK_IMG="${REPO_DIR}/images/adspace-tv-qemu.img"
SSH_PORT="${SSH_PORT:-2222}"
RAM_MB="${RAM_MB:-4096}"
DISK_G="${DISK_G:-16}"
APT_PROXY_PORT="${APT_PROXY_PORT:-3142}"
# SLIRP hostfwd IP distinct from the 10.0.2.2 gateway
APT_PROXY_GUEST="10.0.2.253"
FRESH=0
GUI=0

KERNEL_URL="https://cloud-images.ubuntu.com/noble/current/unpacked/noble-server-cloudimg-arm64-vmlinuz-generic"
INITRD_URL="https://cloud-images.ubuntu.com/noble/current/unpacked/noble-server-cloudimg-arm64-initrd-generic"
KERNEL_PATH="${CACHE_DIR}/vmlinuz-generic"
INITRD_PATH="${CACHE_DIR}/initrd-generic"

# ── Args ──────────────────────────────────────────────────────────────────────
SRC_IMG=""
for arg in "$@"; do
    case "$arg" in
        --fresh) FRESH=1 ;;
        --gui) GUI=1 ;;
        -h|--help)
            sed -n '2,35p' "$0"
            exit 0
            ;;
        *)
            [[ -z "$SRC_IMG" ]] || die "Unexpected argument: $arg"
            SRC_IMG="$arg"
            ;;
    esac
done

if [[ -z "$SRC_IMG" ]]; then
    for candidate in \
        "${REPO_DIR}/images/adspace-tv-v0.1.9.img" \
        "${REPO_DIR}/images/adspace-tv.img"
    do
        if [[ -f "$candidate" ]]; then
            SRC_IMG="$candidate"
            break
        fi
    done
fi
[[ -n "$SRC_IMG" && -f "$SRC_IMG" ]] \
    || die "No image found. Build one first:\n  bash embed.sh <rpios-lite.img> images/adspace-tv-v0.1.9.img"

# ── qemu ──────────────────────────────────────────────────────────────────────
ensure_qemu() {
    if command -v qemu-system-aarch64 >/dev/null 2>&1 \
        && command -v qemu-img >/dev/null 2>&1; then
        return 0
    fi
    command -v brew >/dev/null 2>&1 \
        || die "qemu-system-aarch64 not found. Install with: brew install qemu"
    log "Installing qemu via Homebrew (one-time)..."
    brew install qemu
    command -v qemu-system-aarch64 >/dev/null 2>&1 \
        || die "brew install qemu succeeded but qemu-system-aarch64 is not on PATH"
}

# ── Kernel / initrd (Ubuntu cloud, virtio built in) ───────────────────────────
ensure_kernel() {
    mkdir -p "$CACHE_DIR"
    if [[ ! -s "$KERNEL_PATH" ]]; then
        log "Downloading ARM64 virt kernel..."
        curl -fL --progress-bar -o "${KERNEL_PATH}.partial" "$KERNEL_URL"
        mv "${KERNEL_PATH}.partial" "$KERNEL_PATH"
    fi
    if [[ ! -s "$INITRD_PATH" ]]; then
        log "Downloading ARM64 virt initrd..."
        curl -fL --progress-bar -o "${INITRD_PATH}.partial" "$INITRD_URL"
        mv "${INITRD_PATH}.partial" "$INITRD_PATH"
    fi
    # Ubuntu arm64 vmlinuz is an EFI zboot image. QEMU -kernel wants a raw
    # Image; unwrap gzip payload if present.
    if [[ ! -s "${CACHE_DIR}/Image" ]]; then
        python3 - "$KERNEL_PATH" "${CACHE_DIR}/Image" << 'PY'
import gzip, pathlib, sys
src, dst = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
data = src.read_bytes()
# Already a raw ARM64 Image (magic at 0x38)
if data[0x38:0x3c] == b"ARM\x64":
    dst.write_bytes(data)
    raise SystemExit(0)
idx = data.find(b"\x1f\x8b")
if idx < 0:
    # Try as whole-file gzip
    try:
        payload = gzip.decompress(data)
    except OSError as e:
        raise SystemExit(f"unrecognized kernel format: {e}") from e
else:
    payload = gzip.decompress(data[idx:])
dst.write_bytes(payload)
PY
        log "Unwrapped kernel Image ($(du -h "${CACHE_DIR}/Image" | awk '{print $1}'))"
    fi
}

# ── Apt .deb cache (survives --fresh; indexes stay live) ──────────────────────
proxy_port_open() {
    python3 -c 'import socket,sys; s=socket.socket(); s.settimeout(0.3)
s.connect(("127.0.0.1", int(sys.argv[1]))); s.close()' "$1" 2>/dev/null
}

ensure_apt_proxy() {
    mkdir -p "${CACHE_DIR}/apt-proxy"
    if proxy_port_open "$APT_PROXY_PORT"; then
        log "apt cache proxy already on 127.0.0.1:${APT_PROXY_PORT}"
    else
        log "Starting apt cache proxy on 127.0.0.1:${APT_PROXY_PORT}"
        nohup python3 "${REPO_DIR}/qemu-apt-proxy.py" \
            --port "$APT_PROXY_PORT" \
            --dir "${CACHE_DIR}/apt-proxy" \
            >> "${CACHE_DIR}/apt-proxy.log" 2>&1 &
        echo $! > "${CACHE_DIR}/apt-proxy.pid"
        local i
        for i in $(seq 1 20); do
            proxy_port_open "$APT_PROXY_PORT" && break
            sleep 0.1
        done
        proxy_port_open "$APT_PROXY_PORT" \
            || die "apt cache proxy did not start (see ${CACHE_DIR}/apt-proxy.log)"
    fi
    local cache_size
    cache_size=$(du -sh "${CACHE_DIR}/apt-proxy" 2>/dev/null | awk '{print $1}')
    log "apt .deb cache: ${cache_size:-0}  (${CACHE_DIR}/apt-proxy)"
}

# ── Working copy: APFS clone + grow partition ─────────────────────────────────
prepare_disk() {
    mkdir -p "${REPO_DIR}/images"
    if [[ "$FRESH" -eq 1 || ! -f "$WORK_IMG" ]]; then
        log "Creating working copy from $(basename "$SRC_IMG")..."
        rm -f "$WORK_IMG"
        if cp -c "$SRC_IMG" "$WORK_IMG" 2>/dev/null; then
            :
        else
            cp "$SRC_IMG" "$WORK_IMG"
        fi
    else
        log "Reusing $(basename "$WORK_IMG") (pass --fresh to recopy)"
    fi

    log "Resizing working copy to ${DISK_G}G..."
    qemu-img resize -f raw "$WORK_IMG" "${DISK_G}G" >/dev/null

    python3 - "$WORK_IMG" << 'PY'
import struct, sys
path = sys.argv[1]
with open(path, "r+b") as f:
    f.seek(0, 2)
    total = f.tell() // 512
    f.seek(510)
    if f.read(2) != b"\x55\xaa":
        raise SystemExit("not an MBR image")
    f.seek(446 + 16)
    entry = bytearray(f.read(16))
    ptype = entry[4]
    start, sectors = struct.unpack_from("<II", entry, 8)
    if ptype == 0 or start == 0:
        raise SystemExit("partition 2 missing")
    new_sectors = total - start
    if new_sectors <= sectors:
        print(f"partition 2 already {sectors} sectors")
        raise SystemExit(0)
    struct.pack_into("<II", entry, 8, start, new_sectors)
    f.seek(446 + 16)
    f.write(entry)
    print(f"partition 2 grown {sectors} -> {new_sectors} sectors")
PY

    patch_user_data
}

patch_user_data() {
    # Inject a one-shot resize2fs so the guest fs fills the grown partition.
    local hdiutil_out
    hdiutil_out=$(hdiutil attach "$WORK_IMG" \
        -imagekey diskimage-class=CRawDiskImage -nomount 2>&1) || \
        die "hdiutil attach failed:\n$hdiutil_out"
    QEMU_WHOLE=$(echo "$hdiutil_out" | awk 'NR==1{print $1}')
    QEMU_FAT=$(echo "$hdiutil_out" | awk '/Windows_FAT/{print $1}' | head -1)
    QEMU_MNT=$(mktemp -d)
    cleanup_boot() {
        sync 2>/dev/null || true
        umount "$QEMU_MNT" 2>/dev/null || diskutil unmount force "$QEMU_FAT" 2>/dev/null || true
        rmdir "$QEMU_MNT" 2>/dev/null || true
        hdiutil detach "$QEMU_WHOLE" 2>/dev/null || true
    }
    trap cleanup_boot EXIT
    [[ -n "$QEMU_FAT" ]] || die "No FAT boot partition in working copy"
    mount_msdos "$QEMU_FAT" "$QEMU_MNT" || die "Could not mount boot partition"
    python3 - "$QEMU_MNT/user-data" "$APT_PROXY_GUEST" "$APT_PROXY_PORT" "${APT_PROXY:-}" << 'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
guest, port, lan_proxy = sys.argv[2], sys.argv[3], sys.argv[4]
text = p.read_text()
needle = "users:"
if needle not in text:
    raise SystemExit("user-data missing users: block")

if "qemu-growfs" not in text:
    text = text.replace(
        needle,
        "# qemu-growfs — expand root fs to fill the resized virt disk\n"
        "bootcmd:\n"
        "  - resize2fs /dev/vda2 || true\n"
        "\n" + needle,
        1,
    )
    print("injected resize2fs bootcmd")

proxy_line = (
    f"  - echo 'Acquire::http::Proxy \"http://{guest}:{port}\";' "
    f"> /etc/apt/apt.conf.d/01qemu-proxy"
)
if lan_proxy.strip():
    print("skipping qemu apt proxy (APT_PROXY set)")
elif "01qemu-proxy" not in text:
    if "  - resize2fs /dev/vda2 || true\n" not in text:
        raise SystemExit("bootcmd missing resize2fs; cannot inject apt proxy")
    extra = (
        "  - mkdir -p /etc/apt/apt.conf.d\n"
        f"{proxy_line}\n"
        "  - echo 'Acquire::https::Proxy \"DIRECT\";' "
        ">> /etc/apt/apt.conf.d/01qemu-proxy\n"
    )
    text = text.replace(
        "  - resize2fs /dev/vda2 || true\n",
        "  - resize2fs /dev/vda2 || true\n" + extra,
        1,
    )
    print("injected apt proxy bootcmd")

p.write_text(text)
PY
    # Always refresh baked-in bootstrap so --fresh picks up local edits
    # without re-running embed.sh.
    python3 - "$QEMU_MNT/user-data" "${REPO_DIR}/bootstrap.sh" << 'PY'
from pathlib import Path
import sys
ud_path, bs_path = Path(sys.argv[1]), Path(sys.argv[2])
ud = ud_path.read_text()
bootstrap = bs_path.read_text()
start = "  - path: /opt/adspace/bootstrap.sh"
end = "  - path: /etc/systemd/system/adspace-bootstrap.service"
i, j = ud.find(start), ud.find(end)
if i < 0 or j < 0 or j <= i:
    raise SystemExit("user-data missing bootstrap.sh write_files block")
indent = "      "
body = "\n".join(
    (indent + line) if line else indent.rstrip()
    for line in bootstrap.splitlines()
)
header = (
    "  - path: /opt/adspace/bootstrap.sh\n"
    "    permissions: '0755'\n"
    "    owner: root:root\n"
    "    content: |\n"
)
ud_path.write_text(ud[:i] + header + body + "\n\n" + ud[j:])
print("refreshed bootstrap.sh in user-data")
PY
    python3 - "$QEMU_MNT/user-data" "${REPO_DIR}/tailscale-install.sh" << 'PY'
from pathlib import Path
import sys
ud_path, src_path = Path(sys.argv[1]), Path(sys.argv[2])
ud = ud_path.read_text()
src = src_path.read_text()
start = "  - path: /opt/adspace/tailscale-install.sh"
end = "\n# Enable SSH and bootstrap service\n"
i, j = ud.find(start), ud.find(end)
if i < 0 or j < 0 or j <= i:
    print("user-data has no tailscale-install.sh block — skip refresh (re-embed to add it)")
else:
    indent = "      "
    body = "\n".join(
        (indent + line) if line else indent.rstrip()
        for line in src.splitlines()
    )
    header = (
        "  - path: /opt/adspace/tailscale-install.sh\n"
        "    permissions: '0755'\n"
        "    owner: root:root\n"
        "    content: |\n"
    )
    ud_path.write_text(ud[:i] + header + body + "\n" + ud[j:])
    print("refreshed tailscale-install.sh in user-data")
PY
    if [[ -n "${HEADSCALE_LOGIN_SERVER:-}" ]]; then
        [[ -n "${HEADSCALE_AUTH_KEY:-}" ]] \
            || die "HEADSCALE_LOGIN_SERVER is set but HEADSCALE_AUTH_KEY is empty"
        cat > "$QEMU_MNT/adspace-tailnet.env" << EOF
HEADSCALE_LOGIN_SERVER=${HEADSCALE_LOGIN_SERVER}
HEADSCALE_AUTH_KEY=${HEADSCALE_AUTH_KEY}
EOF
        log "Headscale: guest will join ${HEADSCALE_LOGIN_SERVER}"
    fi
    if [[ -n "${APT_PROXY:-}" ]]; then
        cat > "$QEMU_MNT/adspace-apt.env" << EOF
APT_PROXY=${APT_PROXY}
EOF
        log "Apt proxy: guest will use ${APT_PROXY}"
    fi
    if [[ -n "${ADSPACE_URL:-}" ]]; then
        [[ "$ADSPACE_URL" =~ ^https?://[^[:space:]]+$ ]] \
            || die "Invalid ADSPACE_URL: $ADSPACE_URL"
        cat > "$QEMU_MNT/adspace-kiosk.env" << EOF
ADSPACE_URL=${ADSPACE_URL}
EOF
        log "Kiosk URL: guest will use ${ADSPACE_URL}"
    fi
    if [[ -z "${ADSPACE_VERSION:-}" ]]; then
        ADSPACE_VERSION=$(git -C "$REPO_DIR" describe --tags --always 2>/dev/null || true)
    fi
    if [[ -n "${ADSPACE_VERSION:-}" ]]; then
        cat > "$QEMU_MNT/adspace-version.env" << EOF
ADSPACE_VERSION=${ADSPACE_VERSION}
EOF
        log "Version: guest will use ${ADSPACE_VERSION}"
    fi
    cleanup_boot
    trap - EXIT
}

# ── Launch ────────────────────────────────────────────────────────────────────
accel_args() {
    if [[ "$(uname -m)" == "arm64" ]] && sysctl -n kern.hv_support 2>/dev/null | grep -q 1; then
        echo hvf host
    else
        echo tcg cortex-a72
    fi
}

run_vm() {
    local accel cpu append
    read -r accel cpu <<<"$(accel_args)"
    append="root=/dev/vda2 rw rootfstype=ext4 rootwait fsck.repair=yes console=ttyAMA0,115200 net.ifnames=0 biosdevname=0 systemd.unified_cgroup_hierarchy=1 systemd.mask=systemd-networkd-wait-online.service"

    local -a extra=()
    if [[ "$GUI" -eq 1 ]]; then
        append+=" console=tty0"
        extra+=(
            -display cocoa
            -device virtio-gpu-pci
            -device virtio-keyboard-pci
            -device virtio-mouse-pci
        )
        log "Display: Cocoa window (virtio-gpu)"
    else
        extra+=(-nographic)
    fi

    log "Machine: virt  accel=${accel}  cpu=${cpu}  ram=${RAM_MB}M  ssh=localhost:${SSH_PORT}"
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [[ "$GUI" -eq 1 ]]; then
        echo "  GUI window + serial. Boot/login appear in the QEMU window."
        echo "  Quit:     close the QEMU window"
    else
        echo "  Serial console attached. Bootstrap logs will stream here."
        echo "  Quit:     Ctrl-A then X"
        echo "  GUI:      bash qemu-run.sh --gui"
    fi
    echo
    echo "  SSH:      ssh -p ${SSH_PORT} pi@127.0.0.1"
    echo "  Password: adspace"
    if [[ -n "${APT_PROXY:-}" ]]; then
        echo "  Apt cache: ${APT_PROXY}"
    else
        echo "  Apt cache: ${CACHE_DIR}/apt-proxy  (proxy ${APT_PROXY_GUEST}:${APT_PROXY_PORT})"
    fi
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo

    exec qemu-system-aarch64 \
        -machine virt,accel="${accel}",gic-version=3 \
        -cpu "${cpu}" \
        -smp 4 \
        -m "${RAM_MB}" \
        -kernel "${CACHE_DIR}/Image" \
        -initrd "$INITRD_PATH" \
        -append "$append" \
        -drive "if=none,file=${WORK_IMG},format=raw,id=hd0,cache=writeback" \
        -device virtio-blk-pci,drive=hd0,bootindex=1 \
        -netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22,guestfwd=tcp:${APT_PROXY_GUEST}:${APT_PROXY_PORT}-cmd:nc 127.0.0.1 ${APT_PROXY_PORT}" \
        -device virtio-net-pci,netdev=net0 \
        -device virtio-rng-pci \
        -serial mon:stdio \
        "${extra[@]}"
}

ensure_qemu
ensure_kernel
if [[ -z "${APT_PROXY:-}" ]]; then
    ensure_apt_proxy
fi
prepare_disk
run_vm
