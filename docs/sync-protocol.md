# Sync protocol

Homesync sync is **catalog-first**, then **blob-on-demand**.

## Goals

1. Phone can pull a **delta of catalog changes** since last cursor.
2. Phone can **upload** new files + metadata edits.
3. Phone can **set availability** (`listed` / `cached` / `pinned`).
4. Phone can **download blobs by content hash** (resumable ideally).
5. Conflicts stay boring in v1: **last-write-wins** on metadata rows.

## Actors

```mermaid
sequenceDiagram
  participant P as Phone sync engine
  participant A as Daemon API
  participant D as SQLite
  participant B as Blob store

  P->>A: Auth / device hello
  A->>D: upsert devices.last_seen_at
  P->>A: GET /catalog/delta?since=cursor
  A->>D: query updated rows
  A-->>P: files, tags, availability, tombstones, next_cursor
  P->>A: GET /blobs/{hash}
  A->>B: read
  A-->>P: bytes
  P->>A: PUT metadata / availability / upload blob
  A->>D: LWW apply
  A->>B: write if new hash
```

## Device registration

Implemented (Milestone 3 + reclaim):

```http
POST /v1/devices
{
  "device_id": "…",          // client-generated UUID
  "name": "pixel-8",
  "kind": "android"          // linux | android | other
}

GET /v1/devices              # list registered devices (reclaim UI)
GET /v1/devices/{device_id}
```

`POST` upserts by `device_id` and refreshes `last_seen_at`. Store pairing secret / bearer token association when auth exists.

**Phone today:** UUID v4 stored in app prefs — stable across restarts, **not** across reinstalls / cleared app data.

**Reclaim (Settings → Device ID):** list server devices (`GET /v1/devices`) or paste a known UUID; bind this install to that `device_id`, clear local availability for the previous id, reset the catalog cursor, re-register, and full-sync so pin rows for the reclaimed id apply. **Reset identity** mints a new UUID (old server rows remain under the abandoned id).

## Catalog delta

```http
GET /v1/catalog/delta?since=<cursor>&purge_since=<iso>&limit=500
```

**Cursor (v1 implemented):** opaque `v1:{updated_at}|{file_id}` ordered lexicographically by `(updated_at, file_id)`. Empty / omitted `since` = full scan from the beginning. Tag edits and metadata patches bump `files.updated_at` so they appear in subsequent deltas. A changelog table may replace this later without changing the opaque cursor namespace if we bump to `v2:…`.

**Purge cursor:** optional `purge_since` (ISO `purged_at` from a prior page). Response includes `purged: [{file_id, purged_at}]` and `next_purge_cursor` so phones can hard-delete leftover soft-deleted local rows after Linux GC. File cursor and purge cursor advance independently.

Response shape:

```json
{
  "next_cursor": "v1:2026-07-30T12:00:00.000001Z|…",
  "files": [ { "file_id": "…", "content_hash": "…", "title": "…", "updated_at": "…", "deleted_at": null, "tags": ["family"], "has_thumb": false } ],
  "tags": [ { "tag_id": "…", "name": "family", "color": null } ],
  "file_tags": [ { "file_id": "…", "tag_id": "…" } ],
  "availability": [],
  "paths": [ … ],
  "purged": [ { "file_id": "…", "purged_at": "…" } ],
  "next_purge_cursor": "…"
}
```

`availability` includes rows for the `file_id`s in the page (all devices). Phone applies its own device rows; default local mode for new remote files is `listed` when the server sent no row.

## Default availability for remote files

When phone learns about a file that exists only on Linux:

- Insert local availability `listed` for that phone device (unless server already has a row).

Pinned files must appear in availability with `pinned` and trigger blob fetch.

## Blob transfer

Implemented (Milestone 4 GET + Milestone 5 PUT + resumable uploads):

```http
GET /v1/blobs/{algo}/{hash}
PUT /v1/blobs/{algo}/{hash}          # one-shot (small / legacy)
POST /v1/blob-uploads                # begin or resume session
GET /v1/blob-uploads/{upload_id}     # poll acked offset
PATCH /v1/blob-uploads/{upload_id}   # append chunk (Upload-Offset)
```

**Resumable upload (phone ingest default):**

1. Client hashes the file (BLAKE3), then `POST /v1/blob-uploads` with `{algo, content_hash, size_bytes}`.
2. Server returns `upload_id` (`algo:hash`) and current `offset` (0 for new; resume if a partial exists). If the managed CAS object already exists at that hash with matching `size_bytes`, begin returns `complete: true` immediately (path is content-addressed; no full re-hash on begin). Client idle timeout for begin scales with size (not the 15s catalog default).
3. Client `PATCH`es ~4 MiB chunks with header `Upload-Offset: <acked>`. Response `Upload-Offset` is the new ack (TCP-style).
4. Offset behind server (retry / lost ack) → `204` with current `Upload-Offset`. Gap ahead → `409` + `Upload-Offset`; client syncs and continues.
5. When `offset == size_bytes`, server verifies hash on the partial, promotes into managed CAS, and sets `X-Upload-Complete: 1`.
6. Disconnect / stall: client re-`GET`s status (or keeps the last offset if still offline) and continues. Retries network errors for ~30 minutes (30s backoff cap) while the FG service is alive. Partials live under `$data_root/uploads/…` for up to 7 days; per-chunk client timeout is 1 hour. After retries are exhausted the batch stops — opening the app again re-kicks the remaining queue.

Rules (one-shot PUT still apply):

- `GET` resolves managed `blobs/<algo>/<hh>/<hh>/<hash>` first, then a current hash-in-place library path.
- Unknown / missing on disk → `404` (catalog may still list file as degraded).
- Hash mismatch on upload → `400` (PUT) or `409` (resumable finalize).
- Identical existing blob → `200` dedup (`X-Blob-Created: 0`); new object → `201`.
- Size/byte mismatch against an existing object → `409` (never overwrite).
- Response includes `Content-Length`, `ETag`, `X-Content-Hash`, `X-Hash-Algo`. Prefer HTTP range requests when implementing resume.

Pin flow is **two steps**:

1. Set availability `pinned`.
2. Ensure blob present locally (download if needed).

Do not treat step 1 alone as success in the UI.

## Metadata updates

Implemented (Milestone 2):

```http
GET /v1/files
GET /v1/files?q=<substring>   # Milestone 7: title / notes / tag name (case-insensitive)
GET /v1/files/{file_id}
PATCH /v1/files/{file_id}
{
  "title": "…",
  "notes": "…",
  "source_kind": "whatsapp",
  "updated_at": "client-time",
  "base_updated_at": "last-seen-server-time"
}
DELETE /v1/files/{file_id}   # soft-delete (sets deleted_at; frees UNIQUE content_hash via tombstone: sentinel)
POST /v1/gc                  # manual hard-purge + unreferenced blob/thumb/upload GC
GET /v1/tags
PUT /v1/files/{file_id}/tags
{ "tags": ["family", "receipts"] }
```

**Phone tagging (v1):** Flutter detail sheet edits tags online via `PUT …/tags`, then `GET /v1/tags` to resolve `tag_id`s into the local Drift mirror. No offline tag queue. Browse-by-tag remains Later.

**Search (v1):** `q` is a basic substring match on `title`, `notes`, and tag names (SQLite `LIKE`, case-insensitive). FTS is Later. Soft-deleted rows are excluded unless `include_deleted=true`.

**LWW v1:** if `base_updated_at` is sent and does not match the server row, respond `409` with the current file. If `updated_at` is sent and is older than the stored value, also `409`. Otherwise accept and bump `updated_at` (strictly monotonic on the server when the client omits it).

Manual curl smoke: `scripts/metadata_api_smoke.sh` (daemon on `127.0.0.1:8787`, catalog already indexed).

## Garbage collection (manual)

```http
POST /v1/gc
{
  "dry_run": false,
  "purge_tombstones": true,
  "purge_blobs": true,
  "purge_uploads": true,
  "min_age_seconds": 0,
  "file_ids": null
}
```

CLI: `homesync-gc [--dry-run] [--min-age SECONDS] [--file-id …]`.

Behavior:

1. Hard-delete soft-deleted `files` rows (and children) older than `min_age_seconds`; skip files with an **open** KeePass conflict outbox. Record each id in `gc_purges`.
2. Unlink managed `blobs/<algo>/…` and `thumbs/…` objects whose digest is not referenced by remaining file heads, `versions`, or kdbx candidates. Never unlink library-root hash-in-place files.
3. Wipe expired resumable upload partials under `uploads/` (idle > 7 days).

Phones pull `purged[]` via catalog delta (`purge_since` / `next_purge_cursor`) and drop leftover tombstone **catalog** rows. Local pin/CAS bytes are removed only when the file was **Bound to server** (same rule as soft-delete); unbound local copies are left on disk. Local **Forget** on Removed from PC follows the same byte policy.

## Content versions (head + history)

Implemented (Milestone 8):

```http
POST /v1/files/{file_id}/content
{
  "content_hash": "…",
  "hash_algo": "blake3",
  "size_bytes": 1234,
  "note": "optional"
}
GET /v1/files/{file_id}/versions
```

- Requires the new blob in the managed store first (same as ingest).
- Same hash as current head → idempotent no-op.
- Otherwise archives the previous head into `versions`, sets `files.content_hash` / `size_bytes`, bumps `updated_at` (delta clients see the new head under the same `file_id`).
- New hash already used as another file's head → `409` (never merge logical files).
- Soft-deleted file → `400`.
- `GET …/versions` returns `{ file_id, head, versions }` where `head` is the current tip (`is_head: true`) and `versions` lists archived heads newest-first.

Phone tracking: when a bound `localPath` changes bytes (mtime/size gate, then rehash), upload the new blob and `POST …/content` instead of creating a new `file_id`.

## KeePass (.kdbx) conflict outbox

Implemented (Milestone 9):

When `POST /v1/files/{file_id}/content` targets a KeePass vault (title/path ends in `.kdbx` or keepass mime) and the hash differs from head:

1. Both blobs are retained; catalog **head is not changed** until resolve / trivial promote / auto-merge.
2. Daemon unlocks both with a per-`file_id` secret (`PUT /v1/files/{file_id}/kdbx-secret`) and runs a semantic entry/group diff (ported from `diffkpdb`, UUID-aware for moves).
3. **Trivial** (identical entry fields — typical rewrite/mtime noise) → auto-promote incoming head; **no client outbox**.
4. **Auto-mergeable real** diffs (no entry UUID removed on the incoming side — additions, field edits, and moves OK) → daemon **union-merges** both vaults, last-write-wins on entry fields/location by KeePass `mtime` (tie → incoming), stores the merged blob, promotes it as head.
5. **True removals** (entry UUID present on head, absent on incoming) → HTTP **202** + conflict payload; open outbox.
6. Extra divergent uploads while open are queued as more **candidates**.
7. Phone resolves interactively (preferred) or uploads a merged `AB`:
   - `mode=entries` — keep/discard per contested entry UUID; daemon merges and promotes.
   - `mode=candidate` — promote an existing candidate hash (Keep PC / Keep phone).
   - `mode=upload` (default / legacy) — promote an already-uploaded blob.
8. After saving the vault secret for a `needs_secret` conflict, `POST …/recheck` re-runs classify/auto-merge on stored candidates (no re-upload).

Active conflict `diff_summary` (redacted) includes stable UUIDs for choices:

- `removed_entry_uuids` / `added_entry_uuids`
- `modified_entries`: `{ uuid, identity, fields }` (field **names** only)
- `auto_mergeable`

```http
PUT  /v1/files/{file_id}/kdbx-secret
{ "password": "…" }
GET  /v1/conflicts?state=active
GET  /v1/conflicts?state=open
GET  /v1/conflicts?state=needs_secret
# `active` (default) = open | needs_secret | diff_failed
# exact state filters a single status; omit only via API clients that pass null
GET  /v1/conflicts/{conflict_id}
POST /v1/conflicts/{conflict_id}/recheck
POST /v1/conflicts/{conflict_id}/resolve
# upload (legacy default):
{ "mode": "upload", "content_hash": "…", "hash_algo": "blake3", "size_bytes": N, "note": "…" }
# whole-vault candidate:
{ "mode": "candidate", "content_hash": "…", "size_bytes": N }
# interactive entry choices (base+incoming only; 409 if extra candidates):
{
  "mode": "entries",
  "base_hash": "…",
  "incoming_hash": "…",
  "choices": [
    { "entry_uuid": "…", "keep": "base" },
    { "entry_uuid": "…", "keep": "incoming" },
    { "entry_uuid": "…", "keep": "discard" }
  ],
  "note": "resolved on phone"
}
```

`entries` keep semantics: removals — `base` retain PC entry, `incoming`/`discard` omit; adds — default keep phone, `discard` drops; modified — `base` or `incoming` fields/location (unmentioned shared entries stay LWW). Secrets live in `~/.config/homesync/kdbx_secrets.json` (or `$HOMESYNC_KDBX_SECRETS`), mode `0600` — **not** in catalog SQLite. Diff summaries never include password values.

Phone: drawer / ⋮ → **KeePass conflicts** → detail (whole-vault + per-entry); tracking does **not** require Bound to server.

Multi-way entry merge across 3+ candidates is out of scope (whole-vault pick only).

## Thumbnails (listed-mode previews)

Implemented (Milestone 7):

```http
GET /v1/thumbs/{file_id}
```

- Returns a small JPEG (`Content-Type: image/jpeg`), generated on demand from the full blob (managed store or hash-in-place).
- Cached under `$data_root/thumbs/<hh>/<hh>/<content_hash>.jpg` (content-addressed; max edge 256px).
- Catalog `files[].has_thumb` is a client hint (`true` when `mime_type` starts with `image/`). Phone may `GET` the thumb without materializing full bytes (listed mode).
- Missing file / missing source blob → `404`. Non-image / undecodable → `415`.

Phone: cache thumbs locally by content hash; search filters the local Drift catalog by title/notes/tags (server `?q=` remains available for API clients).

## Availability updates

Implemented (Milestone 4):

```http
PUT /v1/files/{file_id}/availability/{device_id}
{ "mode": "pinned", "updated_at": "…", "base_updated_at": "…" }
GET /v1/files/{file_id}/availability/{device_id}
```

Modes: `listed` | `cached` | `pinned`. Upsert is LWW on `updated_at` (optional `base_updated_at` → `409` on mismatch). Setting availability bumps `files.updated_at` so catalog delta clients observe the change (same pattern as tags).

Server should allow a device to update **its own** availability primarily. Cross-device admin can wait.

## Phone ingest (camera / exports)

Implemented (Milestone 5):

```http
POST /v1/blob-uploads
PATCH /v1/blob-uploads/{upload_id}   # Upload-Offset chunks until complete
# (legacy one-shot still accepted:)
PUT /v1/blobs/{algo}/{hash}
POST /v1/files
{
  "content_hash": "…",
  "hash_algo": "blake3",
  "size_bytes": 1234,
  "mime_type": "image/jpeg",
  "title": "IMG_001.jpg",
  "taken_at": null,
  "source_kind": "camera",
  "source_device_id": "…",
  "relative_path": null
}
PUT /v1/files/{file_id}/availability/{phone_device_id}
{ "mode": "pinned" }
```

```mermaid
sequenceDiagram
  participant Phone
  participant API
  participant Store
  participant DB

  Phone->>API: POST /v1/blob-uploads (hash, size)
  loop until offset == size
    Phone->>API: PATCH chunk (Upload-Offset)
    API-->>Phone: Upload-Offset ack
  end
  API->>Store: promote partial → CAS
  Phone->>API: POST /v1/files
  Note over Phone,API: includes provenance source_kind=camera, source_device_id=phone
  API->>DB: create file_id or dedup by hash
  API->>DB: pin linux-host availability (retention)
  API-->>Phone: file metadata
  Phone->>API: PUT availability pinned for phone
```

- `POST /v1/files` requires the managed blob to exist first (`400` otherwise).
- Dedup by `(hash_algo, content_hash)` returns the existing `file_id` and attaches provenance when needed.
- Standalone ingest uses `file_paths.root_id = NULL` and a synthetic `relative_path` under `ingest/<source_kind>/…`.
- Linux retention: create pins the host `linux` device to `pinned` so the managed blob is kept.
- Phone queue order: **blobs → file create → availability** (durable SharedPreferences queue; flushed on catalog sync). Tracking ingest hashes and uploads **one file at a time** via **resumable chunked upload** from the **original path** (no app-storage duplicate). Pin store is only for PC→phone materialization / small in-memory ingest. UI shows per-file progress (hash → upload). File detail shows on-device path (and catalog relative path when mirrored); **Open** launches an Android `ACTION_VIEW` intent via `open_filex`.
- **Tracking rules (phone):** named regex/folder/**file** rules in Settings (empty = no auto upload). Group name optional (default `misc`). Top-level rules start **disabled** (enable manually after adding include filters). Folder rules recurse the whole directory tree; optional **include-regex children** under a folder (no children ⇒ track all; with children ⇒ must match ≥1 **enabled** child — never falls back to whole-tree). Disabling a rule cancels its pending/failed uploads (in-flight may finish). Scans always list + recurse + re-stat (cheap skip is file size/mtime vs local index). Pull-to-refresh is forced and, inside a drawer **group** (folder rule), walks only that folder (plus folders-view prefix when drilled in); a second pull while refresh is in progress is ignored. AppBar **Force full rescan** walks all rule roots. Browse: flat list (default) or folders; group view can hide extensions (UI only). Per-rule optional tags and optional `source_kind` override (editable later; saving re-syncs matching synced files — tags via `PUT /files/{id}/tags`, provenance via `PATCH /files/{id}` `source_kind`). When multiple rules hit the same file, **tags union**; `source_kind` uses most-specific override (file → folder-child → folder → top-level regex → path heuristic). Folder ingest preserves `relative_path` as `track/<name>/<path under folder>` (not basename-only). Scanner walks granted storage roots for top-level regex/folder; file rules target one absolute path. When unset, `source_kind` is inferred from path (`DCIM`→camera, WhatsApp→whatsapp, Download→download, else `misc`). Matches auto-ingest via the durable queue. Tracked files waiting to upload show chip **`pending`**; failures show **`failed`** — not availability `listed`. Catalog refresh indexes first then kicks **background ingest** (does not wait for uploads). On Android a `dataSync` foreground service starts early (while still foreground); main isolate hashes/enqueues, **upload HTTP runs in the task isolate** (no Drift there), then main commits catalog rows — so Home does not abort sockets and dual-isolate SQLite is avoided; durable queue resumes on app resume.
- **Sync pause (phone):** Settings → Sync with PC off skips catalog delta + tracking ingest; local catalog remains browsable. Soft-delete from a file’s detail sheet calls `DELETE /v1/files/{id}` (tombstone until `POST /v1/gc` / `homesync-gc`).

## WhatsApp-style restore (canonical story)

Implemented (Milestone 6):

Preconditions:

- File was ingested to Linux (backup/export/indexer).
- Catalog still has `file_id` + `content_hash` + path on PC.
- Phone local bytes deleted; availability may be `listed` or absent.

```mermaid
flowchart TD
  A[User opens ghost item on phone] --> B[Show metadata + thumb if any]
  B --> C[User taps Bring to phone]
  C --> D[PUT availability=pinned]
  D --> E[GET blob by hash]
  E --> F{Blob on Linux?}
  F -->|yes| G[Write local pinned file]
  F -->|no| H[Show degraded: missing on PC]
```

- Catalog delta includes `paths[]` with `source_kind` / `source_device_id`.
- Phone mirrors paths locally and surfaces provenance (`from WhatsApp · on PC only` when listed without bytes).
- **Bring to phone** = same as pin (availability `pinned` + blob GET). When bytes are not already on device, the UI asks for a **download folder + file name** (default from Settings → Pin download folder; empty = app `homesync_pins` CAS). Custom destinations are recorded in `pin_local_paths`.
- **Keep on PC only** = availability `listed` + delete local copies (CAS pin store, custom pin path, and phone-origin path if present). Catalog listing remains (ghost again).
- Soft-delete on PC (`DELETE /v1/files/{id}`) → tombstone in delta (`deleted_at` set); phone drops the **active** listing. Drawer → **Removed from PC** lists those soft-deleted rows (chip `removed`, not `pinned`). Local pin bytes remain unless **Bound to server**; **Remove from device** discards them without a server call. Explicit **Remove from PC** on the phone still drops local bytes. **Forget** drops the local tombstone row without waiting for GC. Linux `POST /v1/gc` (or `homesync-gc`) hard-purges eligible tombstones + unreferenced managed blobs/thumbs; delta `purged[]` removes leftover phone mirrors.

Provenance rows explain *why* it still exists (“imported from WhatsApp backup on nixos”).

## Conflict matrix (v1)

| Conflict | Resolution |
|---|---|
| Tag edit on phone + PC | LWW by `updated_at` |
| Title edit both sides | LWW |
| Same file pinned on phone, deleted on PC catalog | Tombstone wins if `deleted_at` newer; else keep and mark degraded |
| Two different byte payloads claimed as same `file_id` | Archive old head in `versions`, set new head — never merge bytes |
| Upload hash already exists as another file's head | Dedup on create; `409` on content replace |
| Upload hash already exists (create) | Dedup; attach path/provenance |

## Auth (planned)

```http
Authorization: Bearer <device-token>
```

Until then, rely on network isolation and document the risk in development notes.

## Versioning the API

Prefix with `/v1/`. Breaking changes bump to `/v2/` or negotiated `Accept` version. Catalog cursor format changes are breaking—version the cursor namespace if needed (`v1:12345`).

## Offline queue (phone)

Phone should queue:

- metadata patches
- availability changes
- blob uploads

Flush on reconnect in order: **blobs first** (so hashes exist), then file rows, then availability/tags.

```mermaid
flowchart LR
  Q1[Queued blob uploads] --> Q2[Queued file/metadata] --> Q3[Queued availability]
```

## Non-goals for protocol v1

- Real-time websocket-only sync (polling deltas is fine).
- P2P phone-to-phone without PC.
- Encrypted blob fields end-to-end (maybe later).
- Partial file logical streaming editors (video scrub without download can be a later optimization).
