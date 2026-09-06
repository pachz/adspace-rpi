# AGENTS.md — AdSpace RPi Codebase Guide for AI Agents

This file is the authoritative reference for AI coding agents working on this repo.
Read it before making any changes. Follow the constraints — they exist because we hit these bugs.

---

## What this system is

A Raspberry Pi 5 that runs a digital signage kiosk (`https://screen.adspace.so`) when it has network, and displays a setup page + WiFi hotspot when it doesn't. A technician connects their phone to the hotspot, submits WiFi credentials via a web form, and the Pi connects and boots into kiosk mode automatically.

One always-on systemd service (`adspace-watchdog`) drives all state transitions. Everything else is started or stopped by the watchdog.

---

## How a new Pi gets set up

The entire provisioning model is runtime — a vanilla RPi OS Lite image is used, with `bootstrap.sh` injected into it via `embed.sh`. On first boot, `bootstrap.sh` installs everything from scratch and pulls app artifacts from GitHub Releases.

**Boot sequence on a new Pi:**
```
Boot 1: cloud-init runs → creates pi user (password: adspace), enables SSH,
        writes bootstrap.sh + service unit, starts adspace-bootstrap.service → reboots
Boot 2: adspace-bootstrap.service runs → full provisioning (~10 min, needs ethernet) → reboots
Boot 3+: Normal operation — adspace-watchdog controls kiosk/setup transitions
```

**To cut a new base image:** GitHub Actions builds two flash images on every `v*` tag (and via workflow_dispatch):

- `adspace-tv-vX.Y.Z.img.xz` — **prod**: kiosk `https://screen.adspace.so`, no apt proxy
- `adspace-tv-vX.Y.Z-dev.img.xz` — **dev**: kiosk `https://dev.adspace.live`, apt-cacher `http://192.168.10.106:3142`

Download from the GitHub Release and flash with Raspberry Pi Imager — no customisation.

Locally (macOS or Linux):
```bash
./embed.sh ~/Downloads/2026-06-18-raspios-trixie-arm64-lite.img images/adspace-tv-v0.1.9.img
```
The official Lite image URL + SHA-256 are pinned in `.github/workflows/release.yml`. Bump both when Raspberry Pi publishes a new Lite image. CI sources `.env.example` during embed, so flash images join Headscale (`HEADSCALE_LOGIN_SERVER` / `HEADSCALE_AUTH_KEY`) instead of Tailscale.com.

Optional: set `APT_PROXY=http://host:3142` and/or `ADSPACE_URL=https://dev.adspace.live` in `.env` so local `embed.sh` / `qemu-run.sh` images pick them up. Bootstrap writes `/etc/apt/apt.conf.d/01adspace-proxy` if the proxy is reachable; otherwise apt goes direct. The CI **dev** image bakes both in; the prod image does not.

**There is no `provision.sh`, `flash.sh`, or `prepare-image.sh`.** Those are gone. `bootstrap.sh` is the single source of truth for what's on a Pi.

---

## SSH access

### Pi naming
Each Pi's hostname follows the pattern `adspace-{cpu_serial}` — set by `bootstrap.sh` on first boot from the hardware CPU serial. After a device is installed at a venue it can be renamed with `rename-device.sh`:

```
adspace-{cpu_serial}          default, e.g. adspace-4d919699
adspace-dubai-mall-01         after venue rename
adspace-riyadh-airport-02
```

Tailscale is enrolled on every Pi, so once renamed you can SSH from anywhere without knowing the IP:
```bash
ssh pi@adspace-dubai-mall-01
```

### Setting up SSH access

SSH to Pis goes through **Tailscale** — no keys to manage. See the README onboarding section for full setup, but the short version:

1. Sign into Tailscale at [tailscale.com](https://tailscale.com) using **dev@adspace.so** (Continue with Google)
2. Install the Tailscale Mac app
3. SSH directly by device name: `ssh pi@adspace-{serial}`

**Tailscale handles auth** — if you're logged into the AdSpace Tailscale account you can SSH any Pi, no key file needed.

**SSH config** (add to `~/.ssh/config` for convenience):
```
# AdSpace Pis via Tailscale — no key needed, Tailscale handles auth
Host adspace-*
    User pi
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
```

**Two users, two purposes:**
- `pi` — humans, full sudo, used for deploys and manual work
- `aiagent` — AI agent only, full passwordless sudo, SSH key auth

**AI agent SSHes as `aiagent`:**
```bash
ssh -i ~/.ssh/ai-agent aiagent@adspace-{serial}
```

**Humans SSH as `pi`:**
```bash
ssh pi@adspace-{serial}      # any Pi by Tailscale name
```

### What `aiagent` can sudo
`aiagent` has `NOPASSWD: ALL` — full passwordless sudo. This is intentional for unattended remote dev and diagnostics over SSH. The user is locked to key-only SSH auth (no password login).

---

## Deploying changes

### Frontend (React)
```bash
cd wifi-setup && make deploy PI_SSH=pi@adspace-{serial}
# Runs: pnpm build → rsync dist/ to Pi:/opt/adspace/wifi-setup/dist
# IMPORTANT: rsync uses --delete (removes old bundles) and --exclude='config.json'
```

### Go API binary
```bash
# From repo root:
make deploy-api PI_SSH=pi@adspace-{serial}

# Or manually:
cd wifi-setup-api
GOOS=linux GOARCH=arm64 go build -o wifi-setup-api .
scp wifi-setup-api pi@adspace-{serial}:/tmp/wifi-setup-api-new
ssh pi@adspace-{serial} "sudo mv /tmp/wifi-setup-api-new /opt/adspace/wifi-setup-api \
         && sudo chown adspace:adspace /opt/adspace/wifi-setup-api \
         && sudo chmod +x /opt/adspace/wifi-setup-api \
         && sudo systemctl start adspace-setup-api.service || true"
```

### Watchdog / shell scripts
`watchdog.sh`, `start-display.sh`, `indicate.sh`, and `device-info.py` exist both as standalone files in the repo root AND as heredocs embedded inside `bootstrap.sh`. **If you edit any of them, you must update both the standalone file and the embedded copy inside `bootstrap.sh`.** Freshly provisioned Pis get the embedded version.

Push the updated file to a running Pi:
```bash
ssh pi@adspace-{serial} "sudo tee /opt/adspace/watchdog.sh" < watchdog.sh
ssh pi@adspace-{serial} "sudo chmod +x /opt/adspace/watchdog.sh && sudo systemctl restart adspace-watchdog"

ssh pi@adspace-{serial} "sudo tee /opt/adspace/indicate.sh" < indicate.sh
ssh pi@adspace-{serial} "sudo chmod +x /opt/adspace/indicate.sh"

make deploy-info PI_SSH=pi@adspace-{serial}
```

### Releasing a new version (frontend + API + flash image)
Commit on `main` with first line exactly `v1.2.3`. Anything after that becomes the GitHub Release changelog (GitHub also appends auto-generated notes):

```
v1.2.3

- Identify a Pi from the TV: ACT LED + hostname flash
- CI images join Headscale instead of Tailscale.com
```

GitHub Actions creates the git tag and builds the Go API, frontend tarball, and both flashable `.img.xz` files (prod + dev).

Manual tag still works (no commit body — release notes are auto-generated only):
```bash
git tag v1.2.3 && git push origin v1.2.3
```
Newly provisioned Pis pull `wifi-setup-api` + `wifi-setup-dist.tar.gz` from the latest release. Existing Pis need `make deploy`. Flash new SD cards from `adspace-tv-v1.2.3.img.xz` (prod) or `adspace-tv-v1.2.3-dev.img.xz` (dev) on the same release.

To rebuild only the image (e.g. after a `bootstrap.sh` fix) without a new tag: Actions → Release → Run workflow → optionally set `attach_to_release` to an existing tag.

---

## Critical constraints — read before changing anything

### 1. `config.json` is NEVER deployed
`/opt/adspace/wifi-setup/dist/config.json` is written at runtime by `watchdog.sh`.
- `wifi-setup/public/config.json` is local dev only (fallback values)
- `rsync` in `wifi-setup/Makefile` uses `--exclude='config.json'`
- `bootstrap.sh` deletes `config.json` after unpacking the frontend tarball
- `.gitignore` excludes both paths
- **Do not add config.json to deploys, commits, rsync commands, or bootstrap**

### 2. wlan0 cannot AP and client simultaneously
When the hotspot is up, `wlan0` is in AP mode. You cannot:
- Run `nmcli dev wifi rescan` (hangs)
- Run `nmcli dev wifi list` (returns empty)
- Auto-connect to saved WiFi

The watchdog scans *before* starting the hotspot and saves to `/tmp/adspace-wifi-scan.json`.
The API reads from that file — it never scans live.

To attempt reconnection: bring hotspot down, wait 20s, check `nmcli con show --active`.

### 3. Always delete the SSID profile before re-connecting
`nmcli dev wifi connect` fails with `key-mgmt: property is missing` if a stale profile for that SSID exists. The API does:
```go
exec.Command("sudo", "nmcli", "con", "delete", body.SSID).Run()
```
before connecting. Do not remove this.

### 4. Hotspot must come down before WiFi connect
The API brings the hotspot down in a background goroutine after immediately returning `{"ok": true}` to the phone. wlan0 cannot be AP and client at the same time. The hotspot is restored if connect fails.

### 5. POST /api/wifi is optimistic
The API returns `{"ok": true}` immediately — before the connect attempt completes. This is required because the phone loses its network connection when the hotspot drops. The actual connect runs in a background goroutine with a 30s timeout. If it fails, the hotspot is restored. The screen switching to kiosk mode is the real success confirmation.

### 6. Use CPU serial, not machine-id, for SSID
`/etc/machine-id` is cloned identically when SD cards are copied for new Pis.
CPU serial is hardware-burned and unique per board:
```bash
grep Serial /proc/cpuinfo | awk '{print $3}' | tail -c 9
```
The watchdog uses this for `Adspace-TV-{cpu_serial}`.

### 7. Separate Chromium profiles
- Kiosk: `--user-data-dir=/home/adspace/.config/adspace-chromium`
- Setup: `--user-data-dir=/home/adspace/.config/adspace-setup-chromium --disk-cache-size=1`

Never merge these. Stale kiosk bundles bled into setup mode — this was a real bug.

### 8. Old JS bundles accumulate and break things
`rsync --delete` in `wifi-setup/Makefile` ensures stale bundles are removed on every deploy.
`bootstrap.sh` unpacks the frontend tarball fresh each time.
Do not remove the `--delete` flag from rsync.

### 9. adspace-kiosk.service has Restart=always but is boot-disabled
The watchdog calls `systemctl restart adspace-kiosk` explicitly.
If `adspace-kiosk` is enabled at boot AND `Restart=always`, it starts itself before watchdog is ready, causing race conditions. It is boot-disabled intentionally — watchdog controls it.

### 10. Wipe SingletonLock before each cage start
`ExecStartPre` in `adspace-kiosk.service` removes the chromium SingletonLock files before cage starts. `KillMode=control-group` already kills all processes in the cgroup (including chromium) when the service stops, so explicit `pkill` is not needed — and is dangerous: `pkill -f <path>` matches the `sh -c '...'` ExecStartPre process itself (the path string appears in its own argv), killing it with SIGHUP and causing a crash loop.

### 11. adspace-kiosk conflicts with getty@tty1
`Conflicts=getty@tty1.service` in `adspace-kiosk.service` ensures systemd stops the getty autologin session before cage starts. Without it, when cage exits, `TTYVHangup=yes` hangs up tty1, getty respawns and autologins `adspace` with a bash shell on tty1, and the next cage start gets HUP'd from tty1 being held.

### 12. Call chromium binary directly, not the wrapper
Use `/usr/lib/chromium/chromium`, not `/usr/bin/chromium`. The RPi wrapper (`rpi-chromium-mods`) injects `--js-flags=--no-decommit-pooled-pages` which is unsupported on this Chromium version and causes an immediate crash. Pass `--user-agent` from `/opt/adspace/chromium-ua` (written at bootstrap after chromium install). Do not invent a UA — dump Chromium's real one and append ` AdspaceTV/rpi-<tag>`.

### 13. cage requires libwlroots-0.18 (RPi build)
Must use `libwlroots-0.18=0.18.2-3+rpt4+b1` (RPi build). The Debian build of wlroots-0.18 fails with `EGL_BAD_PARAMETER` on Pi 5 GPU. libwlroots-0.19 (used by labwc) causes SEGV on mode switch. Both can coexist but cage must link against 0.18.

### 14. cage requires /etc/pam.d/cage
cage needs its own PAM stack. `PAMName=cage` in the service unit points to `/etc/pam.d/cage`. Without it, cage exits with code 21 (ENODEV).

### 15. HDMI force on Pi 5 uses dtparam, not legacy settings
Pi 5 uses KMS/DRM — the old `hdmi_force_hotplug=1`, `hdmi_group`, `hdmi_mode` settings are silently ignored. The correct setting for Pi 5 is:
```
[all]
dtparam=hdmi_force_hotplug=1
```
`bootstrap.sh` removes legacy settings and writes the correct one. Do not reintroduce the legacy settings.

### 16. bootstrap.sh and standalone scripts must stay in sync
`watchdog.sh`, `start-display.sh`, `indicate.sh`, and `device-info.py` are embedded as heredocs inside `bootstrap.sh` (steps 7). The standalone files in the repo root are used for pushing updates to running Pis. **Both must be updated together.** Freshly provisioned Pis get the bootstrap-embedded version.

---

## Bootstrap service

`adspace-bootstrap.service` runs **once per device** on Boot 2 (after cloud-init triggers a reboot). It does full provisioning from scratch:

1. Waits for internet (retry loop, no timeout)
2. Installs all packages: chromium, cage, libwlroots-0.18, caddy, NetworkManager, grim, jq, etc. Dumps Chromium's real UA and writes `/opt/adspace/chromium-ua` as `<ua> AdspaceTV/rpi-<tag>`
3. Configures NetworkManager, disables conflicting network services
4. Fixes boot config (HDMI for Pi 5)
5. Creates users: `adspace`, `pi` (sudoers), `aiagent` (sudoers + SSH key)
6. Configures tty1 autologin
7. Writes all scripts to `/opt/adspace/`: `watchdog.sh`, `start-display.sh`, `indicate.sh`, `device-info.py`, `kiosk.env`
8. Writes `/etc/pam.d/cage`
9. Writes `/etc/caddy/Caddyfile`
10. Installs all systemd units: `adspace-kiosk`, `adspace-watchdog`, `adspace-setup-api`, `adspace-info` (enabled at boot)
11. Disables cloud-init
12. Sets hostname from CPU serial
13. Sets WiFi country (AE), unblocks rfkill
14. Creates hotspot nmcli profile
15. Installs Tailscale via the bundled `/opt/adspace/tailscale-install.sh` (vendored official installer; falls back to curl if missing) and registers the device
16. Pulls `wifi-setup-api` binary + `wifi-setup-dist.tar.gz` from latest GitHub Release
17. Touches `/etc/adspace-bootstrap-done`, reboots

Guarded by `ConditionPathExists=!/etc/adspace-bootstrap-done` — never runs twice.

**Re-running bootstrap** (on an existing Pi, for testing):
```bash
ssh pi@adspace-{serial} "sudo rm /etc/adspace-bootstrap-done && sudo reboot"
# Or run directly:
ssh pi@adspace-{serial} "sudo /opt/adspace/bootstrap.sh"
```

---

## File locations on Pi

| Path | Purpose |
|------|---------|
| `/opt/adspace/bootstrap.sh` | Full provisioning script — written by cloud-init via embed.sh |
| `/opt/adspace/tailscale-install.sh` | Official Tailscale installer — vendored in the repo, baked into the image by `embed.sh` |
| `/opt/adspace/watchdog.sh` | Main control loop — do not edit in place, push from repo |
| `/opt/adspace/start-display.sh` | Single display launcher — checks setup flag, starts correct Chromium |
| `/opt/adspace/indicate.sh` | Identify this Pi — blink ACT LED + flash hostname on the HDMI display |
| `/opt/adspace/device-info.py` | Always-on localhost:7224 API — version, CPU serial, hostname |
| `/opt/adspace/kiosk.env` | `ADSPACE_URL` env var — written by bootstrap (prod default `https://screen.adspace.so`) |
| `/opt/adspace/chromium-ua` | Full Chromium `--user-agent` string — written by bootstrap after chromium install |
| `/opt/adspace/version` | Release token used in the UA (`1.2.3` from tag `v1.2.3`) |
| `/opt/adspace/wifi-setup-api` | Compiled Go binary, served on :3000 |
| `/opt/adspace/wifi-setup/dist/` | Built React app, served by Caddy on :80 |
| `/opt/adspace/wifi-setup/dist/config.json` | Runtime-written by watchdog — never deploy |
| `/etc/caddy/Caddyfile` | Serves :80, proxies /api/*, captive portal redirects |
| `/etc/pam.d/cage` | Required PAM stack for cage compositor |
| `/etc/systemd/system/adspace-bootstrap.service` | One-shot, Boot 2 only, guarded by done flag |
| `/etc/systemd/system/adspace-watchdog.service` | Starts on boot (every boot after bootstrap) |
| `/etc/systemd/system/adspace-kiosk.service` | cage Wayland session on tty1, boot-disabled |
| `/etc/systemd/system/adspace-setup-api.service` | Go API, started by watchdog only |
| `/etc/systemd/system/adspace-info.service` | Device info API on 127.0.0.1:7224, enabled at boot |
| `/etc/adspace-bootstrap-done` | Flag: exists = bootstrap already ran, skip it |
| `/tmp/adspace-setup-mode` | Flag: exists = setup mode, absent = kiosk mode |
| `/tmp/adspace-wifi-scan.json` | WiFi scan cache from before hotspot started |
| `/boot/firmware/adspace-apt.env` | Optional `APT_PROXY=` — baked into the CI **dev** image, not prod |
| `/boot/firmware/adspace-kiosk.env` | Optional `ADSPACE_URL=` — baked into the CI **dev** image (`https://dev.adspace.live`) |
| `/boot/firmware/adspace-version.env` | `ADSPACE_VERSION=` from the git tag — baked by `embed.sh` / CI; bootstrap restamps the UA with the GitHub release tag when it pulls artifacts |

---

## State machine

```
          ┌──────────────┐
          │   WATCHDOG   │  polls every 15s
          └──────┬───────┘
                 │
    ┌────────────▼────────────┐
    │     is_connected()?     │
    └────┬──────────────┬─────┘
         │ YES          │ NO
         ▼              ▼
   enter_kiosk()   enter_setup()
   ─────────────   ─────────────
   stop caddy      scan_networks()
   stop api        update hotspot SSID
   down hotspot    write config.json
   restart kiosk   touch setup flag
                   up hotspot
                   start api + caddy
                   restart kiosk

   In setup mode, every ~60s:
   try_reconnect() → down hotspot → wait 20s → check connection
                  → if connected: enter_kiosk()
                  → if not: restore hotspot
```

---

## Service dependency map

```
systemd boot
    ├── adspace-bootstrap.service  (Boot 2 only — full provisioning, then reboots)
    ├── adspace-info.service       (every boot — device info on 127.0.0.1:7224)
    └── adspace-watchdog.service   (every boot after bootstrap, controls everything)
            ├── adspace-kiosk.service     (watchdog: systemctl restart)
            ├── adspace-setup-api.service (watchdog: systemctl start/stop)
            └── caddy.service             (watchdog: systemctl start/stop)

adspace-kiosk.service
    └── cage (Wayland compositor, PAMName=cage)
            └── /opt/adspace/start-display.sh
                    ├── [setup mode]  → chromium → http://localhost/tv
                    └── [kiosk mode]  → chromium → https://screen.adspace.so
```

---

## API reference

### Device info (`adspace-info`, always on)

Bound to `127.0.0.1:7224` only. Not proxied through Caddy.

```bash
curl -s http://127.0.0.1:7224/
```

```json
{
  "version": "1.2.3",
  "serial": "4d919699",
  "hostname": "adspace-4d919699",
  "model": "Raspberry Pi 5 Model B Rev 1.0",
  "mode": "kiosk"
}
```

`serial` is the last 8 chars of the Pi CPU serial (same token used for hostname / hotspot SSID). QEMU/virt falls back to machine-id. `GET /api/info` is the same payload; `GET /health` returns `{"ok":true}`.

### WiFi setup (Go binary on `:3000`, proxied through Caddy on `:80`)

### Connectivity check
The watchdog uses `nmcli networking connectivity` (not connection profile state) to determine if the Pi has internet. NM keeps ethernet profiles `activated` even when the cable is unplugged — profile state is useless. `nmcli networking connectivity` returns `full` only when NM's internet probe succeeds. Two consecutive failures are required before entering setup mode, to avoid false triggers from momentary NM probe blips.

### `GET /api/networks`
Returns cached WiFi scan from before hotspot started.
```json
{ "networks": [{ "ssid": "Office WiFi", "signal": 85 }, ...] }
```
Returns `{ "networks": [] }` if no cache exists.

### `POST /api/wifi`
Initiates WiFi connection. Returns immediately — connect happens in background.
```json
// Request
{ "ssid": "Office WiFi", "password": "hunter2" }

// Always returns 200 immediately
{ "ok": true }
```
The API returns before the connection attempt completes. Success = screen switches to kiosk within ~15s. Failure = hotspot reappears within ~35s so the technician can retry.

The hotspot restore on failure uses `nohup` so it survives if systemd kills the API process before the goroutine finishes (e.g. watchdog detects ethernet reconnect and stops the API mid-goroutine).

---

## Debugging workflows

### Check current mode
```bash
ssh pi@adspace-{serial} "[ -f /tmp/adspace-setup-mode ] && echo SETUP || echo KIOSK"
```

### Device info API (localhost:7224)
```bash
ssh pi@adspace-{serial} "curl -s http://127.0.0.1:7224/"
```

### Watch everything live
```bash
make logs PI_SSH=pi@adspace-{serial}
# or:
ssh pi@adspace-{serial} "sudo journalctl -u adspace-watchdog -u adspace-kiosk -u adspace-setup-api -u adspace-info -u adspace-bootstrap -f"
```

### Check bootstrap status (new Pi)
```bash
ssh pi@adspace-{serial} "sudo journalctl -u adspace-bootstrap --no-pager"
ssh pi@adspace-{serial} "ls /etc/adspace-bootstrap-done && echo DONE || echo NOT DONE"
```

### Force into setup mode (for testing)
```bash
ssh pi@adspace-{serial} "sudo nmcli con delete 'NetworkName' && sudo systemctl restart adspace-watchdog"
```

### Force into kiosk mode
```bash
ssh pi@adspace-{serial} "sudo rm -f /tmp/adspace-setup-mode && sudo systemctl restart adspace-watchdog"
```

### Grab a screenshot of the current display
```bash
make screenshot PI_SSH=pi@adspace-{serial}
# Saves to /tmp/adspace-screen.png and opens in Preview on Mac
```

### Identify which TV this Pi is
```bash
make indicate PI_SSH=pi@adspace-{serial}
# ACT LED pulses and the HDMI screen flashes the hostname for ~4s
```

### Check WiFi scan cache
```bash
ssh pi@adspace-{serial} "cat /tmp/adspace-wifi-scan.json"
```

### Check what nmcli knows
```bash
ssh pi@adspace-{serial} "sudo nmcli con show"
ssh pi@adspace-{serial} "sudo nmcli con show --active"
```

### Check Caddy is serving correctly
```bash
# From a device on the hotspot (192.168.4.x):
curl http://192.168.4.1/config.json
curl http://192.168.4.1/api/networks
```

### Chromium crash loop
```bash
ssh pi@adspace-{serial} "sudo journalctl -u adspace-kiosk --no-pager -n 50"
# Check for "Opening in existing browser session" → stale singleton, restart will fix it
# The ExecStartPre kills lingering chromium + wipes SingletonLock automatically on each restart
ssh pi@adspace-{serial} "sudo systemctl restart adspace-kiosk"
```

### API not running
```bash
ssh pi@adspace-{serial} "sudo systemctl status adspace-setup-api"
ssh pi@adspace-{serial} "ss -tlnp | grep 3000"
```

---

## Common mistakes to avoid

| Mistake | Why it breaks |
|---------|--------------|
| Deploying `config.json` | Pi's runtime SSID gets overwritten with dev defaults |
| Removing `--delete` from rsync | Old JS bundles accumulate, Chromium loads wrong one |
| Scanning WiFi while hotspot is up | `nmcli rescan` hangs indefinitely |
| Not deleting SSID profile before connect | `key-mgmt: property is missing` error |
| Using `/etc/machine-id` for SSID | All cloned Pis get identical SSIDs |
| Merging Chromium profiles | Stale kiosk cache appears in setup page |
| Enabling adspace-kiosk at boot | Starts before watchdog, race condition, wrong mode |
| Calling `/usr/bin/chromium` wrapper | Injects unsupported `--js-flags`, crashes immediately |
| Using labwc instead of cage | labwc 0.9.7 + wlroots-0.19 SEGFAULTs on mode switch on Pi 5 |
| Using Debian libwlroots-0.18 build | `EGL_BAD_PARAMETER` / exit-21 on Pi 5 GPU; must use RPi build |
| Skipping `/etc/pam.d/cage` | cage exits with code 21 (ENODEV) |
| Using `pkill -f <path>` in ExecStartPre | Matches the sh process running ExecStartPre itself → SIGHUP crash loop |
| Missing `Conflicts=getty@tty1.service` | getty respawns bash on tty1 after cage exits → HUP kills next cage start |
| Checking NM connection profile state for connectivity | Profiles stay `activated` even with cable unplugged — use `nmcli networking connectivity` |
| Using legacy `hdmi_force_hotplug=1` in config.txt | Silently ignored on Pi 5 — use `dtparam=hdmi_force_hotplug=1` under `[all]` |
| Editing watchdog.sh / start-display.sh / indicate.sh / device-info.py without updating bootstrap.sh | Newly provisioned Pis get the old embedded version from bootstrap.sh |
| Uploading an uncompressed `.img` to GitHub Releases | File limit is 2 GB; Lite is ~2.8 GB — always publish `.img.xz` |
| Using unquoted heredoc in embed.sh | Bash expands `$VAR`/`$()` inside bootstrap.sh content → file written as 0 bytes; use Python or quoted `<< 'DELIM'` with no expansions needed |
| Inline Caddyfile handle blocks | `handle /path { ... }` on one line is rejected by Caddy 2.6.2 — always use multiline blocks |
| Customising the image in Raspberry Pi Imager | User-data already creates the pi user with password `adspace` and enables SSH — Imager customisation conflicts with cloud-init and is not needed |
