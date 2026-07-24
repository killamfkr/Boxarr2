# Boxarr on CasaOS / ZimaOS

Failsafe install for Boxarr + TorBox mount + optional Seerr.

**Use SSH + `docker compose`, not the CasaOS/ZimaOS app GUI.**

## Quick install

Only your **TorBox API key** is required (torbox.app → Settings → API). No WebDAV email/password needed.

### One-liner

```bash
TORBOX_API_KEY='your-api-key' \
  curl -fsSL https://raw.githubusercontent.com/killamfkr/Boxarr2/main/deploy/zimaos-casaos/install.sh \
  | sudo -E bash -s -- -y
```

Use `sudo -E` so the API key survives sudo.

### Interactive (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/killamfkr/Boxarr2/main/deploy/zimaos-casaos/install.sh -o /tmp/boxarr-install.sh
chmod +x /tmp/boxarr-install.sh
sudo /tmp/boxarr-install.sh
```

You will be prompted for your TorBox API key only.

### Secrets file

```bash
printf 'TORBOX_API_KEY=your-api-key\n' > /tmp/boxarr.env
chmod 600 /tmp/boxarr.env
curl -fsSL https://raw.githubusercontent.com/killamfkr/Boxarr2/main/deploy/zimaos-casaos/install.sh -o /tmp/boxarr-install.sh
chmod +x /tmp/boxarr-install.sh
sudo /tmp/boxarr-install.sh --env-file /tmp/boxarr.env -y
```

## How the mount works

| Method | What you provide | How it mounts |
|--------|------------------|---------------|
| **API (default)** | `TORBOX_API_KEY` | `torbox-media-center` container (FUSE) |
| **rclone** | Email + password (`--rclone-mount`) | Host systemd or Docker rclone WebDAV |

The API-key path is simpler and matches what you already have from torbox.app.

## After install

```bash
cd /DATA/AppData/boxarr-stack
./manage.sh urls
./manage.sh health
```

Open Boxarr at `http://<nas-ip>:8181` and finish **Settings** (Prowlarr, TMDB, Plex).

**Plex** must bind-mount both paths at the same absolute paths:

- `/DATA/library` → `/DATA/library`
- `/DATA/torbox` → `/DATA/torbox`

## Options

| Flag / env | Description |
|------------|-------------|
| `TORBOX_API_KEY` | **Required** — torbox.app → Settings → API |
| `--rclone-mount` | Use WebDAV+rclone instead (needs email + password) |
| `MOUNT_PROVIDER` | `auto` (default), `api`, or `rclone` |
| `--env-file` | Load secrets from a file |
| `--no-seerr` | Skip Seerr |

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `TorBox API key is required` | Pass `TORBOX_API_KEY=...` with `sudo -E`, or run interactively |
| Empty TorBox mount | `./manage.sh mount` or `./manage.sh logs torbox-mount` |
| Want rclone instead | Re-run with `--rclone-mount` and WebDAV email/password |
