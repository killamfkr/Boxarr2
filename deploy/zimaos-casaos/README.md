# Boxarr on CasaOS / ZimaOS

Failsafe install for Boxarr + TorBox WebDAV (rclone) + optional Seerr.

**Use SSH + `docker compose`, not the CasaOS/ZimaOS app GUI.** The GUI strips mount-propagation flags that Plex needs to resolve Boxarr symlinks after an rclone restart.

## Quick install

SSH into your NAS, then either clone the repo or use the one-liner:

```bash
# One-liner (jsDelivr CDN — raw.githubusercontent.com/.../main/... may 404 on some repos)
curl -fsSL https://cdn.jsdelivr.net/gh/killamfkr/Boxarr2@main/deploy/zimaos-casaos/install.sh | bash
```

If the one-liner fails, clone the repo and run `sudo bash deploy/zimaos-casaos/install.sh` instead.

```bash
# From a git clone
sudo bash deploy/zimaos-casaos/install.sh
```

Non-interactive (set TorBox WebDAV credentials first):

```bash
TORBOX_WEBDAV_USER='you@example.com' \
TORBOX_WEBDAV_PASS='your-torbox-password' \
  bash deploy/zimaos-casaos/install.sh -y
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
| `-y` | off | Non-interactive |
| `--docker-rclone` | off | Run rclone in Docker instead of host systemd |
| `--no-seerr` | off | Skip Seerr container |
| `BOXARR_INSTALL_DIR` | `/DATA/AppData/boxarr-stack` | Config + compose location |
| `BOXARR_TORBOX_MOUNT` | `/DATA/torbox` | TorBox WebDAV mount path |
| `BOXARR_LIBRARY_ROOT` | `/DATA/library` | Symlink library roots |
| `PUID` / `PGID` | current user | Container user |
| `TORBOX_WEBDAV_USER` / `PASS` | prompted | TorBox account credentials |
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
| Empty TorBox mount | `sudo systemctl status boxarr-rclone` / `journalctl -u boxarr-rclone -n 50` |
| Plex shows no files | Ensure both library + torbox paths are mounted in Plex; run **Scan Library Files** |
| FUSE permission denied | Check `/etc/fuse.conf` contains `user_allow_other` |
| Prowlarr unreachable | Set URL in Boxarr Settings — use `http://host.docker.internal:9696` if Prowlarr is on the host |

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
