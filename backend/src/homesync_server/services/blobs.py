"""Blob resolve / serve helpers (managed store + hash-in-place library roots)."""

from __future__ import annotations

from pathlib import Path

from sqlalchemy import select
from sqlalchemy.orm import Session, selectinload

from homesync_server.models import File, FilePath, LibraryRoot
from homesync_server.storage import blob_path, hash_file


class BlobNotFoundError(Exception):
    """No bytes available for (algo, hash) — catalog may still list the file."""


class BlobIntegrityError(Exception):
    """On-disk bytes do not match the requested hash."""


def resolve_blob_path(
    session: Session,
    data_root: Path,
    algo: str,
    hex_hash: str,
) -> Path:
    """Return a readable path for ``(algo, hash)``.

    Prefer managed ``blobs/<algo>/…``; fall back to a current hash-in-place
    library path. Raises ``BlobNotFoundError`` when neither exists.
    """
    digest = hex_hash.strip().lower()
    algo_norm = algo.strip().lower()
    if len(digest) < 4:
        raise BlobNotFoundError(f"hash too short: {digest!r}")

    managed = blob_path(data_root, algo_norm, digest)
    if managed.is_file():
        return managed

    file_row = session.scalars(
        select(File).where(
            File.content_hash == digest,
            File.hash_algo == algo_norm,
        )
    ).first()
    if file_row is None:
        raise BlobNotFoundError(f"unknown blob {algo_norm}/{digest}")

    path_row = session.scalars(
        select(FilePath)
        .where(
            FilePath.file_id == file_row.file_id,
            FilePath.is_current == 1,
            FilePath.gone_at.is_(None),
            FilePath.root_id.is_not(None),
        )
        .options(selectinload(FilePath.root))
        .limit(1)
    ).first()
    if path_row is None or path_row.root is None:
        raise BlobNotFoundError(f"no current path for {algo_norm}/{digest}")

    root: LibraryRoot = path_row.root
    candidate = Path(root.abs_path) / path_row.relative_path
    if not candidate.is_file():
        raise BlobNotFoundError(f"missing on disk: {candidate}")
    return candidate


def open_blob_bytes(
    session: Session,
    data_root: Path,
    algo: str,
    hex_hash: str,
    *,
    verify: bool = False,
) -> tuple[Path, int]:
    """Resolve blob path and return ``(path, size_bytes)``.

    When ``verify`` is True, re-hash the file (expensive; tests / quarantine).
    """
    path = resolve_blob_path(session, data_root, algo, hex_hash)
    size = path.stat().st_size
    if verify:
        digest = hash_file(path, algo=algo.strip().lower())
        if digest != hex_hash.strip().lower():
            raise BlobIntegrityError(
                f"hash mismatch for {path}: expected {hex_hash}, got {digest}"
            )
    return path, size
