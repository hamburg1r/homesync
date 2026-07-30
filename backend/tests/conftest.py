"""Shared fixtures for Homesync backend scenario E2E tests.

Tests use an isolated temp data root (never the real ~/.local/share/homesync).
When the daemon grows to read HOMESYNC_DATA, scenarios already override it here.
"""

from __future__ import annotations

from collections.abc import Iterator
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from homesync_server.main import app


@pytest.fixture
def data_root(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """Isolated $HOMESYNC_DATA with catalog/blobs/thumbs layout."""
    root = tmp_path / "homesync_data"
    (root / "blobs").mkdir(parents=True)
    (root / "thumbs").mkdir(parents=True)
    monkeypatch.setenv("HOMESYNC_DATA", str(root))
    return root


@pytest.fixture
def library_root(tmp_path: Path) -> Path:
    """Small fixture tree for indexer scenarios (known bytes)."""
    root = tmp_path / "library"
    root.mkdir()
    (root / "hello.txt").write_bytes(b"hello homesync\n")
    (root / "subdir").mkdir()
    (root / "subdir" / "note.md").write_bytes(b"# note\n")
    return root


@pytest.fixture
def client(data_root: Path) -> Iterator[TestClient]:
    """HTTP client against the FastAPI app (no real network bind)."""
    # data_root is requested so HOMESYNC_DATA is set before requests.
    _ = data_root
    with TestClient(app) as test_client:
        yield test_client
