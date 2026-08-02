"""Blob resolve / serve / ingest helpers (managed store + hash-in-place)."""

from __future__ import annotations

from pathlib import Path

from sqlalchemy import select
from sqlalchemy.orm import Session, selectinload

from homesync_server.models import File, FilePath, LibraryRoot
from homesync_server.storage import blob_path, hash_bytes, hash_file, write_blob_atomic


class BlobNotFoundError(Exception):
    """No bytes available for (algo, hash) — catalog may still list the file."""


class BlobIntegrityError(Exception):
    """On-disk bytes do not match the requested hash."""


class BlobHashMismatchError(Exception):
    """Uploaded body digest does not match the URL hash."""


class BlobCollisionError(Exception):
    """Managed path exists but bytes/size differ — refuse overwrite."""


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


def put_blob_bytes(
    data_root: Path,
    algo: str,
    hex_hash: str,
    body: bytes,
) -> tuple[Path, bool]:
    """Store content-addressed bytes under the managed blob layout.

    Returns ``(path, created)`` where ``created`` is False on identical
    dedup. Raises ``BlobHashMismatchError`` when the body digest differs,
    ``BlobCollisionError`` when an existing object has different bytes.
    """
    algo_norm = algo.strip().lower()
    digest = hex_hash.strip().lower()
    if len(digest) < 4:
        raise ValueError(f"hash too short: {digest!r}")

    actual = hash_bytes(body, algo=algo_norm)
    if actual != digest:
        raise BlobHashMismatchError(
            f"hash mismatch: expected {digest}, got {actual}"
        )

    dest = blob_path(data_root, algo_norm, digest)
    if dest.is_file():
        existing = dest.read_bytes()
        if existing == body:
            return dest, False
        raise BlobCollisionError(
            f"blob collision for {algo_norm}/{digest}: "
            f"existing size={len(existing)} new size={len(body)}"
        )

    write_blob_atomic(dest, body)
    return dest, True


def managed_blob_exists(data_root: Path, algo: str, hex_hash: str) -> bool:
    """True when the managed CAS object is present (not hash-in-place)."""
    digest = hex_hash.strip().lower()
    algo_norm = algo.strip().lower()
    if len(digest) < 4:
        return False
    return blob_path(data_root, algo_norm, digest).is_file()