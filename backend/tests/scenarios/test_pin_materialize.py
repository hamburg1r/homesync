"""Milestone 4 exit check: availability pin + blob GET (hash-in-place + managed)."""

from __future__ import annotations

from pathlib import Path
from uuid import uuid4

from fastapi.testclient import TestClient
from sqlalchemy import select

from homesync_server.config import DEFAULT_HASH_ALGO
from homesync_server.db import bootstrap, session_scope
from homesync_server.db.migrate import current_version
from homesync_server.indexer import ensure_library_root, index_all_roots
from homesync_server.models import File, SchemaVersion
from homesync_server.storage import blob_path, hash_file


def test_schema_includes_availability(data_root: Path) -> None:
    _, engine = bootstrap(data_root)
    with engine.connect() as conn:
        assert current_version(conn) >= 3
    with session_scope(engine) as session:
        versions = session.scalars(select(SchemaVersion)).all()
        assert any(v.version == 3 for v in versions)


def test_pin_availability_and_blob_get(
    client: TestClient,
    data_root: Path,
    library_root: Path,
) -> None:
    _, engine = bootstrap(data_root)
    with session_scope(engine) as session:
        ensure_library_root(session, library_root, label="fixture")
        stats = index_all_roots(session)
        file_row = session.scalars(
            select(File).where(File.title == "hello.txt")
        ).one()
        file_id = file_row.file_id
        content_hash = file_row.content_hash
        hash_algo = file_row.hash_algo
        size_bytes = file_row.size_bytes

    assert stats.seen == 2
    assert hash_algo == DEFAULT_HASH_ALGO

    device_id = str(uuid4())
    hello = client.post(
        "/v1/devices",
        json={"device_id": device_id, "name": "pixel-pin", "kind": "android"},
    )
    assert hello.status_code == 200

    # Baseline delta: no availability yet.
    delta0 = client.get("/v1/catalog/delta")
    assert delta0.status_code == 200
    assert delta0.json()["availability"] == []
    cursor = delta0.json()["next_cursor"]

    # Pin = availability update (bytes are a separate GET).
    pinned = client.put(
        f"/v1/files/{file_id}/availability/{device_id}",
        json={"mode": "pinned"},
    )
    assert pinned.status_code == 200
    pin_body = pinned.json()
    assert pin_body["file_id"] == file_id
    assert pin_body["device_id"] == device_id
    assert pin_body["mode"] == "pinned"
    assert pin_body["updated_at"]

    got = client.get(f"/v1/files/{file_id}/availability/{device_id}")
    assert got.status_code == 200
    assert got.json()["mode"] == "pinned"

    # Delta since prior cursor includes the file + availability row.
    delta1 = client.get("/v1/catalog/delta", params={"since": cursor})
    assert delta1.status_code == 200
    body1 = delta1.json()
    assert any(f["file_id"] == file_id for f in body1["files"])
    assert len(body1["availability"]) == 1
    assert body1["availability"][0]["mode"] == "pinned"
    assert body1["availability"][0]["device_id"] == device_id

    # Blob GET resolves hash-in-place library bytes.
    blob = client.get(f"/v1/blobs/{hash_algo}/{content_hash}")
    assert blob.status_code == 200
    assert blob.content == b"hello homesync\n"
    assert blob.headers.get("content-length") == str(size_bytes)
    assert blob.headers.get("x-content-hash") == content_hash
    assert blob.headers.get("x-hash-algo") == hash_algo

    # Unknown hash → 404 (catalog may still list; do not invent bytes).
    missing = client.get(f"/v1/blobs/{hash_algo}/{'ab' * 32}")
    assert missing.status_code == 404

    # Bad mode → 400.
    bad = client.put(
        f"/v1/files/{file_id}/availability/{device_id}",
        json={"mode": "mirrored"},
    )
    assert bad.status_code == 400

    # Unpin keeps listing (availability → listed); blob still readable on PC.
    unpinned = client.put(
        f"/v1/files/{file_id}/availability/{device_id}",
        json={"mode": "listed"},
    )
    assert unpinned.status_code == 200
    assert unpinned.json()["mode"] == "listed"

    # Managed blob store path also works when bytes live under blobs/.
    managed_bytes = b"managed blob payload\n"
    managed_hash = hash_file(
        _write_temp(library_root, "managed.bin", managed_bytes)
    )
    dest = blob_path(data_root, DEFAULT_HASH_ALGO, managed_hash)
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_bytes(managed_bytes)

    # Register a catalog file pointing at the managed hash (no library path).
    with session_scope(engine) as session:
        from homesync_server.util import new_uuid, utc_now_iso

        now = utc_now_iso()
        session.add(
            File(
                file_id=new_uuid(),
                content_hash=managed_hash,
                hash_algo=DEFAULT_HASH_ALGO,
                mime_type="application/octet-stream",
                size_bytes=len(managed_bytes),
                title="managed.bin",
                created_at=now,
                updated_at=now,
            )
        )

    managed_get = client.get(f"/v1/blobs/{DEFAULT_HASH_ALGO}/{managed_hash}")
    assert managed_get.status_code == 200
    assert managed_get.content == managed_bytes


def _write_temp(root: Path, name: str, data: bytes) -> Path:
    path = root / name
    path.write_bytes(data)
    return path
