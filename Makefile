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
#   make deploy-info PI_SSH=pi@adspace-{serial}  — device-info.py + command pubkey (localhost:7224)
#   make logs PI_SSH=pi@adspace-{serial}
#   make screenshot PI_SSH=pi@adspace-{serial}
#   make indicate PI_SSH=pi@adspace-{serial}   — blink ACT LED + flash hostname on the TV
#   make ssh PI_SSH=pi@adspace-{serial}

PI_SSH ?= $(error PI_SSH is required. Usage: make deploy PI_SSH=pi@adspace-{serial})
IMG    ?= $(error IMG is required. Usage: make embed IMG=~/Downloads/rpios-lite.img)

SSH  = ssh $(PI_SSH)
SCP  = scp
QEMU_IMG ?=

.PHONY: embed deploy deploy-front deploy-api deploy-info logs screenshot indicate ssh qemu qemu-gui

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

deploy-info:
	$(SCP) device-info.py command-pubkey $(PI_SSH):/tmp/
	$(SSH) "sudo mv /tmp/device-info.py /opt/adspace/device-info.py \
	     && sudo mv /tmp/command-pubkey /opt/adspace/command-pubkey \
	     && sudo chown adspace:adspace /opt/adspace/device-info.py /opt/adspace/command-pubkey \
	     && sudo chmod +x /opt/adspace/device-info.py \
	     && sudo chmod 644 /opt/adspace/command-pubkey \
	     && dpkg -s python3-cryptography >/dev/null 2>&1 \
	        || sudo apt-get install -y python3-cryptography \
	     && printf '%s\n' \
	        'adspace ALL=(ALL) NOPASSWD: /usr/bin/nmcli' \
	        'adspace ALL=(ALL) NOPASSWD: /sbin/reboot' \
	        'adspace ALL=(ALL) NOPASSWD: /usr/sbin/reboot' \
	        'adspace ALL=(ALL) NOPASSWD: /opt/adspace/indicate.sh' \
	        'adspace ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart adspace-kiosk.service' \
	        'adspace ALL=(ALL) NOPASSWD: /bin/systemctl restart adspace-kiosk.service' \
	        | sudo tee /etc/sudoers.d/adspace >/dev/null \
	     && sudo chmod 440 /etc/sudoers.d/adspace \
	     && sudo visudo -cf /etc/sudoers.d/adspace \
	     && printf '%s\n' \
	        '[Unit]' \
	        'Description=AdSpace Device Info API' \
	        'After=network.target' \
	        '' \
	        '[Service]' \
	        'Type=simple' \
	        'User=adspace' \
	        'ExecStart=/usr/bin/python3 /opt/adspace/device-info.py' \
	        'Restart=always' \
	        'RestartSec=3' \
	        'StandardOutput=journal' \
	        'StandardError=journal' \
	        '' \
	        '[Install]' \
	        'WantedBy=multi-user.target' \
	        | sudo tee /etc/systemd/system/adspace-info.service >/dev/null \
	     && sudo systemctl daemon-reload \
	     && sudo systemctl enable --now adspace-info.service \
	     && sudo systemctl restart adspace-info.service""

# ── Diagnostics ───────────────────────────────────────────────────────────────
logs:
	$(SSH) "sudo journalctl -u adspace-watchdog -u adspace-kiosk -u adspace-setup-api -u adspace-info -u adspace-bootstrap -f"

screenshot:
	$(SSH) "sudo -u adspace sh -c 'WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/run/user/1001 grim /tmp/adspace-screen.png'"
	scp $(PI_SSH):/tmp/adspace-screen.png /tmp/adspace-screen.png
	@echo "Saved to /tmp/adspace-screen.png"
	open /tmp/adspace-screen.png

indicate:
	$(SSH) "sudo bash -s" < indicate.sh

ssh:
	$(SSH)
