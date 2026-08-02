"""Milestone 5 exit check: phone blob PUT + file create lands on Linux."""

from __future__ import annotations

from pathlib import Path
from uuid import uuid4

from fastapi.testclient import TestClient
from sqlalchemy import select

from homesync_server.config import DEFAULT_HASH_ALGO
from homesync_server.db import bootstrap, ensure_local_device, session_scope
from homesync_server.models import Availability, File, FilePath
from homesync_server.storage import blob_path, hash_bytes


def test_phone_ingest_puts_blob_and_creates_file(
    client: TestClient,
    data_root: Path,
) -> None:
    payload = b"camera photo bytes from phone\n"
    digest = hash_bytes(payload)
    assert digest == hash_bytes(payload)  # stable

    device_id = str(uuid4())
    hello = client.post(
        "/v1/devices",
        json={"device_id": device_id, "name": "pixel-ingest", "kind": "android"},
    )
    assert hello.status_code == 200

    # Missing blob → create fails.
    missing = client.post(
        "/v1/files",
        json={
            "content_hash": digest,
            "hash_algo": DEFAULT_HASH_ALGO,
            "size_bytes": len(payload),
            "mime_type": "image/jpeg",
            "title": "IMG_001.jpg",
            "source_kind": "camera",
            "source_device_id": device_id,
        },
    )
    assert missing.status_code == 400
    assert "blob not present" in missing.json()["detail"]

    # Hash mismatch → 400.
    bad = client.put(
        f"/v1/blobs/{DEFAULT_HASH_ALGO}/{digest}",
        content=b"wrong bytes",
    )
    assert bad.status_code == 400

    # PUT blob → managed CAS object.
    put = client.put(
        f"/v1/blobs/{DEFAULT_HASH_ALGO}/{digest}",
        content=payload,
    )
    assert put.status_code == 201
    assert put.headers.get("x-content-hash") == digest
    assert put.headers.get("x-blob-created") == "1"
    managed = blob_path(data_root, DEFAULT_HASH_ALGO, digest)
    assert managed.is_file()
    assert managed.read_bytes() == payload

    # Identical re-PUT is a dedup (200, not created).
    again = client.put(
        f"/v1/blobs/{DEFAULT_HASH_ALGO}/{digest}",
        content=payload,
    )
    assert again.status_code == 200
    assert again.headers.get("x-blob-created") == "0"

    created = client.post(
        "/v1/files",
        json={
            "content_hash": digest,
            "hash_algo": DEFAULT_HASH_ALGO,
            "size_bytes": len(payload),
            "mime_type": "image/jpeg",
            "title": "IMG_001.jpg",
            "source_kind": "camera",
            "source_device_id": device_id,
        },
    )
    assert created.status_code == 200
    body = created.json()
    file_id = body["file_id"]
    assert body["content_hash"] == digest
    assert body["title"] == "IMG_001.jpg"
    assert body["size_bytes"] == len(payload)
    assert body["mime_type"] == "image/jpeg"

    got = client.get(f"/v1/files/{file_id}")
    assert got.status_code == 200
    assert got.json()["file_id"] == file_id

    # Managed blob round-trip.
    blob = client.get(f"/v1/blobs/{DEFAULT_HASH_ALGO}/{digest}")
    assert blob.status_code == 200
    assert blob.content == payload

    # Provenance + Linux retention (pinned on host device).
    _, engine = bootstrap(data_root)
    with session_scope(engine) as session:
        path_row = session.scalars(
            select(FilePath).where(FilePath.file_id == file_id)
        ).one()
        assert path_row.root_id is None
        assert path_row.source_kind == "camera"
        assert path_row.source_device_id == device_id
        assert "ingest/camera" in path_row.relative_path

        linux = ensure_local_device(session)
        avail = session.scalars(
            select(Availability).where(
                Availability.file_id == file_id,
                Availability.device_id == linux.device_id,
            )
        ).one()
        assert avail.mode == "pinned"

    # Phone pins its own availability (protocol step 3).
    pinned = client.put(
        f"/v1/files/{file_id}/availability/{device_id}",
        json={"mode": "pinned"},
    )
    assert pinned.status_code == 200
    assert pinned.json()["mode"] == "pinned"

    # Delta surfaces the new file + availability.
    delta = client.get("/v1/catalog/delta")
    assert delta.status_code == 200
    dbody = delta.json()
    assert any(f["file_id"] == file_id for f in dbody["files"])
    assert any(
        p["file_id"] == file_id and p["source_kind"] == "camera"
        for p in dbody["paths"]
    )
    modes = {
        (a["device_id"], a["mode"])
        for a in dbody["availability"]
        if a["file_id"] == file_id
    }
    assert (device_id, "pinned") in modes

    # Dedup: second POST same hash returns same file_id.
    dedup = client.post(
        "/v1/files",
        json={
            "content_hash": digest,
            "hash_algo": DEFAULT_HASH_ALGO,
            "size_bytes": len(payload),
            "title": "IMG_001.jpg",
            "source_kind": "camera",
            "source_device_id": device_id,
        },
    )
    assert dedup.status_code == 200
    assert dedup.json()["file_id"] == file_id

    with session_scope(engine) as session:
        assert session.scalars(select(File)).all().__len__() == 1
