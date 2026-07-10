# Code review — 2026-07-10

Deep review triggered by "downloads slow to add to TorBox and to Plex." Base commit
`168d248`. Six parallel reviewers swept worker, store, api, catalog/selection/release,
external clients, and infra. This file records what was **fixed** and what is
**deferred** so the deferred set doesn't get lost.

Runtime verification harness: `.claude/skills/verify/SKILL.md` (drive the real binary
against stub TorBox/Plex servers).

## Fixed in this pass

Directly explains the reported slowness:

- **Usenet submitter capped at ~1 grab/min.** `perTickBudget` derived the per-tick
  budget from the poll interval → 1 on defaults. Replaced with a bounded burst
  (`maxBurstPerTick = 10`) against the rolling hourly headroom. `worker/submitter.go`.
- **Torrent grabs consumed the usenet hourly cap.** `CountJobsSubmittedSince` pooled
  protocols; now takes a `protocol` arg (empty = all). `store/store.go`, `worker/submitter.go`.
- **Poller blocked up to 30s per stalled download, serially.** Pollers now use a 2s
  probe (`pathProbeTimeout`) and retry next tick; healer keeps the full 30s. `worker/poller.go`.
- **Plex told to scan non-existent folders (silent no-op).** Two remap bugs in
  `plexScanTarget`: sibling-prefix match, and a single-location fallback that rebased a
  nested root onto its parent. Also the anime→TV-section fallback kept the wrong root.
  `worker/importer.go`. Runtime-verified.
- **Permanently-failed jobs spent the per-tick create budget.** `worker/submitter.go`.

Other correctness/security, low-risk, fixed with tests:

- **CRITICAL: rolled-back imports corrupted the catalog.** `ResetImportLinks` wrote
  `job_id=0` into a FK column (jobs.id is AUTOINCREMENT, never 0) → constraint failure →
  row stranded as permanently "downloaded" pointing at a deleted symlink, never
  re-searched. Now writes NULL. `store/store_catalog.go`.
- **German-as-required never worked as the language goal.** `idealLangs` consulted only
  the preferred list; with DE-required/EN-preferred the goal was effectively English, so
  German releases were skipped and German imports re-searched forever. Now unions
  required+preferred, required-first. `catalog/upgrade.go`.
- **Plex language matching was a substring/prefix test.** `und`/"Undetermined" satisfied
  the German requirement; "French" matched "en"; Javanese matched "ja". Now exact. `plex/language.go`.
- **Auto-grab scoring ignored resolution & quality** (the two heaviest weights) because
  it scored releases with only a title populated — could grab 480p over 2160p. Now parses
  the title. Same fix in the healer's replacement search. `catalog/search.go`, `worker/heal_research.go`.
- **Prowlarr API key leaked to indexer hosts** on cross-host redirect, and the prefix
  check that gates it matched `prowlarr:9696.attacker.example`. Now strips the header
  cross-host and matches scheme/host/path. `prowlarr/prowlarr.go`.
- **A panic in any task or worker loop killed the process.** Both now recover + log.
  `task/task.go`, `worker/worker.go`.
- **Seerr API keys served in cleartext** from `GET /api/v1/settings`. `settings/api.go`.
- **Reaper deleted imported jobs hours early/late by timezone.** Now DB-clock vs DB-clock.
  `store/store.go`, `worker/reaper.go`.
- **Truncated-artifact read error dropped** → shipped bad NZBs. `prowlarr/prowlarr.go`.
- Dashboard "grabs today" counted usenet only; cooldown/`usedToday` scoping corrected.
  `api/v1/storage.go`.

## Deferred — real, verified by a reviewer, NOT yet fixed

Ranked roughly by impact. Each was confirmed by reading code and/or a throwaway probe.

### Selection / parsing (catalog, selection, release)

1. **Auto-grab `Cached` not populated for torrents.** The catalog service has no TorBox
   client, so uncached torrents score one tier low in the automatic path (the manual UI
   sets it correctly). Fixing needs wiring a checkcached batch into the auto path.
   `catalog/search.go:scoreRelease`.
2. **Quality-upgrade check compares empty structs.** `shouldGrabUpgrade` scores
   `selection.Release{Title: candidate}` vs `{Title: current}` — resolution/quality zero on
   both sides, so an upgrade can replace a UHD remux with a 480p WEBRip. Same root cause as
   the fixed auto-grab bug, different call site. `catalog/upgrade.go:201`.
3. **Anime absolute-vs-season mismap.** anitogo's season-relative episode number is stored
   as absolute, so `[Group] Show S02E11` fills episode 11 with episode 23's file.
   `release/parse.go:126` + `catalog/scene.go:135`.
4. **Failure-prone-group penalty is a hard reject, not a deprioritization.** Subtracting
   `WeightPreferredGroup` (150) can push score below `MinScore` (0). `selection/score.go:238`.
5. **`sceneNumbers` comparator is not a strict weak ordering** — switches sort keys when
   AirDate is empty on one side, yielding cycles → unstable scene numbering.
   `catalog/scene.go:53`.
6. **Multi-season/episode packs collapse.** `S01-S03` parses as season 1; `S01E01E05`
   claims E02-E04. `release/parse.go:49,79`.
7. **`ep.JobID = jb.ID` is a dead store** in both episode search paths (only movie persists
   it), so `episode.job_id` stays 0 until import and upgrade comparison can't find the job.
   `catalog/search.go:120`, `catalog/searchall.go:119`.

### API / auth (api/v1, api/seerr)

8. **`?url=` on Plex test/section endpoints exfiltrates the stored Plex token** to any host
   (server-side request carries the saved token). `api/v1/plex.go:84`, `test.go:74`.
9. **Unsigned `releaseId` token → SSRF.** `decodeReleaseID` base64-decodes a client blob
   with no signature; `DownloadURL` flows into an outbound GET, and ≥400 bodies are echoed
   back (readable SSRF). `api/v1/search.go:34`, `grab.go:85`.
10. **Episode endpoints ignore the `{id}` series segment** — reset/monitor/search/grab act
    on the raw `episodeId`, so a destructive action can hit another series' episode.
    `api/v1/series.go:317,345,461,505`.
11. **`/healthz` leaks upstream error strings** (driver/HTTP/DB-path) to unauthenticated
    callers. `api/handlers.go:90`.
12. **Seerr write paths that silently no-op or lie:** `POST /series` on an already-tracked
    series drops seasons and returns 201; episode-level re-request sets only the episode
    flag (no cascade/re-derive); `PUT series` decodes `monitored` and ignores it; delete
    endpoints return 200 for ids that don't exist or failed to delete. `api/seerr/sonarr.go`,
    `radarr.go`.
13. **Search results keyed by title collide** — two indexers returning the same scene name
    keep only the last, so the row you click (e.g. `cached:true`) can grab the other's
    release. `api/v1/search.go:167`.

### Clients (torbox, plex, prowlarr, metadata)

14. **TorBox retries non-idempotent create POSTs.** A transport error/timeout after the
    server created the download re-POSTs → duplicate download, both spending the create
    budget. Needs an idempotency key or narrower retry. `torbox/client.go:208`, `worker/submitter.go`.
15. **`inCooldown` tests presence, never compares to now** — dashboard shows a permanent
    cooldown banner. `api/v1/storage.go:80`.
16. **Raw `baseURL + path` double-slash** — a pasted trailing-slash URL 404s every call with
    no hint. `plex/plex.go`, `prowlarr`, `tmdb`, `torbox`.
17. **Unescaped indexer info-hashes in a query string** — `#`/`&` corrupt the checkcached
    request. `torbox/torrent.go:201`.

### Store / infra

18. **`submitted_at` stored as Go local-zone `String()`** (monotonic suffix and all), compared
    as text. Works in one TZ today; breaks across a container TZ change or DST fall-back.
    Proper fix: `_time_format=sqlite` in the DSN, or store `.UTC()` — migration-shaped, kept
    out of this pass. Also affects completed_at/last_healed_at/last_metadata_sync at rest.
    `store/store.go:619` (`nullTime`).
19. **Unprefixed env fallback.** envconfig accepts bare `API_KEY`/`PLEX_TOKEN`/`DATABASE_PATH`
    etc. alongside `BOXARR_*`, so a shared compose var can silently configure Boxarr.
    `config/config.go:138`.
20. **Interval settings claim to hot-reload but don't** — `interval.poll` etc. are snapshotted
    at `Run()` and never re-read. `worker/worker.go:139`.
21. **Secrets world-readable** — the settings DB (and `-wal`) hold cleartext tokens at 0644.
    `store/store.go:37`.
22. **`putSettings` is non-atomic** — a mid-loop failure leaves a half-applied config; bad
    durations/ints are silently swallowed by the getters. `api/v1/v1.go:251`.
23. **In-flight adopt/delete tasks abandoned at shutdown** — the task goroutine isn't joined
    and `st.Close()` can fire underneath it. `cmd/boxarr/main.go:135`; `task.Enqueue` can also
    block an HTTP handler forever when the queue fills. `task/task.go:137`.
24. **`UpsertRootFolder` ON CONFLICT(id)** can't re-point a root to a path another row holds
    (path is UNIQUE). No production caller today. `store/store_settings.go:120`.

### Smaller / latent

- `worker.loop` never `t.Reset`s, so a slow iteration runs back-to-back and the Status page's
  `nextRun` lies. `worker/worker.go:213`.
- `heal.prowlarr_fallback` is read but not in any writable-keys set (unreachable write).
- `MaxTorrentPerMin` setting paces nothing (dead knob).
- `plexLocCache` caches a `nil` result for an unmatched section, permanently forcing full
  scans. `worker/importer.go:170`.
- `UpdateJob` silently drops `is_upgrade` on a round-trip (only set at creation today).

## Reviewer-refuted (so we don't re-chase)

Keep-alive is intact (all clients share `http.DefaultTransport`); every client has a timeout;
`resp.StatusCode` is checked everywhere; `parseRetryAfter`/`RateLimit` handle 429 + both
Retry-After forms with correct units. `logbuf` has no race/aliasing/off-by-one. `settings.Store`
has no lock-order inversion. Env precedence (`BOXARR_*` wins) is correct — the fallback (#19) is
the separate issue.
