# Data model

This document is the **intended** schema for Homesync. The code may not implement every table yet—when implementing, extend this doc in the same PR/change set if you diverge.

## Design principles

1. **`file_id` (UUID)** is the stable logical identity.
2. **`content_hash`** (BLAKE3 preferred; SHA-256 acceptable) identifies bytes.
3. Paths are **attributes**, not primary keys.
4. Availability is **per device**.
5. Deletes are **soft** (tombstones) until garbage collection.

```mermaid
erDiagram
  devices ||--o{ availability : has
  files ||--o{ availability : has
  files ||--o{ file_tags : has
  tags ||--o{ file_tags : has
  files ||--o{ file_paths : remembered
  files ||--o{ versions : may_have
  library_roots ||--o{ file_paths : contains

  files {
    uuid file_id PK
    text content_hash
    text mime_type
    int size_bytes
    text title
    text notes
    datetime created_at
    datetime updated_at
    datetime deleted_at
  }

  devices {
    uuid device_id PK
    text name
    text kind
    datetime last_seen_at
  }

  availability {
    uuid file_id FK
    uuid device_id FK
    text mode
    datetime updated_at
  }

  tags {
    uuid tag_id PK
    text name
    text color
  }

  file_tags {
    uuid file_id FK
    uuid tag_id FK
  }
```

## Tables (v1 target)

### `devices`

| Column | Type | Notes |
|---|---|---|
| `device_id` | UUID PK | |
| `name` | TEXT | e.g. `pixel`, `nixos-box` |
| `kind` | TEXT | `linux` \| `android` \| … |
| `created_at` | TEXT/DATETIME | ISO-8601 |
| `last_seen_at` | TEXT/DATETIME | |

The Linux host should register itself as a device too—availability on Linux is usually “has blob” implied by blob store presence, but an explicit row helps multi-disk later.

### `library_roots`

| Column | Type | Notes |
|---|---|---|
| `root_id` | UUID PK | |
| `device_id` | UUID FK | Usually the Linux device |
| `abs_path` | TEXT | Absolute path on that device |
| `label` | TEXT | `Pictures`, `WhatsApp`, … |
| `enabled` | INT/BOOL | |

### `files`

Logical file row (current head metadata).

| Column | Type | Notes |
|---|---|---|
| `file_id` | UUID PK | |
| `content_hash` | TEXT NOT NULL | Hex digest |
| `hash_algo` | TEXT | `blake3` / `sha256` |
| `mime_type` | TEXT | |
| `size_bytes` | INTEGER | |
| `title` | TEXT | Display name; may differ from path basename |
| `notes` | TEXT | Freeform |
| `taken_at` | DATETIME | From EXIF if known |
| `created_at` | DATETIME | Row creation |
| `updated_at` | DATETIME | Catalog LWW |
| `deleted_at` | DATETIME NULL | Soft delete |

Optional JSON column `exif_json` is acceptable early; normalize later if needed.

### `file_paths` (provenance + human path history)

| Column | Type | Notes |
|---|---|---|
| `id` | INTEGER/UUID PK | |
| `file_id` | UUID FK | |
| `root_id` | UUID NULL FK | Null if standalone ingest |
| `relative_path` | TEXT | Path under root |
| `source_kind` | TEXT | `camera` \| `whatsapp` \| `download` \| `manual` \| `unknown` |
| `source_device_id` | UUID NULL | Device that introduced this path |
| `is_current` | BOOL | Current known path on Linux indexer |
| `seen_at` | DATETIME | |
| `gone_at` | DATETIME NULL | Path no longer found on indexer run |

**WhatsApp example:** phone deletes local media → phone availability becomes listed/absent → Linux `file_paths` still points at PC copy → user can pin and fetch by `content_hash`.

### `versions` (optional but recommended soon)

When bytes change but you want history:

| Column | Type | Notes |
|---|---|---|
| `version_id` | UUID PK | |
| `file_id` | UUID FK | |
| `content_hash` | TEXT | |
| `size_bytes` | INTEGER | |
| `created_at` | DATETIME | |
| `note` | TEXT | |

v1 may keep only head on `files` and append versions when hash changes for same `file_id` (policy: same logical photo edited → new version; unrelated file → new `file_id`).

### `tags` / `file_tags`

Simple many-to-many. Tag names unique per library (casefold).

### `availability`

| Column | Type | Notes |
|---|---|---|
| `file_id` | UUID FK | |
| `device_id` | UUID FK | |
| `mode` | TEXT | `listed` \| `cached` \| `pinned` |
| `updated_at` | DATETIME | LWW field |
| PRIMARY KEY | `(file_id, device_id)` | |

Semantics:

- **`listed`**: device may show metadata; should not expect full bytes.
- **`cached`**: bytes may exist locally; daemon/app may evict.
- **`pinned`**: bytes must be kept locally; Linux should also retain blob.

Absence of a row on phone can mean “unknown / not yet synced policy”; define API so phone always materializes a mode after first catalog pull (default `listed` for remote-only files).

### `replicas` (optional explicit “has bytes here”)

If you need stronger tracking than mode:

| Column | Type | Notes |
|---|---|---|
| `file_id` | UUID | |
| `device_id` | UUID | |
| `content_hash` | TEXT | What hash is present |
| `state` | TEXT | `present` \| `missing` \| `partial` |
| `last_verified_at` | DATETIME | |

`pinned` + `missing` = degraded pin (UI should offer re-fetch).

## Identity rules

```mermaid
flowchart TD
  Ingest[New bytes arrive] --> Hash[Compute content_hash]
  Hash --> Exists{hash already in files?}
  Exists -->|yes| Dedup[Reuse file_id or link path]
  Exists -->|no| NewID[Create file_id + blob write]
  Dedup --> Path[Upsert file_paths / provenance]
  NewID --> Path
```

Dedup policy recommendation:

- Same hash from a new path → **same `file_id`**, add `file_paths` row (dedup storage).
- User insists on separate logical items with identical bytes (rare) → allow force-new `file_id` later; not needed in v1.

## Metadata vs filesystem sidecars

Prefer **catalog tables** for tags/notes. Optional export of sidecars (XMP) can be a later feature; don’t require sidecars for correctness.

## Migrations

When schema lands in code:

- Maintain `schema_version` table.
- Use Alembic **or** ordered SQL migration files applied by the daemon at startup.
- Never rely on “delete sqlite and reindex” as the only story once real user tags exist.

## Indexing suggestions

- Unique index on `files(content_hash)` (if 1:1 hash↔file_id policy).
- Index `file_tags(tag_id)`.
- Index `availability(device_id, mode)`.
- Index `files(deleted_at)`, `files(updated_at)` for delta sync.
