"""Content hashing and content-addressed blob path helpers."""

from __future__ import annotations

from pathlib import Path

import blake3

from homesync_server.config import DEFAULT_HASH_ALGO

_CHUNK = 1024 * 1024


def hash_file(path: Path, algo: str = DEFAULT_HASH_ALGO) -> str:
    """Stream-hash a file; return lowercase hex digest."""
    if algo != "blake3":
        raise ValueError(f"Unsupported hash algo for v1 indexer: {algo}")
    hasher = blake3.blake3()
    with path.open("rb") as fh:
        while True:
            chunk = fh.read(_CHUNK)
            if not chunk:
                break
            hasher.update(chunk)
    return hasher.hexdigest()


def hash_bytes(data: bytes, algo: str = DEFAULT_HASH_ALGO) -> str:
    """Hash an in-memory payload; return lowercase hex digest."""
    if algo != "blake3":
        raise ValueError(f"Unsupported hash algo for v1: {algo}")
    return blake3.blake3(data).hexdigest()


def blob_path(data_root: Path, algo: str, hex_hash: str) -> Path:
    """Content-addressed path: ``blobs/<algo>/<hh>/<hh>/<fullhash>``."""
    if len(hex_hash) < 4:
        raise ValueError("content hash too short for fan-out")
    return data_root / "blobs" / algo / hex_hash[0:2] / hex_hash[2:4] / hex_hash


def thumb_path(data_root: Path, hex_hash: str) -> Path:
    """Derived JPEG thumb path: ``thumbs/<hh>/<hh>/<fullhash>.jpg``."""
    digest = hex_hash.strip().lower()
    if len(digest) < 4:
        raise ValueError("content hash too short for fan-out")
    return data_root / "thumbs" / digest[0:2] / digest[2:4] / f"{digest}.jpg"


def write_blob_atomic(dest: Path, data: bytes) -> None:
    """Write bytes via ``.tmp`` + ``rename`` into ``dest`` (parent dirs created)."""
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_name(dest.name + ".tmp")
    try:
        tmp.write_bytes(data)
        tmp.replace(dest)
    finally:
        if tmp.exists():
            tmp.unlink(missing_ok=True)


def write_blob_stream_atomic(
    dest: Path,
    chunks: object,
    *,
    algo: str = DEFAULT_HASH_ALGO,
    expected_size: int | None = None,
) -> tuple[int, str]:
    """Stream ``chunks`` of bytes to ``dest.tmp``, hash, return ``(size, hex)``.

    Does **not** promote to ``dest`` — caller verifies digest then renames.
    Raises ``ValueError`` when Content-Length is exceeded or undershot.
    """
    if algo != "blake3":
        raise ValueError(f"Unsupported hash algo for v1: {algo}")
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_name(dest.name + ".tmp")
    hasher = blake3.blake3()
    size = 0
    try:
        with tmp.open("wb") as fh:
            for chunk in chunks:  # type: ignore[attr-defined]
                if not chunk:
                    continue
                data = bytes(chunk)
                hasher.update(data)
                fh.write(data)
                size += len(data)
                if expected_size is not None and size > expected_size:
                    raise ValueError(
                        f"body larger than Content-Length ({expected_size})"
                    )
        if expected_size is not None and size != expected_size:
            raise ValueError(
                f"size mismatch: Content-Length={expected_size}, got {size}"
            )
        return size, hasher.hexdigest()
    except Exception:
        tmp.unlink(missing_ok=True)
        raise
