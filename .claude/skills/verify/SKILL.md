---
name: verify
description: Run the real boxarr binary against stub TorBox/Plex servers to observe worker behaviour end-to-end. Use when verifying changes to the submitter, pollers, importer, or Plex scan paths.
---

# Verifying Boxarr at runtime

Boxarr's interesting logic lives in background worker loops that talk to TorBox
and Plex. You can drive all of it without real credentials: both clients are
redirectable, so point them at local stubs and read the requests they make.

## Why stubs work

- `torbox.base_url` is a **settings row** (`internal/settings/getters.go`,
  `KeyTorBoxBaseURL`). No env var — write it into the `settings` table.
- `plex.url` / `plex.token` are settings rows too. `PlexEnabled()` is just
  `PlexURL() != "" && PlexToken() != ""`.
- Settings rows override env/config seed, so seeding the DB is the control point.

## Recipe

1. **Build**: `go build -o /tmp/bx ./cmd/boxarr`

2. **Create the schema** by booting once (it runs goose migrations), then kill it.
   Wait properly — `/healthz` does *not* return 2xx without a reachable TorBox,
   so don't gate on it. Just give it a couple of seconds.

3. **Seed the DB** with `sqlite3` (the driver is `modernc.org/sqlite`; the file is
   plain SQLite):

   ```sql
   INSERT INTO settings(key,value) VALUES
     ('torbox.base_url','http://127.0.0.1:9101/v1/api'),
     ('torbox.token','tok'),
     ('interval.poll','10s'),              -- shrink ticks so a run takes seconds
     ('limit.max_create_per_hour','60'),
     ('plex.url','http://127.0.0.1:9102'),
     ('plex.token','tok'),
     ('plex.tv_section','13')
   ON CONFLICT(key) DO UPDATE SET value=excluded.value;
   ```

4. **Stub the endpoints actually used**:
   - TorBox (all wrapped in `{"success":true,"data":...}`):
     `GET /v1/api/user/me`, `POST /v1/api/usenet/createusenetdownload`,
     `GET /v1/api/usenet/mylist`, `GET /v1/api/torrents/mylist`,
     `POST /v1/api/torrents/createtorrent`
   - Plex: `GET /library/sections` (return `MediaContainer.Directory[].Location[].path`),
     `GET /library/sections/{id}/refresh` — a `?path=` query means a *partial*
     scan, absent means a *full section* scan. Log which one you got; that
     distinction is the whole point of the importer's remap logic.

5. **Run** with env: `BOXARR_DATABASE_PATH`, `BOXARR_LISTEN_ADDR`,
   `BOXARR_WEBDAV_MOUNT_ROOT`, `BOXARR_WEBDAV_USENET_SUBPATH=usenet`,
   `BOXARR_SYMLINK_ROOT`, `BOXARR_TORBOX_API_TOKEN`.

## Driving specific paths

- **Submitter pacing / caps** — insert `pending` rows into `jobs`
  (`state,category,nzb_name,nzb_content,protocol`) and count
  `create-usenet` hits on the stub. `submitOnce` runs immediately on start,
  then every `interval.poll`.
- **Plex partial-scan remap** — the cheapest surface is
  `PUT /api/v1/series/{id}/type {"seriesType":"anime"}`. It calls `maybePlexScan`
  for both the new and old library root, even with zero episodes. Seed one
  `series` row and set `library.tv_root` / `library.anime_root`.
- **Budget/limit stats** — `GET /api/v1/storage` returns `limits.usedLastHour`
  and `usedToday`, computed by `CountJobsSubmittedSince`. No auth on `/api/v1`.

## Gotchas

- **Don't seed `submitted_at` with `datetime('now')`.** Go writes that column via
  `time.Time.String()`, producing `2026-07-10 17:20:57.2 +0200 CEST m=+0.02`
  (monotonic suffix and all). The `submitted_at >= ?` comparison is a
  *lexicographic string* compare, so a `YYYY-MM-DD HH:MM:SS` value you inserted
  by hand never matches and the row is silently not counted. To seed a submitted
  job, let the app submit it, or match the Go format exactly.
- Foreground `sleep` is blocked in this harness — run the whole
  start/sleep/kill/report sequence as one backgrounded Bash command.
- Truncating a stub's logfile while the process holds the fd leaves NUL padding;
  pipe through `tr -d '\0'` before grepping.
