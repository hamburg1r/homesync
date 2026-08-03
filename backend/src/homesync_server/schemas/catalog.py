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


class KdbxResolveIn(BaseModel):
    content_hash: str = Field(..., min_length=4)
    hash_algo: str = Field(default="blake3", min_length=1)
    size_bytes: int = Field(..., ge=0)
    note: str | None = None


class AvailabilityOut(BaseModel):
    file_id: str
    device_id: str
    mode: str
    updated_at: str


class AvailabilityPutIn(BaseModel):
    mode: str = Field(..., min_length=1)
    updated_at: str | None = None
    base_updated_at: str | None = None


class CatalogDeltaOut(BaseModel):
    next_cursor: str
    files: list[FileOut]
    tags: list[TagOut]
    file_tags: list[FileTagOut]
    paths: list[FilePathOut]
    availability: list[AvailabilityOut] = Field(default_factory=list)


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
