"""Content hashing and (future) blob path helpers."""

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


def blob_path(data_root: Path, algo: str, hex_hash: str) -> Path:
    """Content-addressed path: ``blobs/<algo>/<hh>/<hh>/<fullhash>``."""
    if len(hex_hash) < 4:
        raise ValueError("content hash too short for fan-out")
    return data_root / "blobs" / algo / hex_hash[0:2] / hex_hash[2:4] / hex_hash
