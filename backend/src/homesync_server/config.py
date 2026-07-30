"""Runtime configuration for the Homesync daemon and indexer."""

from __future__ import annotations

import os
from pathlib import Path

DEFAULT_HASH_ALGO = "blake3"


def data_root() -> Path:
    """Canonical data directory (`$HOMESYNC_DATA` or XDG-ish default)."""
    override = os.environ.get("HOMESYNC_DATA")
    if override:
        return Path(override).expanduser().resolve()
    return (Path.home() / ".local" / "share" / "homesync").resolve()


def catalog_db_path(root: Path | None = None) -> Path:
    return (root or data_root()) / "catalog.sqlite"


def ensure_data_dirs(root: Path | None = None) -> Path:
    """Create data root layout; return the resolved root."""
    base = root or data_root()
    base.mkdir(parents=True, exist_ok=True)
    (base / "blobs").mkdir(exist_ok=True)
    (base / "thumbs").mkdir(exist_ok=True)
    (base / "quarantine").mkdir(exist_ok=True)
    return base
