# Boxarr on CasaOS / ZimaOS

Only your **TorBox API key** is required (torbox.app → Settings → API).

## Install (easiest)

SSH into your NAS and run:

```bash
curl -fsSL https://raw.githubusercontent.com/killamfkr/Boxarr2/main/deploy/zimaos-casaos/install.sh -o /tmp/boxarr-install.sh
chmod +x /tmp/boxarr-install.sh
sudo /tmp/boxarr-install.sh
```

It will **prompt for your API key** — paste it and press Enter.

## Install (one command, pass API key)

```bash
sudo /tmp/boxarr-install.sh --api-key 'paste-your-api-key-here' -y
```

(Download the script first with the `curl` command above.)

## One-liner

The API key must come **before** `curl`, and you need `sudo -E`:

```bash
TORBOX_API_KEY='paste-your-api-key-here' \
  curl -fsSL https://raw.githubusercontent.com/killamfkr/Boxarr2/main/deploy/zimaos-casaos/install.sh \
  | sudo -E bash -s -- -y
```

Note: `TORBOX_API_KEY` uses **underscores**, not spaces.

## Verify you have the right script

The first lines should say:

```
[install] Boxarr installer v1.1.3 — API key mount is the default
```

If you see **WebDAV** or **v1.0.0**, delete `/tmp/boxarr-install.sh` and re-download.

## After install

```bash
cd /DATA/AppData/boxarr-stack
./manage.sh urls
```

Open Boxarr at `http://<nas-ip>:8181` and finish Settings (Prowlarr, TMDB, Plex).
