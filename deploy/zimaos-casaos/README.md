# Boxarr on CasaOS / ZimaOS

Failsafe install for Boxarr + TorBox WebDAV (rclone) + optional Seerr.

**Use SSH + `docker compose`, not the CasaOS/ZimaOS app GUI.** The GUI strips mount-propagation flags that Plex needs to resolve Boxarr symlinks after an rclone restart.

## Quick install

SSH into your NAS. **Do not use `curl | bash` without credentials** — the installer cannot prompt when piped.

### Recommended (interactive)

```bash
curl -fsSL https://cdn.jsdelivr.net/gh/killamfkr/Boxarr2@main/deploy/zimaos-casaos/install.sh -o /tmp/boxarr-install.sh
chmod +x /tmp/boxarr-install.sh
sudo /tmp/boxarr-install.sh
```

You will be prompted for your **TorBox WebDAV** login (torbox.app email + password — **not** the API key).

### One-liner (non-interactive)

Pass credentials on the same line. Use `sudo -E` so environment variables survive sudo:

```bash
TORBOX_WEBDAV_USER='you@example.com' \
TORBOX_WEBDAV_PASS='your-torbox-password' \
  curl -fsSL https://cdn.jsdelivr.net/gh/killamfkr/Boxarr2@main/deploy/zimaos-casaos/install.sh \
  | sudo -E bash -s -- -y
```

### Secrets file

```bash
printf 'TORBOX_WEBDAV_USER=you@example.com\nTORBOX_WEBDAV_PASS=your-password\n' > /tmp/boxarr.env
chmod 600 /tmp/boxarr.env
curl -fsSL https://cdn.jsdelivr.net/gh/killamfkr/Boxarr2@main/deploy/zimaos-casaos/install.sh -o /tmp/boxarr-install.sh
chmod +x /tmp/boxarr-install.sh
sudo /tmp/boxarr-install.sh --env-file /tmp/boxarr.env -y
```

## What it does

1. Creates `/DATA/AppData/boxarr-stack`, `/DATA/torbox`, `/DATA/library/{movies,tv,anime}`
2. Enables FUSE (`user_allow_other`)
3. Writes `rclone.conf` for TorBox WebDAV (`https://webdav.torbox.app`)
4. Installs **`boxarr-rclone.service`** (host rclone mount — recommended)
5. Starts **Boxarr** (+ optional **Seerr**) via Docker Compose
6. Installs **`manage.sh`** for day-to-day operations

## Options

| Flag / env | Default | Description |
|------------|---------|-------------|
| `-y` | off | Non-interactive (requires WebDAV creds or existing `rclone.conf`) |
| `--env-file PATH` | — | Load `TORBOX_WEBDAV_USER` / `PASS` from a file |
| `--docker-rclone` | off | Run rclone in Docker instead of host systemd |
| `--no-seerr` | off | Skip Seerr container |
| `BOXARR_INSTALL_DIR` | `/DATA/AppData/boxarr-stack` | Config + compose location |
| `BOXARR_TORBOX_MOUNT` | `/DATA/torbox` | TorBox WebDAV mount path |
| `BOXARR_LIBRARY_ROOT` | `/DATA/library` | Symlink library roots |
| `PUID` / `PGID` | current user | Container user |
| `TORBOX_WEBDAV_USER` / `PASS` | prompted | Torbox.app **login** (not API key) |
| `TORBOX_API_KEY` etc. | empty | Optional Boxarr pre-seed (UI works too) |

## After install

```bash
cd /DATA/AppData/boxarr-stack
./manage.sh urls
./manage.sh health
./manage.sh logs boxarr
```

**Plex** (if installed from the app store): add custom bind mounts so paths match Boxarr exactly:

- `/DATA/library` → `/DATA/library`
- `/DATA/torbox` → `/DATA/torbox`

Then map libraries to `/DATA/library/movies`, `/DATA/library/tv`, `/DATA/library/anime`.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `TorBox WebDAV credentials are required` | Use interactive install (download script first) or pass `TORBOX_WEBDAV_USER` + `PASS` with `sudo -E` |
| `Docker Compose is required` | `sudo apt-get install -y docker-compose-plugin` then `docker compose version`, or re-run with `sudo bash install.sh` |
| Empty TorBox mount | `sudo systemctl status boxarr-rclone` / `journalctl -u boxarr-rclone -n 50` |
| Plex shows no files | Ensure both library + torbox paths are mounted in Plex; run **Scan Library Files** |

## Uninstall

```bash
cd /DATA/AppData/boxarr-stack
./manage.sh stop
sudo systemctl disable --now boxarr-rclone
sudo rm -f /etc/systemd/system/boxarr-rclone.service
sudo systemctl daemon-reload
# Remove data if desired:
# sudo rm -rf /DATA/AppData/boxarr-stack /DATA/torbox /DATA/library
```
