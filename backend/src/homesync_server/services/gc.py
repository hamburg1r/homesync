"""Garbage collection: hard-purge tombstones + unreferenced managed blobs."""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path

from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from homesync_server.models import (
    Availability,
    File,
    FilePath,
    FileTag,
    FileVersion,
    GcPurge,
    KdbxConflict,
    KdbxConflictCandidate,
)
from homesync_server.services.uploads import PARTIAL_KEEP_SECONDS, _wipe_upload
from homesync_server.util import utc_now_iso


def _stored_head_hash(content_hash: str) -> str:
    """Real hex digest from a head or ``tombstone:{file_id}:{hex}`` sentinel."""
    raw = content_hash.strip().lower()
    if raw.startswith("tombstone:"):
        return raw.rsplit(":", 1)[-1]
    return raw


@dataclass
class GcResult:
    dry_run: bool
    purged_file_ids: list[str] = field(default_factory=list)
    skipped_open_conflict_ids: list[str] = field(default_factory=list)
    deleted_blobs: list[str] = field(default_factory=list)
    deleted_thumbs: list[str] = field(default_factory=list)
    deleted_uploads: int = 0
    bytes_reclaimed: int = 0


def _parse_iso(raw: str) -> datetime:
    # Accept both ``…Z`` and offset forms from stored ISO timestamps.
    normalized = raw.replace("Z", "+00:00") if raw.endswith("Z") else raw
    return datetime.fromisoformat(normalized)


def _age_seconds(iso_ts: str, *, now: datetime | None = None) -> float:
    current = now or datetime.now(UTC)
    return (current - _parse_iso(iso_ts)).total_seconds()


def _open_conflict_file_ids(session: Session) -> set[str]:
    rows = session.scalars(
        select(KdbxConflict.file_id).where(KdbxConflict.state == "open")
    ).all()
    return set(rows)


def _hard_delete_file(session: Session, file_id: str) -> None:
    conflict_ids = list(
        session.scalars(
            select(KdbxConflict.conflict_id).where(KdbxConflict.file_id == file_id)
        ).all()
    )
    if conflict_ids:
        session.execute(
            delete(KdbxConflictCandidate).where(
                KdbxConflictCandidate.conflict_id.in_(conflict_ids)
            )
        )
        session.execute(
            delete(KdbxConflict).where(KdbxConflict.conflict_id.in_(conflict_ids))
        )
    session.execute(delete(FileTag).where(FileTag.file_id == file_id))
    session.execute(delete(FilePath).where(FilePath.file_id == file_id))
    session.execute(delete(Availability).where(Availability.file_id == file_id))
    session.execute(delete(FileVersion).where(FileVersion.file_id == file_id))
    session.execute(delete(File).where(File.file_id == file_id))


def _live_referenced_hashes(
    session: Session,
    *,
    exclude_file_ids: set[str] | None = None,
) -> set[str]:
    """Hashes still needed by catalog rows after tombstone hard-purge."""
    exclude = exclude_file_ids or set()
    refs: set[str] = set()
    for row in session.scalars(select(File)).all():
        if row.file_id in exclude:
            continue
        refs.add(_stored_head_hash(row.content_hash))
    for ver in session.scalars(select(FileVersion)).all():
        if ver.file_id in exclude:
            continue
        refs.add(ver.content_hash.strip().lower())
    # Conflict candidates: exclude when their parent file is being purged.
    if exclude:
        conflict_ids = set(
            session.scalars(
                select(KdbxConflict.conflict_id).where(
                    KdbxConflict.file_id.in_(exclude)
                )
            ).all()
        )
    else:
        conflict_ids = set()
    for cand in session.scalars(select(KdbxConflictCandidate)).all():
        if cand.conflict_id in conflict_ids:
            continue
        refs.add(cand.content_hash.strip().lower())
    return {h for h in refs if h and len(h) >= 4}


def _iter_managed_blob_files(data_root: Path) -> list[tuple[str, str, Path]]:
    """Yield ``(algo, digest, path)`` for managed CAS objects."""
    blobs_root = data_root / "blobs"
    if not blobs_root.is_dir():
        return []
    out: list[tuple[str, str, Path]] = []
    for algo_dir in blobs_root.iterdir():
        if not algo_dir.is_dir():
            continue
        algo = algo_dir.name
        for path in algo_dir.rglob("*"):
            if not path.is_file():
                continue
            if path.name.endswith(".tmp"):
                continue
            digest = path.name.strip().lower()
            if len(digest) < 4:
                continue
            out.append((algo, digest, path))
    return out


def _iter_thumb_files(data_root: Path) -> list[tuple[str, Path]]:
    thumbs_root = data_root / "thumbs"
    if not thumbs_root.is_dir():
        return []
    out: list[tuple[str, Path]] = []
    for path in thumbs_root.rglob("*.jpg"):
        if not path.is_file():
            continue
        digest = path.stem.strip().lower()
        if len(digest) < 4:
            continue
        out.append((digest, path))
    return out


def _cleanup_expired_uploads(data_root: Path, *, dry_run: bool) -> tuple[int, int]:
    """Wipe upload sessions idle longer than ``PARTIAL_KEEP_SECONDS``.

    Returns ``(deleted_count, bytes_reclaimed)``.
    """
    uploads_root = data_root / "uploads"
    if not uploads_root.is_dir():
        return 0, 0
    deleted = 0
    bytes_reclaimed = 0
    now = datetime.now(UTC)
    for meta in uploads_root.rglob("meta.json"):
        udir = meta.parent
        try:
            data = json.loads(meta.read_text(encoding="utf-8"))
            last_activity = str(data.get("last_activity") or "")
            age = _age_seconds(last_activity, now=now) if last_activity else float("inf")
        except (OSError, json.JSONDecodeError, ValueError):
            age = float("inf")
        if age <= PARTIAL_KEEP_SECONDS:
            continue
        size = 0
        for child in udir.rglob("*"):
            if child.is_file():
                try:
                    size += child.stat().st_size
                except OSError:
                    pass
        if not dry_run:
            _wipe_upload(udir)
            # Remove empty fan-out parents when possible.
            parent = udir.parent
            for _ in range(3):
                if not parent.is_dir() or parent == uploads_root:
                    break
                try:
                    parent.rmdir()
                except OSError:
                    break
                parent = parent.parent
        deleted += 1
        bytes_reclaimed += size
    return deleted, bytes_reclaimed


def run_gc(
    session: Session,
    data_root: Path,
    *,
    dry_run: bool = False,
    purge_tombstones: bool = True,
    purge_blobs: bool = True,
    purge_uploads: bool = True,
    min_age_seconds: int = 0,
    file_ids: list[str] | None = None,
) -> GcResult:
    """Hard-purge soft-deleted catalog rows and unreferenced managed objects."""
    if min_age_seconds < 0:
        raise ValueError("min_age_seconds must be >= 0")

    result = GcResult(dry_run=dry_run)
    now = datetime.now(UTC)
    open_conflicts = _open_conflict_file_ids(session)

    if purge_tombstones:
        stmt = select(File).where(File.deleted_at.is_not(None))
        if file_ids is not None:
            wanted = {fid.strip() for fid in file_ids if fid.strip()}
            if not wanted:
                tombstones: list[File] = []
            else:
                stmt = stmt.where(File.file_id.in_(wanted))
                tombstones = list(session.scalars(stmt).all())
        else:
            tombstones = list(session.scalars(stmt).all())

        purged_at = utc_now_iso()
        for row in tombstones:
            if row.file_id in open_conflicts:
                result.skipped_open_conflict_ids.append(row.file_id)
                continue
            if row.deleted_at is None:
                continue
            if _age_seconds(row.deleted_at, now=now) < min_age_seconds:
                continue
            if not dry_run:
                _hard_delete_file(session, row.file_id)
                session.merge(GcPurge(file_id=row.file_id, purged_at=purged_at))
            result.purged_file_ids.append(row.file_id)
        if not dry_run and result.purged_file_ids:
            session.flush()

    if purge_blobs:
        # Dry-run: treat would-be-purged tombstones as already gone for blob refs.
        exclude = set(result.purged_file_ids) if dry_run else None
        refs = _live_referenced_hashes(session, exclude_file_ids=exclude)
        for algo, digest, path in _iter_managed_blob_files(data_root):
            if digest in refs:
                continue
            try:
                size = path.stat().st_size
            except OSError:
                size = 0
            if not dry_run:
                path.unlink(missing_ok=True)
            result.deleted_blobs.append(f"{algo}/{digest}")
            result.bytes_reclaimed += size

        for digest, path in _iter_thumb_files(data_root):
            if digest in refs:
                continue
            try:
                size = path.stat().st_size
            except OSError:
                size = 0
            if not dry_run:
                path.unlink(missing_ok=True)
            result.deleted_thumbs.append(digest)
            result.bytes_reclaimed += size

    if purge_uploads:
        deleted, upload_bytes = _cleanup_expired_uploads(data_root, dry_run=dry_run)
        result.deleted_uploads = deleted
        result.bytes_reclaimed += upload_bytes

    return result


def list_purges_since(
    session: Session,
    *,
    purge_since: str | None = None,
    limit: int = 500,
) -> tuple[list[GcPurge], str]:
    """Return purge rows after ``purge_since`` and the next purge cursor.

    Cursor is the max ``purged_at`` in the page, or echoed ``purge_since`` / ``""``
    when there are no new rows.
    """
    if limit < 1 or limit > 5000:
        raise ValueError("limit must be between 1 and 5000")

    stmt = select(GcPurge).order_by(GcPurge.purged_at.asc(), GcPurge.file_id.asc()).limit(
        limit
    )
    since = (purge_since or "").strip()
    if since:
        stmt = stmt.where(GcPurge.purged_at > since)

    rows = list(session.scalars(stmt).all())
    if not rows:
        return [], since
    return rows, rows[-1].purged_at
