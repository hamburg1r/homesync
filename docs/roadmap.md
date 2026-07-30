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

## Milestone 1 — Indexer on Linux

**Outcome:** Point at a folder; SQLite fills with `file_id`, hash, paths, basic mime/size.

- [ ] Data dir + SQLite bootstrap + `schema_version`
- [ ] Content-addressed blob store **or** “hash in place” mode for first iteration  
      Recommendation: start with **hash-in-place** (file stays in library root; DB stores hash+path), then optionally copy/dedup into `blobs/` for unmanaged sources.
- [ ] Walk `library_roots`, compute hash, upsert `files` / `file_paths`
- [ ] Soft-detect gone paths (`gone_at`)

**Exit check:** CLI or logs show N files indexed; re-run is idempotent.

## Milestone 2 — Metadata API

**Outcome:** Tag and fetch files without Flutter.

- [ ] CRUD-ish file metadata endpoints
- [ ] Tags + file_tags
- [ ] Catalog delta endpoint (even if crude cursor)
- [ ] Manual curl/httpie script in docs or `scripts/`

**Exit check:** Tag a file via API; delta returns it.

## Milestone 3 — Flutter catalog (list-only)

**Outcome:** Phone shows names/types/sizes/tags from API; opening full file is not required.

- [ ] API client + device registration
- [ ] Local SQLite mirror of catalog subset
- [ ] Browse UI + pull-to-refresh / delta sync
- [ ] Explicit empty/error/degraded states

**Exit check:** Phone lists PC files while online; survives app restart with local catalog.

## Milestone 4 — Pin + materialize

**Outcome:** User pins a file; bytes land on phone; unpin can delete local bytes but keep listing.

- [ ] Availability API + local mode storage
- [ ] Blob GET + local file store
- [ ] Pin UI affordance
- [ ] Disk budget / basic error if missing blob on PC

**Exit check:** Airplane mode: pinned file opens; listed-only file does not.

## Milestone 5 — Phone → PC ingest

**Outcome:** Camera (or share intent) uploads to PC with provenance.

- [ ] Blob PUT + file create with `source_kind`
- [ ] Background-friendly upload queue
- [ ] Confirm Linux retention

**Exit check:** Photo taken on phone appears in PC catalog and blob store.

## Milestone 6 — Ghost / restore UX

**Outcome:** WhatsApp-style story works end-to-end.

- [ ] Surface provenance in UI (“from WhatsApp · on PC only”)
- [ ] “Bring to phone” = pin + download
- [ ] Tombstone handling when PC deletes for real

**Exit check:** Delete local copy, still see listing, restore from PC.

## Milestone 7 — Thumbnails + search quality

- [ ] Server-side thumbs for images
- [ ] Listed-mode thumb sync (small payloads)
- [ ] Basic search (name, tags; FTS later)

## Later / maybe

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
