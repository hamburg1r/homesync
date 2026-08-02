"""Catalog metadata services: files, tags, delta cursor."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from sqlalchemy import and_, delete, func, or_, select
from sqlalchemy.orm import Session, selectinload

from homesync_server.db import ensure_local_device
from homesync_server.models import File, FilePath, FileTag, Tag
from homesync_server.schemas.catalog import (
    CatalogDeltaOut,
    FileOut,
    FilePathOut,
    FileTagOut,
    TagOut,
)
from homesync_server.services import blobs as blob_svc
from homesync_server.util import new_uuid, next_updated_at, utc_now_iso

_CURSOR_PREFIX = "v1:"
_ALLOWED_SOURCE_KINDS = frozenset(
    {"camera", "whatsapp", "download", "manual", "misc", "unknown"}
)


class CatalogConflictError(Exception):
    """LWW mid-air collision (base_updated_at mismatch)."""

    def __init__(self, file_row: File) -> None:
        self.file_row = file_row
        super().__init__(f"catalog conflict for file_id={file_row.file_id}")


class NotFoundError(Exception):
    pass


class IngestValidationError(Exception):
    """Invalid ingest payload or missing prerequisite blob."""


@dataclass(frozen=True)
class DeltaCursor:
    updated_at: str
    file_id: str

    def encode(self) -> str:
        return f"{_CURSOR_PREFIX}{self.updated_at}|{self.file_id}"

    @classmethod
    def decode(cls, raw: str | None) -> DeltaCursor | None:
        if raw is None or raw == "" or raw == "0":
            return None
        if not raw.startswith(_CURSOR_PREFIX):
            raise ValueError(f"unsupported catalog cursor: {raw!r}")
        body = raw[len(_CURSOR_PREFIX) :]
        updated_at, file_id = body.rsplit("|", 1)
        if not updated_at or not file_id:
            raise ValueError(f"malformed catalog cursor: {raw!r}")
        return cls(updated_at=updated_at, file_id=file_id)


def file_to_out(file_row: File, tag_names: list[str] | None = None) -> FileOut:
    names = tag_names
    if names is None:
        names = sorted(ft.tag.name for ft in file_row.file_tags if ft.tag is not None)
    mime = (file_row.mime_type or "").strip().lower()
    return FileOut(
        file_id=file_row.file_id,
        content_hash=file_row.content_hash,
        hash_algo=file_row.hash_algo,
        mime_type=file_row.mime_type,
        size_bytes=file_row.size_bytes,
        title=file_row.title,
        notes=file_row.notes,
        taken_at=file_row.taken_at,
        created_at=file_row.created_at,
        updated_at=file_row.updated_at,
        deleted_at=file_row.deleted_at,
        tags=names,
        has_thumb=mime.startswith("image/"),
    )


def path_to_out(path: FilePath) -> FilePathOut:
    return FilePathOut(
        id=path.id,
        file_id=path.file_id,
        root_id=path.root_id,
        relative_path=path.relative_path,
        source_kind=path.source_kind,
        source_device_id=path.source_device_id,
        is_current=bool(path.is_current),
        seen_at=path.seen_at,
        gone_at=path.gone_at,
    )


def tag_to_out(tag: Tag) -> TagOut:
    return TagOut(tag_id=tag.tag_id, name=tag.name, color=tag.color)


def get_file(session: Session, file_id: str) -> File:
    row = session.scalars(
        select(File)
        .where(File.file_id == file_id)
        .options(selectinload(File.file_tags).selectinload(FileTag.tag))
    ).first()
    if row is None:
        raise NotFoundError(file_id)
    return row


def list_files(
    session: Session,
    *,
    include_deleted: bool = False,
    limit: int = 100,
    offset: int = 0,
    q: str | None = None,
) -> list[File]:
    """List files, optionally filtered by basic search ``q`` (title/notes/tags).

    Matching is case-insensitive substring (SQLite ``LIKE``). FTS is Later.
    """
    stmt = (
        select(File)
        .options(selectinload(File.file_tags).selectinload(FileTag.tag))
        .order_by(File.updated_at.desc(), File.file_id.desc())
        .limit(limit)
        .offset(offset)
    )
    if not include_deleted:
        stmt = stmt.where(File.deleted_at.is_(None))
    needle = (q or "").strip()
    if needle:
        pattern = f"%{needle.lower()}%"
        tag_ids = select(FileTag.file_id).join(Tag).where(
            func.lower(Tag.name).like(pattern)
        )
        stmt = stmt.where(
            or_(
                func.lower(File.title).like(pattern),
                func.lower(File.notes).like(pattern),
                File.file_id.in_(tag_ids),
            )
        )
    return list(session.scalars(stmt).unique().all())


def patch_file(
    session: Session,
    file_id: str,
    *,
    title: str | None = None,
    notes: str | None = None,
    updated_at: str | None = None,
    base_updated_at: str | None = None,
) -> File:
    row = get_file(session, file_id)
    if base_updated_at is not None and base_updated_at != row.updated_at:
        raise CatalogConflictError(row)

    dirty = False
    if title is not None and title != row.title:
        row.title = title
        dirty = True
    if notes is not None and notes != row.notes:
        row.notes = notes
        dirty = True

    if dirty or updated_at is not None:
        # LWW: reject older client clocks when they send updated_at.
        if updated_at is not None and updated_at < row.updated_at:
            raise CatalogConflictError(row)
        row.updated_at = updated_at if updated_at is not None else next_updated_at(row.updated_at)

    session.flush()
    return row


def soft_delete_file(session: Session, file_id: str) -> File:
    row = get_file(session, file_id)
    now = next_updated_at(row.updated_at)
    row.deleted_at = now
    row.updated_at = now
    session.flush()
    return row


def _safe_ingest_name(title: str | None, content_hash: str) -> str:
    raw = (title or "").strip() or content_hash[:16]
    cleaned = "".join(c if c.isalnum() or c in "._-+" else "_" for c in raw)
    return cleaned[:120] or content_hash[:16]


def create_file(
    session: Session,
    data_root: Path,
    *,
    content_hash: str,
    hash_algo: str,
    size_bytes: int,
    mime_type: str | None = None,
    title: str | None = None,
    taken_at: str | None = None,
    source_kind: str = "camera",
    source_device_id: str | None = None,
    relative_path: str | None = None,
) -> File:
    """Create (or dedup) a catalog file after a managed blob PUT.

    Requires the blob under ``blobs/<algo>/…``. Pins the Linux host to
    ``pinned`` so ingested bytes are retained. Dedup by ``content_hash``
    attaches a new provenance ``file_paths`` row when needed.
    """
    algo = hash_algo.strip().lower()
    digest = content_hash.strip().lower()
    kind = source_kind.strip().lower()
    if kind not in _ALLOWED_SOURCE_KINDS:
        raise IngestValidationError(
            f"source_kind must be one of: {', '.join(sorted(_ALLOWED_SOURCE_KINDS))}"
        )
    if size_bytes < 0:
        raise IngestValidationError("size_bytes must be >= 0")
    if not blob_svc.managed_blob_exists(data_root, algo, digest):
        raise IngestValidationError(
            "blob not present in managed store; PUT /v1/blobs first"
        )

    from homesync_server.storage import blob_path

    on_disk = blob_path(data_root, algo, digest)
    actual_size = on_disk.stat().st_size
    if actual_size != size_bytes:
        raise IngestValidationError(
            f"size_bytes mismatch: body claims {size_bytes}, on disk {actual_size}"
        )

    if source_device_id is not None:
        from homesync_server.models import Device

        device = session.scalars(
            select(Device).where(Device.device_id == source_device_id)
        ).first()
        if device is None:
            raise NotFoundError(f"device:{source_device_id}")

    now = utc_now_iso()
    existing = session.scalars(
        select(File).where(File.content_hash == digest, File.hash_algo == algo)
    ).first()

    if existing is not None:
        file_row = existing
        # Revive soft-deleted row on re-ingest of the same hash.
        if file_row.deleted_at is not None:
            file_row.deleted_at = None
        if title is not None and title != file_row.title:
            file_row.title = title
        if mime_type is not None and file_row.mime_type is None:
            file_row.mime_type = mime_type
        if taken_at is not None and file_row.taken_at is None:
            file_row.taken_at = taken_at
        file_row.updated_at = next_updated_at(file_row.updated_at)
    else:
        file_row = File(
            file_id=new_uuid(),
            content_hash=digest,
            hash_algo=algo,
            mime_type=mime_type,
            size_bytes=size_bytes,
            title=title,
            notes=None,
            taken_at=taken_at,
            created_at=now,
            updated_at=now,
            deleted_at=None,
        )
        session.add(file_row)
        session.flush()

    rel = (relative_path or "").strip()
    if not rel:
        name = _safe_ingest_name(title, digest)
        device_part = source_device_id or "unknown"
        rel = f"ingest/{kind}/{device_part}/{name}"

    path_exists = session.scalars(
        select(FilePath).where(
            FilePath.file_id == file_row.file_id,
            FilePath.root_id.is_(None),
            FilePath.relative_path == rel,
            FilePath.source_kind == kind,
            FilePath.source_device_id == source_device_id,
        )
    ).first()
    if path_exists is None:
        session.add(
            FilePath(
                id=new_uuid(),
                file_id=file_row.file_id,
                root_id=None,
                relative_path=rel,
                source_kind=kind,
                source_device_id=source_device_id,
                is_current=1,
                seen_at=now,
                gone_at=None,
            )
        )

    # Linux retention: pin the host device so GC will not drop the blob.
    from homesync_server.services import availability as avail_svc

    linux = ensure_local_device(session)
    avail_svc.set_availability(
        session, file_row.file_id, linux.device_id, mode="pinned"
    )

    session.flush()
    return get_file(session, file_row.file_id)


def list_tags(session: Session) -> list[Tag]:
    return list(session.scalars(select(Tag).order_by(Tag.name)).all())


def _normalize_tag_name(name: str) -> str:
    return name.strip()


def _get_or_create_tag(session: Session, name: str) -> Tag:
    normalized = _normalize_tag_name(name)
    if not normalized:
        raise ValueError("tag name must be non-empty")
    # Match unique index ux_tags_name_ci (COLLATE NOCASE).
    existing = session.scalars(
        select(Tag).where(func.lower(Tag.name) == normalized.lower())
    ).first()
    if existing is not None:
        return existing
    tag = Tag(tag_id=new_uuid(), name=normalized, color=None)
    session.add(tag)
    session.flush()
    return tag


def set_file_tags(session: Session, file_id: str, tag_names: list[str]) -> File:
    row = get_file(session, file_id)
    desired: list[Tag] = []
    seen_ids: set[str] = set()
    for raw in tag_names:
        tag = _get_or_create_tag(session, raw)
        if tag.tag_id not in seen_ids:
            desired.append(tag)
            seen_ids.add(tag.tag_id)

    session.execute(delete(FileTag).where(FileTag.file_id == file_id))
    for tag in desired:
        session.add(FileTag(file_id=file_id, tag_id=tag.tag_id))

    row.updated_at = next_updated_at(row.updated_at)
    session.flush()
    # Refresh relationship for response.
    session.expire(row, ["file_tags"])
    return get_file(session, file_id)


def catalog_delta(
    session: Session,
    *,
    since: str | None = None,
    limit: int = 500,
) -> CatalogDeltaOut:
    if limit < 1 or limit > 5000:
        raise ValueError("limit must be between 1 and 5000")

    cursor = DeltaCursor.decode(since)
    stmt = select(File).order_by(File.updated_at.asc(), File.file_id.asc()).limit(limit)
    if cursor is not None:
        stmt = stmt.where(
            or_(
                File.updated_at > cursor.updated_at,
                and_(
                    File.updated_at == cursor.updated_at,
                    File.file_id > cursor.file_id,
                ),
            )
        )

    files = list(
        session.scalars(
            stmt.options(selectinload(File.file_tags).selectinload(FileTag.tag))
        ).all()
    )

    if not files:
        # Caught up: echo cursor so clients can poll; empty string means "start".
        next_cursor = cursor.encode() if cursor is not None else ""
        return CatalogDeltaOut(
            next_cursor=next_cursor,
            files=[],
            tags=[],
            file_tags=[],
            paths=[],
            availability=[],
        )

    file_ids = [f.file_id for f in files]
    paths = list(
        session.scalars(select(FilePath).where(FilePath.file_id.in_(file_ids))).all()
    )

    file_tag_rows = list(
        session.scalars(select(FileTag).where(FileTag.file_id.in_(file_ids))).all()
    )
    tag_ids = {ft.tag_id for ft in file_tag_rows}
    tags = (
        list(session.scalars(select(Tag).where(Tag.tag_id.in_(tag_ids))).all())
        if tag_ids
        else []
    )

    last = files[-1]
    next_cursor = DeltaCursor(updated_at=last.updated_at, file_id=last.file_id).encode()

    # Lazy import avoids catalog ↔ availability cycle at module load.
    from homesync_server.services import availability as avail_svc

    avail_rows = avail_svc.list_availability_for_files(session, file_ids)

    return CatalogDeltaOut(
        next_cursor=next_cursor,
        files=[file_to_out(f) for f in files],
        tags=[tag_to_out(t) for t in tags],
        file_tags=[FileTagOut(file_id=ft.file_id, tag_id=ft.tag_id) for ft in file_tag_rows],
        paths=[path_to_out(p) for p in paths],
        availability=[avail_svc.availability_to_out(a) for a in avail_rows],
    )
