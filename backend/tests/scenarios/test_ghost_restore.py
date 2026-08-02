"""Milestone 6 exit check: WhatsApp-style ghost listing + restore from PC.

Phone deletes local bytes (unpin) → still listed with provenance → pin
(bring-to-phone) fetches blob again. Soft-delete on PC surfaces a tombstone.
"""

from __future__ import annotations

from pathlib import Path
from uuid import uuid4

from fastapi.testclient import TestClient

from homesync_server.config import DEFAULT_HASH_ALGO
from homesync_server.storage import blob_path, hash_bytes


def test_ghost_restore_unpin_then_bring_to_phone(
    client: TestClient,
    data_root: Path,
) -> None:
    payload = b"whatsapp media that lived on phone then only on PC\n"
    digest = hash_bytes(payload)
    phone_id = str(uuid4())

    hello = client.post(
        "/v1/devices",
        json={"device_id": phone_id, "name": "pixel-ghost", "kind": "android"},
    )
    assert hello.status_code == 200

    # Ingest with WhatsApp provenance (backup/export → Linux catalog + blob).
    put = client.put(f"/v1/blobs/{DEFAULT_HASH_ALGO}/{digest}", content=payload)
    assert put.status_code == 201

    created = client.post(
        "/v1/files",
        json={
            "content_hash": digest,
            "hash_algo": DEFAULT_HASH_ALGO,
            "size_bytes": len(payload),
            "mime_type": "image/jpeg",
            "title": "IMG-20260803-WA0001.jpg",
            "source_kind": "whatsapp",
            "source_device_id": phone_id,
        },
    )
    assert created.status_code == 200
    file_id = created.json()["file_id"]

    delta0 = client.get("/v1/catalog/delta")
    assert delta0.status_code == 200
    d0 = delta0.json()
    assert any(f["file_id"] == file_id and f["deleted_at"] is None for f in d0["files"])
    path = next(p for p in d0["paths"] if p["file_id"] == file_id)
    assert path["source_kind"] == "whatsapp"
    assert path["source_device_id"] == phone_id
    assert "ingest/whatsapp" in path["relative_path"]
    cursor = d0["next_cursor"]

    # Bring to phone = pin availability + blob GET (materialize).
    pinned = client.put(
        f"/v1/files/{file_id}/availability/{phone_id}",
        json={"mode": "pinned"},
    )
    assert pinned.status_code == 200
    assert pinned.json()["mode"] == "pinned"

    blob = client.get(f"/v1/blobs/{DEFAULT_HASH_ALGO}/{digest}")
    assert blob.status_code == 200
    assert blob.content == payload

    # Delete local copy (unpin → listed). Catalog + PC blob remain.
    unpinned = client.put(
        f"/v1/files/{file_id}/availability/{phone_id}",
        json={"mode": "listed"},
    )
    assert unpinned.status_code == 200
    assert unpinned.json()["mode"] == "listed"

    still = client.get(f"/v1/files/{file_id}")
    assert still.status_code == 200
    assert still.json()["deleted_at"] is None
    assert still.json()["content_hash"] == digest

    ghost_blob = client.get(f"/v1/blobs/{DEFAULT_HASH_ALGO}/{digest}")
    assert ghost_blob.status_code == 200
    assert ghost_blob.content == payload
    assert blob_path(data_root, DEFAULT_HASH_ALGO, digest).is_file()

    # Restore again from PC (bring to phone).
    restored = client.put(
        f"/v1/files/{file_id}/availability/{phone_id}",
        json={"mode": "pinned"},
    )
    assert restored.status_code == 200
    assert restored.json()["mode"] == "pinned"
    assert client.get(f"/v1/blobs/{DEFAULT_HASH_ALGO}/{digest}").content == payload

    # Soft-delete on PC → tombstone on next delta (phone must drop active listing).
    deleted = client.delete(f"/v1/files/{file_id}")
    assert deleted.status_code == 200
    assert deleted.json()["deleted_at"] is not None

    delta_tomb = client.get("/v1/catalog/delta", params={"since": cursor})
    assert delta_tomb.status_code == 200
    tombs = [
        f
        for f in delta_tomb.json()["files"]
        if f["file_id"] == file_id and f["deleted_at"] is not None
    ]
    assert len(tombs) == 1
    # Provenance paths still accompany the tombstoned file page.
    assert any(
        p["file_id"] == file_id and p["source_kind"] == "whatsapp"
        for p in delta_tomb.json()["paths"]
    )

    listed = client.get("/v1/files")
    assert listed.status_code == 200
    assert all(f["file_id"] != file_id for f in listed.json())
