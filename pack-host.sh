#!/usr/bin/env bash
# =============================================================================
# Pack host agent files into adspace-host.tar.gz
# =============================================================================
# Source of truth is the standalone files in the repo root (+ hide-cursor/).
# embed.sh and qemu-run.sh copy the tarball onto the boot partition;
# bootstrap.sh unpacks it into /opt/adspace. The release job attaches the
# same archive so a later updater can reuse the format.
#
# USAGE:
#   ./pack-host.sh [outfile]
# =============================================================================

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-${REPO_DIR}/adspace-host.tar.gz}"

FILES=(
    watchdog.sh
    start-display.sh
    set-display-mode.sh
    indicate.sh
    device-info.py
    command-pubkey
    hide-cursor/manifest.json
    hide-cursor/hide-cursor.css
)

for f in "${FILES[@]}"; do
    [[ -f "${REPO_DIR}/${f}" ]] || { echo "pack-host: missing ${f}" >&2; exit 1; }
done

mkdir -p "$(dirname "$OUT")"
tar -czf "$OUT" -C "$REPO_DIR" "${FILES[@]}"
echo "pack-host: wrote ${OUT}"
