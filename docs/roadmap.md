# Roadmap

Ordered so each step is usable alone. Resist implementing later steps first.

## North star

Phone browses a rich catalog of PC-held files, pins what matters offline, tags everything, and can restore phone-originated files that now live only on Linux.

```mermaid
flowchart LR
  S1[1 Indexer] --> S2[2 Metadata API]
  S2 --> S3[3 Phone list-only]
  S3 --> S4[4 Pin + download]
  S4 --> S5[5 Phone ingest]
  S5 --> S6[6 Ghost restore UX]
  S6 --> S7[7 Thumbs + search]
  S7 --> S8[8 Content versions]
  S8 --> S9[9 KeePass conflicts]
```

## Milestone 0 — Scaffolding (done)

- [x] Monorepo under `~/repo/homesync`
- [x] Nix flake with light backend + mobile shells
- [x] Python FastAPI `/health`
- [x] Flutter Android skeleton
- [x] Design docs + `AGENTS.md`
- [x] Backend scenario E2E harness (`backend/tests/`, health smoke)

**Exit check:** `cd backend && uv sync --extra dev && uv run pytest` passes (health).

**E2E:** `backend/tests/test_health.py`

## Milestone 1 — Indexer on Linux (done)

**Outcome:** Point at a folder; SQLite fills with `file_id`, hash, paths, basic mime/size.

- [x] Data dir + SQLite bootstrap + `schema_version`
- [x] Content-addressed blob store **or** “hash in place” mode for first iteration  
      Recommendation: start with **hash-in-place** (file stays in library root; DB stores hash+path), then optionally copy/dedup into `blobs/` for unmanaged sources.
- [x] Walk `library_roots`, compute hash, upsert `files` / `file_paths`
- [x] Soft-detect gone paths (`gone_at`)

**Exit check:** CLI or logs show N files indexed; re-run is idempotent.

**E2E:** `backend/tests/scenarios/test_indexer.py`

## Milestone 2 — Metadata API (done)

**Outcome:** Tag and fetch files without Flutter.

- [x] CRUD-ish file metadata endpoints
- [x] Tags + file_tags
- [x] Catalog delta endpoint (even if crude cursor)
- [x] Manual curl/httpie script in docs or `scripts/`

**Exit check:** Tag a file via API; delta returns it.

**E2E:** `backend/tests/scenarios/test_metadata_api.py`

## Milestone 3 — Flutter catalog (list-only) (done)

**Outcome:** Phone shows names/types/sizes/tags from API; opening full file is not required.

- [x] API client + device registration
- [x] Local SQLite mirror of catalog subset
- [x] Browse UI + pull-to-refresh / delta sync
- [x] Explicit empty/error/degraded states

**Exit check:** Phone lists PC files while online; survives app restart with local catalog.

**E2E:** `backend/tests/scenarios/test_phone_catalog.py`. Flutter: `mobile/test/scenarios/phone_catalog_test.dart` (+ cubit/browse). Device E2E deferred.

## Milestone 4 — Pin + materialize (done)

**Outcome:** User pins a file; bytes land on phone; unpin can delete local bytes but keep listing.

- [x] Availability API + local mode storage
- [x] Blob GET + local file store
- [x] Pin UI affordance
- [x] Disk budget / basic error if missing blob on PC

**Exit check:** Airplane mode: pinned file opens; listed-only file does not.

**E2E:** `backend/tests/scenarios/test_pin_materialize.py` (availability pin + blob GET). Flutter: `mobile/test/scenarios/pin_materialize_test.dart`. Device/Maestro airplane-mode flow is Later.

## Milestone 5 — Phone → PC ingest (done)

**Outcome:** Camera (or share intent) uploads to PC with provenance.

- [x] Blob PUT + file create with `source_kind`
- [x] Background-friendly upload queue
- [x] Confirm Linux retention

**Exit check:** Photo taken on phone appears in PC catalog and blob store.

**E2E:** `backend/tests/scenarios/test_phone_ingest.py`. Flutter: `mobile/test/scenarios/phone_ingest_test.dart` (queue + API). Camera/share UI polish is Later.

## Milestone 6 — Ghost / restore UX (done)

**Outcome:** WhatsApp-style story works end-to-end.

- [x] Surface provenance in UI (“from WhatsApp · on PC only”)
- [x] “Bring to phone” = pin + download
- [x] Tombstone handling when PC deletes for real

**Exit check:** Delete local copy, still see listing, restore from PC.

**E2E:** `backend/tests/scenarios/test_ghost_restore.py`. Flutter: `mobile/test/scenarios/ghost_restore_test.dart`.

## Milestone 7 — Thumbnails + search quality (done)

- [x] Server-side thumbs for images
- [x] Listed-mode thumb sync (small payloads)
- [x] Basic search (name, tags; FTS later)

**Exit check:** Image files expose `has_thumb`; `GET /v1/thumbs/{file_id}` returns a small JPEG without requiring a full pin; `GET /v1/files?q=` matches title/tags.

**E2E:** `backend/tests/scenarios/test_thumbs_search.py`. Flutter: `mobile/test/scenarios/thumbs_search_test.dart`.

## Milestone 8 — Content versions (done)

**Outcome:** Same logical `file_id` can change bytes; previous head is archived; phone tracking re-uploads edits without minting a new id.

- [x] `versions` table + migration `004`
- [x] `POST /v1/files/{file_id}/content` + `GET /v1/files/{file_id}/versions`
- [x] Phone: mtime/size gate on tracked paths → rehash → content replace when bound
- [x] Scenario E2E (backend + Flutter)

**Exit check:** Content replace keeps `file_id`, archives old hash, catalog delta shows new head; bound phone path hash change does not create a second `file_id`.

**E2E:** `backend/tests/scenarios/test_content_versions.py`. Flutter: `mobile/test/scenarios/content_versions_test.dart`.

## Milestone 9 — KeePass conflicts (done)

**Outcome:** Divergent `.kdbx` uploads keep both hashes; trivial semantic diffs auto-resolve; non-deletion real diffs (adds / moves / field edits) auto-merge with LWW by entry `mtime`; true entry UUID removals open a multi-candidate outbox; phone uploads resolved `AB`.

- [x] Port semantic diff + `pykeepass` via uv
- [x] `kdbx_conflicts` / candidates migration; local secrets file; `PUT …/kdbx-secret`
- [x] kdbx-aware `POST …/content` (202 outbox) + resolve API
- [x] Phone outbox UI + scenario tests
- [x] UUID-aware move detection; daemon auto-merge (union + LWW) when incoming drops no entry UUIDs

**Exit check:** Trivial rewrite auto-promotes head with no open conflict; add/move/LWW edit auto-merges; deletion returns 202; resolve sets single head and closes outbox.

**E2E:** `backend/tests/scenarios/test_kdbx_conflicts.py`. Flutter: `mobile/test/scenarios/kdbx_conflicts_test.dart`.

## Testing / AI guardrails

Two phone-free loops:

**Backend** — isolated temp `$HOMESYNC_DATA`, FastAPI `TestClient`:

1. Implement a roadmap exit check.
2. Add/update `backend/tests/scenarios/test_*.py`.
3. Run `cd backend && uv sync --extra dev && uv run pytest`.

**Mobile** (when changing `mobile/`) — Drift memory + MockClient:

1. Implement the client-side exit check.
2. Add/update `mobile/test/scenarios/*_test.dart`.
3. Run `nix develop .#mobile --command ./scripts/mobile_check.sh`.

Do not skip or delete failing exit-check tests to “finish” a milestone. Device/Maestro E2E remains Later.

See `docs/development.md` (Quality checks) and `AGENTS.md` (Testing).

## Later / maybe

- Flutter `integration_test` or Maestro: browse → pin → airplane-mode open (after Milestone 3–4 UI)
- Multi-device phones
- Auth tokens + NixOS module systemd service
- Hash-dedup blob migration tooling
- EXIF-rich filters, maps, albums
- Export tags to XMP
- Read-only Web UI on PC
- Linux evacuate / remote-only path: after ingest into blobs, unlink source; keep catalog listing + path attribute (host analog of phone listed)
- CRDTs (only if LWW proves painful)

## Explicit non-goals (for now)

| Non-goal | Why |
|---|---|
| Full CRDT sync | Complexity; LWW enough for single user |
| Flutter Linux desktop client | Human preference: Android only |
| Public internet exposure | Security |
| Replacing all Syncthing uses | Different tool |
| Perfect WhatsApp integration without exports | OS/API constraints; use backup/export folders |

## Decision log (append-only)

Record important choices here as they happen.

| Date | Decision | Rationale |
|---|---|---|
| 2026-07-30 | Python + uv daemon; Flutter Android | Ship speed; potato PC; learning path |
| 2026-07-30 | Catalog + availability modes | Fits list/pin/restore requirements |
| 2026-07-30 | Nix default shell = backend only | Avoid heavy Flutter deps on every enter |
| 2026-07-30 | Avoid Nix `withPackages` for app deps | Prevents compiling SciPy/Pillow via Nix |
| 2026-07-30 | Backend scenario E2E first; Flutter E2E later | AI loops need phone-free pytest; device UI waits for list/pin |
| 2026-07-30 | Blobs at `blobs/<algo>/<hh>/<hh>/<fullhash>`; collision = refuse overwrite | Fan-out for FS/GUI; algo prefix for API + migration; never silent CAS overwrite |
| 2026-07-30 | Milestone 1: hash-in-place + BLAKE3 (uv) | Ship indexer without blob copy; blake3 via uv wheels, not Nix withPackages |
| 2026-07-30 | Milestone 2: `(updated_at, file_id)` delta cursor `v1:…` | Crude changelog without extra table; tag edits bump `files.updated_at` |
| 2026-07-31 | Future host “send-and-remove” = catalog + path attr without bytes at that path | Host analog of phone listed; blobs remain SoT for content; deferred after mobile list/pin/ingest |
| 2026-07-31 | Milestone 3: Flutter list-only + `POST /v1/devices`; local sqflite mirror | Catalog delta → phone DB; listed UI without blob open; pin/materialize is M4 |
| 2026-07-31 | Phone catalog mirror: Drift (SQLite) + Bloc/Cubit; not Riverpod; blobs stay on filesystem | Typed migrations + watch queries before M4 availability; Cubit for sync UI states |
| 2026-07-31 | Mobile foundation: feature-first flatter layout; get_it/injectable; freezed DTOs; logger; http not dio; codegen gitignored | Small-app stack; audit logs; agents run build_runner via mobile_check.sh |
| 2026-07-31 | Flutter phone-free scenarios co-equal for `mobile/` changes | Mirror backend pytest guardrail without requiring a device |
| 2026-07-31 | Milestone 4: availability API + blob GET; phone pin = mode + materialize; disk budget | Unpin deletes local bytes, keeps listing; hash-in-place still serves GET |
| 2026-08-02 | Milestone 5: blob PUT + POST /files ingest; Linux host pinned on create; phone durable queue | Managed CAS for phone uploads; provenance on file_paths; camera UI polish Later |
| 2026-08-03 | Phone tracking rules (regex + folder) + drawer browse; path-inferred source_kind; misc default group name | Full FS walk not MediaStore; folder/tag browse Later |
| 2026-08-03 | Milestone 6: provenance in catalog UI; Bring to phone = pin; tombstone drops listing + local bytes | Ghost restore via paths mirror + existing pin/blob APIs |
| 2026-08-03 | Milestone 7: Pillow thumbs via uv; GET /v1/thumbs; has_thumb hint; GET /v1/files?q= | Listed-mode JPEG cache by content hash; basic LIKE search (FTS Later) |
| 2026-08-03 | Phone: sync pause + Remove from PC + file tracking rules | Pause skips delta/ingest; soft-delete via existing DELETE; single-path rules |
| 2026-08-03 | Phone `pin_server_binds`: Bound to server → delete pin on tombstone | Default keeps local bytes after PC soft-delete; opt-in for pinned only |
| 2026-08-03 | Drawer **Removed from PC** lists soft-deleted catalog rows | Tombstones stay out of All; bytes may remain on device when unbound |
| 2026-08-03 | Tombstone demotes local availability; Remove from device discards bytes | Stale `pinned` chip on deleted rows; local discard needs no availability API |
| 2026-08-03 | Phone→PC ingest from original path only (no `homesync_pins` copy) | Avoid duplicating camera/Downloads under app storage; pin store stays PC→phone |
| 2026-08-03 | Resumable blob uploads: `POST/PATCH /v1/blob-uploads` + offset ack | Large-folder stalls; reconnect resumes; 4 MiB chunks; 1h chunk timeout; partials ≤7d |
| 2026-08-03 | File detail shows path; Open uses Android VIEW intent (`open_filex`) | In-app text preview was a dead end; system apps handle mime types |
| 2026-08-03 | Keep on PC only = listed + delete all local copies (CAS / custom / origin) | Clear “remove from device, retain PC”; replaces vague Unpin for user-facing |
| 2026-08-03 | PC→phone materialize path: settings default + per-download folder/name | Was app-only `homesync_pins`; users need Downloads-style destinations |
| 2026-08-03 | Device reclaim: `GET /v1/devices` + Settings reclaim/reset | Survive reinstall without orphaning availability keyed by device_id |
| 2026-08-03 | Settings sheet wraps content in SafeArea | Full-height modal collided with status/notification bar |
| 2026-08-03 | Tracked pending/failed show upload chip (not listed) | Was mapped to availability listed; onIndexed refreshes list mid-scan |
| 2026-08-03 | Ingest: BLAKE3 on isolate; throttle progress; scoped rebuilds | Per-chunk UI rebuilds + main-isolate hash caused frame skips |
| 2026-08-03 | Background ingest + Android `dataSync` FG service | Refresh must not wait for uploads; survive app background |
| 2026-08-03 | Ingest HTTP runs in FG task isolate (not UI isolate) | Home paused UI isolate and aborted sockets mid-upload |
| 2026-08-03 | FG task: HTTP-only jobs; main owns Drift/queue | Dual-isolate DI/Drift caused `flush failed` |
| 2026-08-03 | Milestone 8: head+history versions under stable `file_id`; not file↔file links | Path is local binding only; history starts at first observation; `POST …/content` archives old head |
| 2026-08-03 | Milestone 9: kdbx conflict outbox; daemon secret for trivial semantic auto-diff; collision = bound `file_id` only | Phone interactive resolve for real entry diffs; Bound-to-server unrelated |
| 2026-08-03 | kdbx auto-merge: union + LWW by entry mtime when incoming drops no UUIDs; moves OK; true deletions → outbox | Was outbox for any real field/entry diff |
| 2026-08-03 | Tracking: folder include-regex children + tags/source_kind; preserve relative_path under folder | Exclude children later; no new tracker kind |
| 2026-08-03 | Tracking rule edit re-syncs tags + source_kind; multi-rule tag union; PATCH source_kind | Most-specific source_kind when several rules match |
| 2026-08-03 | Manual GC: `POST /v1/gc` + `homesync-gc`; `gc_purges` + delta `purged[]` | Soft-delete until explicit hard-purge; phone Forget for leftover Removed rows |
| 2026-08-03 | Phone tag edit via PUT `/files/{id}/tags` + chip UI in detail sheet | Display/search already existed; write path was missing; browse-by-tag Later |
