# AdSpace RPi — Makefile
#
# ── Image prep (prefer the GitHub Release .img.xz; this is the local path) ───
#   make embed IMG=~/Downloads/rpios-lite.img
#
# ── QEMU (Mac, no SD card) ───────────────────────────────────────────────────
#   make qemu                    — boot the embedded image (Ctrl-A X to quit)
#   make qemu-gui                — same, with a QEMU window
#   make qemu QEMU_IMG=path.img  — boot a specific image
#   bash qemu-run.sh --fresh     — recopy and re-run first boot
#   bash qemu-run.sh --fresh --gui
#
# ── Day-to-day deploy (existing Pi) ──────────────────────────────────────────
#   make deploy PI_SSH=pi@adspace-{serial}         — frontend + API
#   make deploy-front PI_SSH=pi@adspace-{serial}   — frontend only
#   make deploy-api PI_SSH=pi@adspace-{serial}     — API binary only
#
# ── Diagnostics ───────────────────────────────────────────────────────────────
#   make logs PI_SSH=pi@adspace-{serial}
#   make screenshot PI_SSH=pi@adspace-{serial}
#   make ssh PI_SSH=pi@adspace-{serial}

PI_SSH ?= $(error PI_SSH is required. Usage: make deploy PI_SSH=pi@adspace-{serial})
IMG    ?= $(error IMG is required. Usage: make embed IMG=~/Downloads/rpios-lite.img)

SSH  = ssh $(PI_SSH)
SCP  = scp
QEMU_IMG ?=

.PHONY: embed deploy deploy-front deploy-api logs screenshot ssh qemu qemu-gui

# ── Image prep ────────────────────────────────────────────────────────────────
embed:
	@bash embed.sh "$(IMG)"

qemu:
	@bash qemu-run.sh $(QEMU_IMG)

qemu-gui:
	@bash qemu-run.sh --gui $(QEMU_IMG)

# ── Day-to-day deploy ─────────────────────────────────────────────────────────
deploy: deploy-front deploy-api

deploy-front:
	$(MAKE) -C wifi-setup deploy PI_SSH=$(PI_SSH)

deploy-api:
	cd wifi-setup-api && GOOS=linux GOARCH=arm64 go build -o wifi-setup-api .
	$(SSH) "sudo systemctl stop adspace-setup-api.service || true"
	$(SCP) wifi-setup-api/wifi-setup-api $(PI_SSH):/tmp/wifi-setup-api-new
	$(SSH) "sudo mv /tmp/wifi-setup-api-new /opt/adspace/wifi-setup-api \
	     && sudo chown adspace:adspace /opt/adspace/wifi-setup-api \
	     && sudo chmod +x /opt/adspace/wifi-setup-api \
	     && sudo systemctl start adspace-setup-api.service || true"

# ── Diagnostics ───────────────────────────────────────────────────────────────
logs:
	$(SSH) "sudo journalctl -u adspace-watchdog -u adspace-kiosk -u adspace-setup-api -u adspace-bootstrap -f"

screenshot:
	$(SSH) "sudo -u adspace sh -c 'WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/run/user/1001 grim /tmp/adspace-screen.png'"
	scp $(PI_SSH):/tmp/adspace-screen.png /tmp/adspace-screen.png
	@echo "Saved to /tmp/adspace-screen.png"
	open /tmp/adspace-screen.png

ssh:
	$(SSH)
