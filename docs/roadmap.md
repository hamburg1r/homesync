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

## Milestone 3 — Flutter catalog (list-only)

**Outcome:** Phone shows names/types/sizes/tags from API; opening full file is not required.

- [ ] API client + device registration
- [ ] Local SQLite mirror of catalog subset
- [ ] Browse UI + pull-to-refresh / delta sync
- [ ] Explicit empty/error/degraded states

**Exit check:** Phone lists PC files while online; survives app restart with local catalog.

**E2E:** backend still covers catalog list/delta as the phone would call them (extend metadata/delta scenarios). Flutter device E2E stays deferred.

## Milestone 4 — Pin + materialize

**Outcome:** User pins a file; bytes land on phone; unpin can delete local bytes but keep listing.

- [ ] Availability API + local mode storage
- [ ] Blob GET + local file store
- [ ] Pin UI affordance
- [ ] Disk budget / basic error if missing blob on PC

**Exit check:** Airplane mode: pinned file opens; listed-only file does not.

**E2E:** add `backend/tests/scenarios/test_pin_materialize.py` (availability pin + blob GET). Flutter/Maestro airplane-mode flow is Later.

## Milestone 5 — Phone → PC ingest

**Outcome:** Camera (or share intent) uploads to PC with provenance.

- [ ] Blob PUT + file create with `source_kind`
- [ ] Background-friendly upload queue
- [ ] Confirm Linux retention

**Exit check:** Photo taken on phone appears in PC catalog and blob store.

**E2E:** add `backend/tests/scenarios/test_phone_ingest.py`.

## Milestone 6 — Ghost / restore UX

**Outcome:** WhatsApp-style story works end-to-end.

- [ ] Surface provenance in UI (“from WhatsApp · on PC only”)
- [ ] “Bring to phone” = pin + download
- [ ] Tombstone handling when PC deletes for real

**Exit check:** Delete local copy, still see listing, restore from PC.

**E2E:** add `backend/tests/scenarios/test_ghost_restore.py`.

## Milestone 7 — Thumbnails + search quality

- [ ] Server-side thumbs for images
- [ ] Listed-mode thumb sync (small payloads)
- [ ] Basic search (name, tags; FTS later)

**E2E:** extend scenarios for thumb endpoints / search when they exist.

## Testing / AI guardrails

Backend scenario E2E is the primary AI-proof loop: isolated temp `$HOMESYNC_DATA`, FastAPI `TestClient`, no phone required.

1. Implement a roadmap exit check.
2. Add or update the matching file under `backend/tests/scenarios/` (do not leave green “done” without the scenario).
3. Run `cd backend && uv sync --extra dev && uv run pytest`.
4. Do not skip or delete failing exit-check tests to “finish” a milestone.

See `docs/development.md` (Quality checks) and `AGENTS.md` (Testing).

## Later / maybe

- Flutter `integration_test` or Maestro: browse → pin → airplane-mode open (after Milestone 3–4 UI)
- Multi-device phones
- Auth tokens + NixOS module systemd service
- Hash-dedup blob migration tooling
- EXIF-rich filters, maps, albums
- Export tags to XMP
- Read-only Web UI on PC
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
