"""Library-root indexer: hash-in-place walk, upsert, soft-gone detection."""

from __future__ import annotations

import logging
import mimetypes
from dataclasses import dataclass
from pathlib import Path

from sqlalchemy import select
from sqlalchemy.orm import Session

from homesync_server.config import DEFAULT_HASH_ALGO
from homesync_server.db import ensure_local_device
from homesync_server.models import File, FilePath, LibraryRoot
from homesync_server.storage import hash_file
from homesync_server.util import new_uuid, utc_now_iso

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class IndexStats:
    roots: int = 0
    seen: int = 0
    upserted: int = 0
    unchanged: int = 0
    gone: int = 0
    errors: int = 0


def ensure_library_root(
    session: Session,
    abs_path: Path,
    *,
    label: str | None = None,
) -> LibraryRoot:
    """Register or return an enabled library root on the local Linux device."""
    resolved = abs_path.expanduser().resolve()
    if not resolved.is_dir():
        raise NotADirectoryError(f"Library root is not a directory: {resolved}")

    existing = session.scalars(
        select(LibraryRoot).where(LibraryRoot.abs_path == str(resolved))
    ).first()
    if existing is not None:
        if label and existing.label != label:
            existing.label = label
        existing.enabled = 1
        session.flush()
        return existing

    device = ensure_local_device(session)
    root = LibraryRoot(
        root_id=new_uuid(),
        device_id=device.device_id,
        abs_path=str(resolved),
        label=label or resolved.name,
        enabled=1,
    )
    session.add(root)
    session.flush()
    return root


def index_all_roots(session: Session) -> IndexStats:
    """Walk every enabled library root and return aggregate stats."""
    roots = session.scalars(select(LibraryRoot).where(LibraryRoot.enabled == 1)).all()
    totals = IndexStats(roots=len(roots))
    for root in roots:
        part = index_root(session, root)
        totals = IndexStats(
            roots=totals.roots,
            seen=totals.seen + part.seen,
            upserted=totals.upserted + part.upserted,
            unchanged=totals.unchanged + part.unchanged,
            gone=totals.gone + part.gone,
            errors=totals.errors + part.errors,
        )
    return totals


def index_root(session: Session, root: LibraryRoot) -> IndexStats:
    """Hash-in-place index one library root; soft-mark missing paths as gone."""
    base = Path(root.abs_path)
    if not base.is_dir():
        logger.warning("library root missing on disk: %s", base)
        return _mark_all_gone(session, root)

    now = utc_now_iso()
    seen_relpaths: set[str] = set()
    upserted = 0
    unchanged = 0
    errors = 0

    for path in _iter_files(base):
        rel = path.relative_to(base).as_posix()
        seen_relpaths.add(rel)
        try:
            changed = _upsert_path(session, root, path, rel, now)
        except OSError as exc:
            logger.warning("skip %s: %s", path, exc)
            errors += 1
            continue
        if changed:
            upserted += 1
        else:
            unchanged += 1

    gone = _mark_gone(session, root, seen_relpaths, now)
    session.flush()
    stats = IndexStats(
        roots=1,
        seen=len(seen_relpaths),
        upserted=upserted,
        unchanged=unchanged,
        gone=gone,
        errors=errors,
    )
    logger.info(
        "indexed root %s (%s): seen=%d upserted=%d unchanged=%d gone=%d errors=%d",
        root.label or root.root_id,
        base,
        stats.seen,
        stats.upserted,
        stats.unchanged,
        stats.gone,
        stats.errors,
    )
    return stats


def _iter_files(base: Path):
    for path in sorted(base.rglob("*")):
        if path.is_file() and not path.is_symlink():
            yield path


def _upsert_path(
    session: Session,
    root: LibraryRoot,
    path: Path,
    rel: str,
    now: str,
) -> bool:
    """Upsert file + path rows. Returns True if catalog changed."""
    digest = hash_file(path)
    size = path.stat().st_size
    mime, _ = mimetypes.guess_type(path.name)
    title = path.name

    file_row = session.scalars(select(File).where(File.content_hash == digest)).first()
    created_file = False
    if file_row is None:
        file_row = File(
            file_id=new_uuid(),
            content_hash=digest,
            hash_algo=DEFAULT_HASH_ALGO,
            mime_type=mime,
            size_bytes=size,
            title=title,
            created_at=now,
            updated_at=now,
        )
        session.add(file_row)
        session.flush()
        created_file = True
    else:
        # Keep mime/size in sync if we learned better info; title stays user-owned later.
        dirty = False
        if file_row.size_bytes != size:
            file_row.size_bytes = size
            dirty = True
        if mime and file_row.mime_type != mime:
            file_row.mime_type = mime
            dirty = True
        if dirty:
            file_row.updated_at = now

    path_row = session.scalars(
        select(FilePath).where(
            FilePath.root_id == root.root_id,
            FilePath.relative_path == rel,
        )
    ).first()

    if path_row is None:
        session.add(
            FilePath(
                id=new_uuid(),
                file_id=file_row.file_id,
                root_id=root.root_id,
                relative_path=rel,
                source_kind="unknown",
                source_device_id=root.device_id,
                is_current=1,
                seen_at=now,
                gone_at=None,
            )
        )
        return True

    changed = False
    if path_row.file_id != file_row.file_id:
        path_row.file_id = file_row.file_id
        changed = True
    if path_row.gone_at is not None or path_row.is_current != 1:
        path_row.gone_at = None
        path_row.is_current = 1
        changed = True
    path_row.seen_at = now
    return changed or created_file


def _mark_gone(session: Session, root: LibraryRoot, seen: set[str], now: str) -> int:
    rows = session.scalars(
        select(FilePath).where(
            FilePath.root_id == root.root_id,
            FilePath.is_current == 1,
        )
    ).all()
    count = 0
    for row in rows:
        if row.relative_path not in seen:
            row.is_current = 0
            row.gone_at = now
            count += 1
    return count


def _mark_all_gone(session: Session, root: LibraryRoot) -> IndexStats:
    now = utc_now_iso()
    gone = _mark_gone(session, root, set(), now)
    session.flush()
    return IndexStats(roots=1, gone=gone)
