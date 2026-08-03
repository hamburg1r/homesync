"""Pydantic models for catalog / metadata API."""

from __future__ import annotations

from typing import Any

from pydantic import BaseModel, Field


class FilePathOut(BaseModel):
    id: str
    file_id: str
    root_id: str | None
    relative_path: str
    source_kind: str
    source_device_id: str | None
    is_current: bool
    seen_at: str
    gone_at: str | None


class TagOut(BaseModel):
    tag_id: str
    name: str
    color: str | None = None


class FileTagOut(BaseModel):
    file_id: str
    tag_id: str


class FileOut(BaseModel):
    file_id: str
    content_hash: str
    hash_algo: str
    mime_type: str | None
    size_bytes: int
    title: str | None
    notes: str | None
    taken_at: str | None
    created_at: str
    updated_at: str
    deleted_at: str | None
    tags: list[str] = Field(default_factory=list)
    # Client hint: GET /v1/thumbs/{file_id} may return a small JPEG (listed mode).
    has_thumb: bool = False


class FilePatchIn(BaseModel):
    title: str | None = None
    notes: str | None = None
    # Updates current file_paths.source_kind (provenance) when set.
    source_kind: str | None = None
    updated_at: str | None = None
    base_updated_at: str | None = None


class FileCreateIn(BaseModel):
    """Phone / client ingest after ``PUT /v1/blobs/{algo}/{hash}``."""

    content_hash: str = Field(..., min_length=4)
    hash_algo: str = Field(default="blake3", min_length=1)
    size_bytes: int = Field(..., ge=0)
    mime_type: str | None = None
    title: str | None = None
    taken_at: str | None = None
    source_kind: str = Field(default="camera", min_length=1)
    source_device_id: str | None = None
    relative_path: str | None = None


class FileTagsPutIn(BaseModel):
    tags: list[str]


class FileContentIn(BaseModel):
    """Replace file head after new bytes are in the managed blob store."""

    content_hash: str = Field(..., min_length=4)
    hash_algo: str = Field(default="blake3", min_length=1)
    size_bytes: int = Field(..., ge=0)
    note: str | None = None


class FileVersionOut(BaseModel):
    version_id: str
    file_id: str
    content_hash: str
    size_bytes: int
    created_at: str
    note: str | None = None
    is_head: bool = False


class FileVersionsOut(BaseModel):
    file_id: str
    head: FileVersionOut
    versions: list[FileVersionOut] = Field(default_factory=list)


class KdbxSecretIn(BaseModel):
    password: str = Field(..., min_length=1)


class KdbxConflictCandidateOut(BaseModel):
    content_hash: str
    size_bytes: int
    source_device_id: str | None = None
    role: str
    created_at: str


class KdbxConflictOut(BaseModel):
    conflict_id: str
    file_id: str
    state: str
    created_at: str
    updated_at: str
    diff_summary: dict[str, Any] | None = None
    resolved_content_hash: str | None = None
    candidates: list[KdbxConflictCandidateOut] = Field(default_factory=list)


class KdbxContentResult(BaseModel):
    """Returned with HTTP 202 when a kdbx content update opens/updates an outbox."""

    status: str = "conflict"
    conflict: KdbxConflictOut
    file: FileOut | None = None


class KdbxEntryChoiceIn(BaseModel):
    entry_uuid: str = Field(..., min_length=1)
    keep: str = Field(..., min_length=1)  # base | incoming | discard


class KdbxResolveIn(BaseModel):
    """Resolve a KeePass conflict.

    Modes:
    - ``upload`` (default): promote an already-uploaded blob (legacy).
    - ``candidate``: promote an existing conflict candidate hash (no new upload).
    - ``entries``: server merges base+incoming using per-entry choices.
    """

    mode: str = Field(default="upload", min_length=1)
    content_hash: str | None = Field(default=None, min_length=4)
    hash_algo: str = Field(default="blake3", min_length=1)
    size_bytes: int | None = Field(default=None, ge=0)
    note: str | None = None
    base_hash: str | None = Field(default=None, min_length=4)
    incoming_hash: str | None = Field(default=None, min_length=4)
    choices: list[KdbxEntryChoiceIn] = Field(default_factory=list)


class AvailabilityOut(BaseModel):
    file_id: str
    device_id: str
    mode: str
    updated_at: str


class AvailabilityPutIn(BaseModel):
    mode: str = Field(..., min_length=1)
    updated_at: str | None = None
    base_updated_at: str | None = None


class GcPurgeOut(BaseModel):
    file_id: str
    purged_at: str


class GcRunIn(BaseModel):
    dry_run: bool = False
    purge_tombstones: bool = True
    purge_blobs: bool = True
    purge_uploads: bool = True
    min_age_seconds: int = Field(default=0, ge=0)
    file_ids: list[str] | None = None


class GcRunOut(BaseModel):
    dry_run: bool
    purged_file_ids: list[str] = Field(default_factory=list)
    skipped_open_conflict_ids: list[str] = Field(default_factory=list)
    deleted_blobs: list[str] = Field(default_factory=list)
    deleted_thumbs: list[str] = Field(default_factory=list)
    deleted_uploads: int = 0
    bytes_reclaimed: int = 0


class CatalogDeltaOut(BaseModel):
    next_cursor: str
    files: list[FileOut]
    tags: list[TagOut]
    file_tags: list[FileTagOut]
    paths: list[FilePathOut]
    availability: list[AvailabilityOut] = Field(default_factory=list)
    purged: list[GcPurgeOut] = Field(default_factory=list)
    next_purge_cursor: str = ""


class DeviceIn(BaseModel):
    device_id: str = Field(..., min_length=1, max_length=36)
    name: str = Field(..., min_length=1)
    kind: str = Field(..., min_length=1)


class DeviceOut(BaseModel):
    device_id: str
    name: str
    kind: str
    created_at: str
    last_seen_at: str | None
