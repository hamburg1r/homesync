# Architecture

Homesync is a **catalog + selective materialization** system for one primary Linux host and one or more phones.

## Problem statement

You want:

1. Files **primarily stored on Linux**.
2. A phone app that can **browse / tag / request** those files.
3. Rich **metadata** (tags, notes, EXIF, provenance) that survives path changes and phone deletes.
4. Per-file phone policy:
   - **Pinned** — always available offline on phone *and* retained on Linux.
   - **Listed** — visible in the catalog on phone without full file access.
   - **Cached** (optional middle ground) — temporary local bytes.
5. Ability to **re-materialize** a file onto the phone from the PC (e.g. WhatsApp image deleted on phone, still on PC).

Classic folder sync fights (4) and (5). A catalog-first design embraces them.

## High-level components

```mermaid
flowchart TB
  subgraph host [Linux host]
    Indexer[Indexer / importer]
    API[API daemon FastAPI]
    Cat[(Canonical SQLite)]
    Store[(Content-addressed blobs)]
    Thumbs[Thumbnail worker optional]

    Indexer --> Cat
    Indexer --> Store
    API --> Cat
    API --> Store
    Thumbs --> Store
    Thumbs --> Cat
  end

  subgraph device [Android device]
    UI[Flutter UI]
    Sync[Sync engine]
    LCat[(Local SQLite)]
    LStore[(Pinned + cache dir)]

    UI --> Sync
    Sync --> LCat
    Sync --> LStore
  end

  Sync <-->|HTTPS or HTTP over VPN| API
```

### Linux daemon (`backend/`)

Responsibilities:

- Own the **canonical catalog**.
- Serve **metadata APIs** and **blob download/upload**.
- **Index** configured library roots (Photos, Documents, WhatsApp backup dirs, …).
- Record **provenance** on ingest.
- Generate thumbnails (later) so listed-mode phone UI can show previews without full files.
- Apply **pin/list/cache** policy updates from devices.

### Flutter app (`mobile/`)

Responsibilities:

- Browse catalog (search/filter/tags).
- Edit metadata when online (or queue offline edits — later).
- Set availability: pin / unpin / keep listed.
- Materialize blobs for pin/cache.
- Ingest phone-captured media up to the host with provenance.

### Out of scope for the core daemon

- Replacing Syncthing for arbitrary project folders unrelated to the catalog.
- Multi-user SaaS / public internet hosting.
- Perfect multi-master conflict magic (v1 is LWW).

## Trust and topology

```mermaid
flowchart LR
  Phone[Phone]
  TS[Tailscale / LAN]
  PC[NixOS PC]
  Phone --> TS --> PC
```

- v1: daemon listens on `127.0.0.1` or Tailscale IP with a shared token (when auth lands).
- Do not bind `0.0.0.0` to a hostile network without auth + TLS assumptions documented.

## Source of truth split

| Concern | Source of truth |
|---|---|
| File bytes | Blob store on Linux (content hash) |
| Logical identity | `file_id` in SQLite |
| Display name / original path | Catalog columns (history optional) |
| Tags / user metadata | Catalog |
| Which device has a full copy | `availability` / `replicas` tables |
| Phone offline UI | Local catalog replica (may lag) |

If catalog and disk disagree (hash missing), the API should surface a **broken/missing blob** state—not invent bytes.

## Library roots

The indexer should support **multiple roots** configured in DB or config, e.g.:

- `~/Pictures`
- `~/Documents`
- `~/WhatsApp/Media` (or a backup export path)

Each ingest stamps `root_id` + relative path for human recovery, while identity remains `file_id`/hash.

## Comparison to adjacent tools

| Tool | Overlap | Why Homesync still exists |
|---|---|---|
| Syncthing | Moves bytes | Weak selective “list only” + rich provenance UX |
| Nextcloud | Files + metadata | Heavy; different product shape |
| Immich | Photos pipeline | Photo-centric; may inspire thumbnail/EXIF code later |

Homesync’s differentiator is **explicit listed vs pinned + provenance-first restore**.

## Failure domains

```mermaid
flowchart TB
  A[Phone offline] -->|OK| B[Browse local catalog + pinned]
  A -->|Degraded| C[Cannot materialize new pins]
  D[PC offline] -->|OK| E[Phone uses what it already pinned]
  D -->|Blocked| F[No catalog updates / uploads]
  G[Blob missing on PC] --> H[Mark file degraded in catalog]
```

Design APIs and UI states for degraded/missing, not only the happy path.

## Security sketch (v1 → later)

1. **v1:** network isolation (Tailscale) + optional static bearer token.
2. **Later:** per-device pairing keys, TLS if exposed beyond VPN, capability-limited tokens (read catalog vs write tags vs delete).

Never commit real tokens. Use env / NixOS secrets.

## Implementation boundary diagram

```mermaid
flowchart LR
  subgraph backend_pkg [homesync_server]
    api[api/]
    models[models/]
    db[db/]
    storage[storage/]
    index[indexer/]
  end

  api --> models
  api --> db
  api --> storage
  index --> db
  index --> storage
```

Suggested future package layout (not all present yet): keep HTTP handlers thin; put catalog invariants in services; put hash/FS IO in `storage`.
