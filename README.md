# AdSpace RPi — Digital Signage OS

This repo contains everything needed to turn a **Raspberry Pi 5** into an AdSpace digital signage device — from first boot to a fully self-managing kiosk that handles WiFi setup, network loss recovery, and remote management.

---

## Table of Contents

1. [Onboarding — new developer setup](#onboarding--new-developer-setup)
2. [How it works](#how-it-works)
3. [Repository layout](#repository-layout)
4. [Pi file layout](#pi-file-layout)
5. [Quick start — setting up a new Pi](#quick-start--setting-up-a-new-pi)
6. [Day-to-day development](#day-to-day-development)
7. [Connecting to the Pi](#connecting-to-the-pi)
8. [Debugging](#debugging)
9. [Testing bootstrap (without reflashing)](#testing-bootstrap-without-reflashing)
10. [Pi naming](#pi-naming)
11. [Architecture decisions](#architecture-decisions)

---

## Onboarding — new developer setup

Do this once when you join the team. Takes about 5 minutes.

### 1. Join Tailscale
Tailscale is how you SSH into any Pi from anywhere — no VPN config, no IP addresses, just device names.

- Go to [tailscale.com](https://tailscale.com)
- Click **Log in** → **Continue with Google**
- Sign in with **dev@adspace.so**
- Download and install the Tailscale app for your Mac: [tailscale.com/download](https://tailscale.com/download/mac)
- Open the app, sign in with the same Google account
- You're now on the AdSpace network — all Pis are immediately reachable by name

### 2. Install dev tools
```bash
brew install go pnpm
```

That's it. You can now SSH into any Pi and set up new ones.

> **No auth keys needed.** Tailscale OAuth credentials are embedded in `bootstrap.sh` — Pis self-register on first boot. You only need to be on the AdSpace Tailscale account.

---

## How it works

### Normal boot (WiFi already configured)
```
Boot → adspace-watchdog starts
     → detects network (ethernet or WiFi)
     → calls enter_kiosk()
     → starts adspace-kiosk (cage → Chromium → https://screen.adspace.so)
```

### First boot / no network
```
Boot → adspace-watchdog starts
     → no network detected
     → scans for nearby WiFi networks (before hotspot starts)
     → brings up adspace-hotspot (AP on wlan0, SSID = Adspace-TV-{cpu_serial})
     → starts Caddy + setup API
     → starts adspace-kiosk (cage → Chromium → http://localhost/tv)
     → TV shows QR code + hotspot credentials

Technician connects phone to Adspace-TV-xxxxxxxx
     → opens http://192.168.4.1 (captive portal fires automatically)
     → sees WiFi setup page with scanned networks (or manual input)
     → submits credentials → sees "Attempting to connect" message

API receives credentials
     → returns ok immediately (before hotspot drops)
     → brings down hotspot in background
     → connects wlan0 to submitted network (up to 30s)
     → watchdog detects network up within 15s
     → calls enter_kiosk() → TV switches to kiosk URL
     → if connect fails: hotspot restored, technician can retry
```

### Network loss recovery
```
WiFi drops → watchdog detects no network → enter_setup()
Every ~60s in setup mode → try_reconnect():
     → brings hotspot down for 20s
     → NetworkManager attempts saved WiFi profiles
     → if connected: enter_kiosk()
     → if not: restore hotspot, keep showing setup screen
```

---

## Repository layout

```
rpi/
├── bootstrap.sh              # Full provisioning — runs on Pi first boot, installs everything
├── adspace-bootstrap.service # Systemd unit that runs bootstrap.sh once on first boot
├── embed.sh                  # Injects bootstrap into vanilla RPi OS .img (macOS or Linux)
├── watchdog.sh               # Source copy of /opt/adspace/watchdog.sh (also embedded in bootstrap.sh)
├── start-display.sh          # Source copy of /opt/adspace/start-display.sh (also embedded in bootstrap.sh)
├── kiosk.env                 # Source copy of /opt/adspace/kiosk.env
├── Makefile                  # Root: embed, deploy, logs, screenshot, ssh targets
├── rename-device.sh          # Rename Pi after venue install
├── deprovision.sh            # Wipe all adspace config (for re-testing bootstrap)
│
├── .github/
│   └── workflows/
│       └── release.yml       # Auto-tags vx.x.x commits; builds API + frontend + prod/dev .img.xz
│
├── wifi-setup/               # React frontend (TV page + phone setup page)
│   ├── src/
│   │   ├── App.tsx           # Router: /tv → TvSetupPage, / → PhoneSetupPage
│   │   ├── pages/
│   │   │   ├── tv-setup-page.tsx      # TV display: QR code + hotspot creds
│   │   │   └── phone-setup-page.tsx   # Phone: network dropdown + manual input
│   │   └── use-setup-config.ts        # Fetches /config.json (written by watchdog)
│   ├── public/
│   │   ├── config.json       # LOCAL DEV ONLY — never deployed (rsync excludes it)
│   │   └── Logo.svg
│   └── Makefile              # pnpm build + rsync to Pi
│
└── wifi-setup-api/           # Go HTTP API (runs on Pi :3000)
    └── main.go               # GET /api/networks, POST /api/wifi
```

> **Note:** `watchdog.sh` and `start-display.sh` are standalone files here for pushing updates to running Pis, but they are also embedded as heredocs inside `bootstrap.sh`. If you edit either, update both places.

---

## Pi file layout

```
/opt/adspace/
├── bootstrap.sh              # Full provisioning script (written by cloud-init via embed.sh)
├── watchdog.sh               # Main control loop (run by systemd)
├── start-display.sh          # Launches Chromium — kiosk or setup mode based on flag
├── kiosk.env                 # ADSPACE_URL env var
├── wifi-setup-api            # Compiled Go binary (serves :3000) — pulled from GitHub Releases
└── wifi-setup/
    └── dist/                 # Built React app (served by Caddy on :80) — pulled from GitHub Releases
        ├── index.html
        ├── assets/
        └── config.json       # Written at runtime by watchdog — NOT in git, NOT deployed

/etc/caddy/Caddyfile          # Serves :80, proxies /api/* to :3000, captive portal
/etc/pam.d/cage               # PAM stack required by cage compositor
/etc/systemd/system/
├── adspace-bootstrap.service # One-shot, Boot 2 only, guarded by /etc/adspace-bootstrap-done
├── adspace-watchdog.service  # Starts on boot, controls everything else
├── adspace-kiosk.service     # cage Wayland session on tty1, boot-disabled
└── adspace-setup-api.service # Go API, started by watchdog only

/etc/adspace-bootstrap-done   # Flag file — exists = bootstrap already ran, skip it
/tmp/adspace-setup-mode       # Flag file — exists = setup mode, absent = kiosk
/tmp/adspace-wifi-scan.json   # WiFi scan cache (written before hotspot starts)
```

---

## Quick start — setting up a new Pi

### Requirements
- Raspberry Pi 5 (4GB or 8GB)
- SD card (16GB+)
- `brew install go pnpm` for frontend/API development
- Ethernet cable (required for first-boot provisioning)

### Step 1 — Get the flash image

**Preferred:** download from the [latest GitHub Release](https://github.com/pachz/adspace-rpi/releases/latest). Raspberry Pi Imager opens `.xz` directly.

- `adspace-tv-vX.Y.Z.img.xz` — **prod**: kiosk `https://screen.adspace.so`
- `adspace-tv-vX.Y.Z-dev.img.xz` — **dev**: kiosk `https://dev.adspace.live`, office apt-cacher

**Or build locally** (macOS or Linux) from a vanilla **Raspberry Pi OS Lite 64-bit (Trixie)** `.img`:
```bash
./embed.sh ~/Downloads/2026-06-18-raspios-trixie-arm64-lite.img images/adspace-tv-v0.1.9.img
```
On Linux, `embed.sh` needs sudo (`losetup` / `mount`). On macOS it uses `hdiutil` (built in).

For a local **dev** image, set these in `.env` then re-run `embed.sh`:
```
APT_PROXY=http://192.168.10.106:3142
ADSPACE_URL=https://dev.adspace.live
```

### Step 2 — Flash the image
Open **Raspberry Pi Imager**:
- OS: **Use Custom** → select the `.img.xz` (or local `.img`)
- Storage: your SD card
- **Do not customise** — no username, no SSH, no WiFi. Everything is baked in.
- Flash

### Step 3 — Boot and wait
Insert SD card, plug in ethernet, power on. Then:

```
Boot 1 (~1 min):  cloud-init runs → creates pi user, enables SSH, starts adspace-bootstrap.service → reboots
Boot 2 (~10 min): bootstrap.sh runs — installs packages, pulls app from GitHub Releases, registers Tailscale → reboots
Boot 3:           Kiosk is live (prod: screen.adspace.so / dev: dev.adspace.live)
```

You can follow Boot 2 progress by SSH-ing in via LAN IP (find it on your router) with password `adspace`:
```bash
ssh pi@<ip>   # password: adspace
sudo journalctl -u adspace-bootstrap -f
```

### Step 4 — Verify
Once bootstrap completes and the Pi reboots:
- Pi appears in [Tailscale dashboard](https://login.tailscale.com/admin/machines) as `adspace-{serial}` with tag `tag:rpi`
- SSH from anywhere: `ssh pi@adspace-{serial}`
- With ethernet: TV shows `screen.adspace.so`
- Without ethernet: setup screen appears, hotspot `Adspace-TV-{serial}` is visible

---

## Day-to-day development

All deploy commands require `PI_SSH`:

### Deploy everything
```bash
make deploy PI_SSH=pi@adspace-{serial}
```

### Deploy frontend only
```bash
make deploy-front PI_SSH=pi@adspace-{serial}
# or: cd wifi-setup && make deploy PI_SSH=pi@adspace-{serial}
```

### Deploy API only
```bash
make deploy-api PI_SSH=pi@adspace-{serial}
```

### Tail live logs
```bash
make logs PI_SSH=pi@adspace-{serial}
```

### Grab a screenshot of what's on the TV
```bash
make screenshot PI_SSH=pi@adspace-{serial}
# Saves to /tmp/adspace-screen.png and opens in Preview on Mac
```

### Open SSH session
```bash
make ssh PI_SSH=pi@adspace-{serial}
```

### Local frontend dev
```bash
cd wifi-setup
pnpm dev
# Opens http://localhost:5173
# / → phone setup page
# /tv → TV display page
# Uses wifi-setup/public/config.json for local config (not deployed to Pi)
```

### Releasing a new version
Commit on `main` with message exactly `v1.2.3` — GitHub Actions creates the tag and builds the API, frontend, and both flash images (prod + dev).

Or tag manually:
```bash
git tag v1.2.3 && git push origin v1.2.3
```
This publishes `wifi-setup-api` (arm64 binary), `wifi-setup-dist.tar.gz`, `adspace-tv-v1.2.3.img.xz` (prod), and `adspace-tv-v1.2.3-dev.img.xz` (dev) to GitHub Releases. Newly provisioned Pis pull the latest release. Existing Pis need `make deploy`.

---

## Connecting to the Pi

### SSH via Tailscale (normal)
```bash
ssh pi@adspace-{serial}           # e.g. ssh pi@adspace-4d919699
ssh pi@adspace-dubai-mall-01      # after venue rename
```

No key file needed — Tailscale handles auth. Just be signed into the AdSpace Tailscale account.

Add to `~/.ssh/config` for convenience:
```
Host adspace-*
    User pi
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
```

### SSH by IP (before Tailscale connects)
```bash
ssh pi@<ip>
```

### Hotspot (setup mode)
When the Pi has no network:
- **SSID**: `Adspace-TV-{cpu_serial}`
- **Password**: same as SSID suffix (the serial)
- **Setup page**: http://192.168.4.1 (opens automatically on most phones as captive portal)
- **TV page**: http://192.168.4.1/tv

---

## Debugging

### Check system state
```bash
# What mode is the Pi in right now?
ssh pi@adspace-{serial} "[ -f /tmp/adspace-setup-mode ] && echo SETUP || echo KIOSK"

# What's connected?
ssh pi@adspace-{serial} "nmcli con show --active"

# Watchdog live log
ssh pi@adspace-{serial} "sudo journalctl -u adspace-watchdog -f"

# Kiosk service log
ssh pi@adspace-{serial} "sudo journalctl -u adspace-kiosk -f"

# API log
ssh pi@adspace-{serial} "sudo journalctl -u adspace-setup-api -f"

# All adspace logs together (including bootstrap)
make logs PI_SSH=pi@adspace-{serial}
```

### Check bootstrap status (new Pi)
```bash
ssh pi@adspace-{serial} "sudo journalctl -u adspace-bootstrap --no-pager"
ssh pi@adspace-{serial} "ls /etc/adspace-bootstrap-done && echo DONE || echo NOT DONE"
```

### Force setup mode (for testing)
```bash
ssh pi@adspace-{serial} "sudo nmcli con delete 'YourNetwork' && sudo systemctl restart adspace-watchdog"
```

### Force kiosk mode
```bash
ssh pi@adspace-{serial} "sudo rm -f /tmp/adspace-setup-mode && sudo systemctl restart adspace-watchdog"
```

### Restart everything cleanly
```bash
ssh pi@adspace-{serial} "sudo systemctl restart adspace-watchdog"
```

### API not responding
```bash
ssh pi@adspace-{serial} "sudo systemctl status adspace-setup-api"
ssh pi@adspace-{serial} "sudo systemctl status caddy"
ssh pi@adspace-{serial} "ss -tlnp | grep 3000"
```

### Chromium won't start / crash loop
```bash
ssh pi@adspace-{serial} "sudo journalctl -u adspace-kiosk --no-pager -n 50"
# Check GPU device exists:
ssh pi@adspace-{serial} "ls /dev/dri/"
# Restart kiosk — ExecStartPre wipes SingletonLock automatically:
ssh pi@adspace-{serial} "sudo systemctl restart adspace-kiosk"
```

### Check what's deployed
```bash
ssh pi@adspace-{serial} "ls -la /opt/adspace/wifi-setup/dist/assets/"
ssh pi@adspace-{serial} "md5sum /opt/adspace/wifi-setup-api"
```

---

## Testing bootstrap (without reflashing)

To test the full bootstrap flow on a Pi that's already running:

```bash
# Step 1 — Wipe all adspace config (simulates a fresh Pi)
ssh pi@adspace-{serial} "sudo bash -s" < deprovision.sh

# Step 2 — Remove the done flag and reboot — bootstrap runs automatically
ssh pi@adspace-{serial} "sudo rm -f /etc/adspace-bootstrap-done && sudo reboot"

# Or run bootstrap directly (skips the reboot guard):
ssh pi@adspace-{serial} "sudo /opt/adspace/bootstrap.sh"
```

**What to verify after bootstrap completes:**
- [ ] With ethernet plugged in: TV shows `screen.adspace.so` within 30s of final reboot
- [ ] Ethernet unplugged + no saved WiFi: setup screen appears, hotspot `Adspace-TV-{serial}` visible
- [ ] Phone connects to hotspot → opens `http://192.168.4.1` → WiFi form with network dropdown
- [ ] Submit valid WiFi creds → TV transitions to kiosk within 15s
- [ ] `make logs` shows clean watchdog transitions

---

## Pi naming

Each Pi gets a hostname based on its CPU serial number during bootstrap:
```
adspace-{8-char cpu serial}    e.g. adspace-4d919699
```

This is **hardware-burned and unique per board** — safe across all Pis (unlike `/etc/machine-id` which can be cloned identically).

Once a Pi is installed at a venue, rename it:
```bash
ssh pi@adspace-4d919699 "sudo bash -s adspace-dubai-mall-01" < rename-device.sh
```

After rename + reboot, SSH via Tailscale from anywhere:
```bash
ssh pi@adspace-dubai-mall-01
```

**Naming convention:**
```
adspace-{city/venue}-{2-digit index}
adspace-dubai-mall-01
adspace-riyadh-airport-01
adspace-cairo-downtown-02
```

---

## Architecture decisions

### Full runtime provisioning
A vanilla RPi OS Lite image has `bootstrap.sh` + `adspace-bootstrap.service` injected via `embed.sh` (locally or in GitHub Actions). On first boot, bootstrap installs all packages, configures all services, and pulls the app binary + frontend from GitHub Releases. No "golden image" to maintain, no `prepare-image.sh` step, no cloning workflow. Any Pi flashed from `adspace-tv.img` self-configures completely on first boot.

### GitHub Releases for app artifacts
`bootstrap.sh` fetches `wifi-setup-api` and `wifi-setup-dist.tar.gz` from the latest GitHub Release. This means:
- No Mac-side deploy step during provisioning
- Every new Pi gets the latest released version automatically
- Version is explicit and auditable in the release history

### Single watchdog, not many services
One `adspace-watchdog.service` (polling loop) controls all transitions. Simpler than a web of oneshot services with `After=`/`Wants=` dependencies that are hard to reason about.

### cage as Wayland compositor
RPi5 uses the Pi GPU driver (vc4/drm). We use **cage** (`libwlroots-0.18`, RPi build `0.18.2-3+rpt4+b1`) as the Wayland compositor — it's purpose-built for single-app kiosks and restarts cleanly on mode switches.

**Why not labwc:** labwc 0.9.7 + wlroots-0.19 (the version in RPi OS) SEGFAULTs on SIGTERM when Chromium holds GPU resources, making mode switching unreliable on Pi 5. cage + wlroots-0.18 is stable.

**Why pin `libwlroots-0.18`:** Must use the RPi build (`0.18.2-3+rpt4+b1`), not the Debian build. The Debian build fails with `EGL_BAD_PARAMETER` / exit-21 on Pi 5 GPU.

### Single `start-display.sh` for both modes
One script checks `/tmp/adspace-setup-mode` and launches Chromium pointing at the correct URL. Replaces the old `start-kiosk.sh` + `start-setup-display.sh` split.

Chromium is called directly as `/usr/lib/chromium/chromium` — bypasses the `/usr/bin/chromium` RPi wrapper which injects `--js-flags=--no-decommit-pooled-pages` (unsupported flag → immediate crash on this version).

### Optimistic WiFi connect response
`POST /api/wifi` returns `{"ok": true}` immediately — before the hotspot is torn down. This is intentional: the phone loses its connection to the Pi when the hotspot drops, so any response sent after that is never received. The actual connect happens in a background goroutine. The screen switching to kiosk = success. Hotspot reappearing = wrong password, try again.

### Separate Chromium profiles
- Kiosk: `adspace-chromium` — persists cache between sessions
- Setup: `adspace-setup-chromium` with `--disk-cache-size=1` — never caches, always shows fresh build

This prevents a stale kiosk JS bundle from bleeding into the setup page (a real bug we hit).

### WiFi scan before hotspot starts
`wlan0` can't be AP and WiFi client simultaneously. The watchdog scans and caches results to `/tmp/adspace-wifi-scan.json` *before* bringing up the hotspot. The API serves from this cache — it never scans live.

### CPU serial for SSID uniqueness
`/etc/machine-id` is identical on all Pi clones. CPU serial (`/proc/cpuinfo`) is hardware-burned and unique per board — safe to use even after SD card cloning.

### config.json never deployed
The Pi writes `/opt/adspace/wifi-setup/dist/config.json` at runtime (hotspot SSID, password, URL). The repo's `public/config.json` is local-dev only. rsync uses `--exclude='config.json'` and `.gitignore` excludes it. `bootstrap.sh` also explicitly deletes it after unpacking the frontend tarball.
