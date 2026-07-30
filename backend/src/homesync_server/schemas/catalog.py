"""Pydantic models for catalog / metadata API."""

from __future__ import annotations

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


class FilePatchIn(BaseModel):
    title: str | None = None
    notes: str | None = None
    updated_at: str | None = None
    base_updated_at: str | None = None


class FileTagsPutIn(BaseModel):
    tags: list[str]


class CatalogDeltaOut(BaseModel):
    next_cursor: str
    files: list[FileOut]
    tags: list[TagOut]
    file_tags: list[FileTagOut]
    paths: list[FilePathOut]
    availability: list[dict[str, object]] = Field(default_factory=list)
