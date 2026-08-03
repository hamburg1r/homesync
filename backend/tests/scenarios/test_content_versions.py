"""Milestone 8 exit check: content replace keeps file_id and archives old head."""

from __future__ import annotations

from pathlib import Path
from uuid import uuid4

from fastapi.testclient import TestClient
from sqlalchemy import select

from homesync_server.config import DEFAULT_HASH_ALGO
from homesync_server.db import bootstrap, session_scope
from homesync_server.db.migrate import current_version
from homesync_server.models import File, FileVersion, SchemaVersion
from homesync_server.storage import blob_path, hash_bytes


def _put_blob(client: TestClient, payload: bytes) -> str:
    digest = hash_bytes(payload)
    put = client.put(
        f"/v1/blobs/{DEFAULT_HASH_ALGO}/{digest}",
        content=payload,
    )
    assert put.status_code in (200, 201), put.text
    return digest


def test_content_version_keeps_file_id_and_archives_head(
    client: TestClient,
    data_root: Path,
) -> None:
    _, engine = bootstrap(data_root)
    with engine.connect() as conn:
        assert current_version(conn) >= 4
    with session_scope(engine) as session:
        versions = session.scalars(select(SchemaVersion)).all()
        assert any(v.version == 4 for v in versions)

    device_id = str(uuid4())
    assert (
        client.post(
            "/v1/devices",
            json={"device_id": device_id, "name": "pixel-v", "kind": "android"},
        ).status_code
        == 200
    )

    v1 = b"version one bytes\n"
    v2 = b"version two bytes - edited\n"
    h1 = _put_blob(client, v1)
    h2 = _put_blob(client, v2)

    created = client.post(
        "/v1/files",
        json={
            "content_hash": h1,
            "hash_algo": DEFAULT_HASH_ALGO,
            "size_bytes": len(v1),
            "mime_type": "text/plain",
            "title": "notes.txt",
            "source_kind": "misc",
            "source_device_id": device_id,
        },
    )
    assert created.status_code == 200, created.text
    file_id = created.json()["file_id"]
    assert created.json()["content_hash"] == h1
    head_updated_at = created.json()["updated_at"]

    # Missing blob for new head → 400.
    missing = client.post(
        f"/v1/files/{file_id}/content",
        json={
            "content_hash": hash_bytes(b"never uploaded"),
            "hash_algo": DEFAULT_HASH_ALGO,
            "size_bytes": 5,
        },
    )
    assert missing.status_code == 400
    assert "blob not present" in missing.json()["detail"]

    # Replace head → same file_id, new hash.
    replaced = client.post(
        f"/v1/files/{file_id}/content",
        json={
            "content_hash": h2,
            "hash_algo": DEFAULT_HASH_ALGO,
            "size_bytes": len(v2),
            "note": "phone edit",
        },
    )
    assert replaced.status_code == 200, replaced.text
    body = replaced.json()
    assert body["file_id"] == file_id
    assert body["content_hash"] == h2
    assert body["size_bytes"] == len(v2)
    assert body["updated_at"] > head_updated_at

    # Idempotent same-head POST.
    again = client.post(
        f"/v1/files/{file_id}/content",
        json={
            "content_hash": h2,
            "hash_algo": DEFAULT_HASH_ALGO,
            "size_bytes": len(v2),
        },
    )
    assert again.status_code == 200
    assert again.json()["updated_at"] == body["updated_at"]

    hist = client.get(f"/v1/files/{file_id}/versions")
    assert hist.status_code == 200, hist.text
    hist_body = hist.json()
    assert hist_body["file_id"] == file_id
    assert hist_body["head"]["content_hash"] == h2
    assert hist_body["head"]["is_head"] is True
    assert len(hist_body["versions"]) == 1
    archived = hist_body["versions"][0]
    assert archived["content_hash"] == h1
    assert archived["size_bytes"] == len(v1)
    assert archived["note"] == "phone edit"
    assert archived["is_head"] is False

    # Delta surfaces the new head under the same file_id.
    delta = client.get("/v1/catalog/delta", params={"since": "0"})
    assert delta.status_code == 200
    files = {f["file_id"]: f for f in delta.json()["files"]}
    assert file_id in files
    assert files[file_id]["content_hash"] == h2

    # Both blobs remain readable.
    assert client.get(f"/v1/blobs/{DEFAULT_HASH_ALGO}/{h1}").content == v1
    assert client.get(f"/v1/blobs/{DEFAULT_HASH_ALGO}/{h2}").content == v2

    managed_h1 = blob_path(data_root, DEFAULT_HASH_ALGO, h1)
    managed_h2 = blob_path(data_root, DEFAULT_HASH_ALGO, h2)
    assert managed_h1.is_file() and managed_h2.is_file()

    with session_scope(engine) as session:
        file_row = session.scalars(select(File).where(File.file_id == file_id)).one()
        assert file_row.content_hash == h2
        vers = list(
            session.scalars(
                select(FileVersion).where(FileVersion.file_id == file_id)
            ).all()
        )
        assert len(vers) == 1
        assert vers[0].content_hash == h1


def test_content_version_rejects_other_files_head(
    client: TestClient,
    data_root: Path,
) -> None:
    _ = data_root
    device_id = str(uuid4())
    assert (
        client.post(
            "/v1/devices",
            json={"device_id": device_id, "name": "pixel-v2", "kind": "android"},
        ).status_code
        == 200
    )

    a = b"file A\n"
    b = b"file B\n"
    ha = _put_blob(client, a)
    hb = _put_blob(client, b)

    fa = client.post(
        "/v1/files",
        json={
            "content_hash": ha,
            "hash_algo": DEFAULT_HASH_ALGO,
            "size_bytes": len(a),
            "title": "a.txt",
            "source_kind": "misc",
            "source_device_id": device_id,
        },
    ).json()["file_id"]
    fb = client.post(
        "/v1/files",
        json={
            "content_hash": hb,
            "hash_algo": DEFAULT_HASH_ALGO,
            "size_bytes": len(b),
            "title": "b.txt",
            "source_kind": "misc",
            "source_device_id": device_id,
        },
    ).json()["file_id"]

    conflict = client.post(
        f"/v1/files/{fa}/content",
        json={
            "content_hash": hb,
            "hash_algo": DEFAULT_HASH_ALGO,
            "size_bytes": len(b),
        },
    )
    assert conflict.status_code == 409
    detail = conflict.json()["detail"]
    assert detail["file"]["file_id"] == fb

    # A unchanged; no version row created.
    assert client.get(f"/v1/files/{fa}").json()["content_hash"] == ha
    hist = client.get(f"/v1/files/{fa}/versions").json()
    assert hist["versions"] == []


def test_content_update_revives_soft_deleted_file(
    client: TestClient,
    data_root: Path,
) -> None:
    _ = data_root
    device_id = str(uuid4())
    assert (
        client.post(
            "/v1/devices",
            json={"device_id": device_id, "name": "pixel-revive", "kind": "android"},
        ).status_code
        == 200
    )
    v1 = b"alive again\n"
    h1 = _put_blob(client, v1)
    file_id = client.post(
        "/v1/files",
        json={
            "content_hash": h1,
            "hash_algo": DEFAULT_HASH_ALGO,
            "size_bytes": len(v1),
            "title": "notes.txt",
            "source_kind": "misc",
            "source_device_id": device_id,
        },
    ).json()["file_id"]

    assert client.delete(f"/v1/files/{file_id}").status_code == 200
    assert client.get(f"/v1/files/{file_id}").json()["deleted_at"] is not None

    # Same head after tombstone — revive without requiring a new hash.
    again = client.post(
        f"/v1/files/{file_id}/content",
        json={
            "content_hash": h1,
            "hash_algo": DEFAULT_HASH_ALGO,
            "size_bytes": len(v1),
        },
    )
    assert again.status_code == 200, again.text
    assert again.json()["deleted_at"] is None
    assert again.json()["content_hash"] == h1

    v2 = b"alive with new bytes\n"
    h2 = _put_blob(client, v2)
    assert client.delete(f"/v1/files/{file_id}").status_code == 200
    replaced = client.post(
        f"/v1/files/{file_id}/content",
        json={
            "content_hash": h2,
            "hash_algo": DEFAULT_HASH_ALGO,
            "size_bytes": len(v2),
        },
    )
    assert replaced.status_code == 200, replaced.text
    assert replaced.json()["deleted_at"] is None
    assert replaced.json()["content_hash"] == h2


def test_content_update_reuses_hash_from_soft_deleted_sibling(
    client: TestClient,
    data_root: Path,
) -> None:
    """Soft-deleted rows must not 409 UNIQUE(content_hash) for another file_id."""
    _ = data_root
    device_id = str(uuid4())
    assert (
        client.post(
            "/v1/devices",
            json={"device_id": device_id, "name": "pixel-hash-reuse", "kind": "android"},
        ).status_code
        == 200
    )
    va = b"file a head\n"
    vb = b"file b head - will soft-delete\n"
    ha = _put_blob(client, va)
    hb = _put_blob(client, vb)

    fa = client.post(
        "/v1/files",
        json={
            "content_hash": ha,
            "hash_algo": DEFAULT_HASH_ALGO,
            "size_bytes": len(va),
            "title": "a.txt",
            "source_kind": "misc",
            "source_device_id": device_id,
        },
    ).json()["file_id"]
    fb = client.post(
        "/v1/files",
        json={
            "content_hash": hb,
            "hash_algo": DEFAULT_HASH_ALGO,
            "size_bytes": len(vb),
            "title": "b.txt",
            "source_kind": "misc",
            "source_device_id": device_id,
        },
    ).json()["file_id"]

    assert client.delete(f"/v1/files/{fb}").status_code == 200
    # API still exposes the real digest on the tombstone row.
    deleted = client.get(f"/v1/files/{fb}").json()
    assert deleted["deleted_at"] is not None
    assert deleted["content_hash"] == hb

    # Live file A takes B's former head hash — previously HTTP 409.
    moved = client.post(
        f"/v1/files/{fa}/content",
        json={
            "content_hash": hb,
            "hash_algo": DEFAULT_HASH_ALGO,
            "size_bytes": len(vb),
        },
    )
    assert moved.status_code == 200, moved.text
    assert moved.json()["content_hash"] == hb
    assert moved.json()["file_id"] == fa

    # Soft-deleted B still readable; hash freed in DB (API shows real digest).
    assert client.get(f"/v1/files/{fb}").json()["content_hash"] == hb


def test_content_update_frees_legacy_soft_deleted_hash(
    client: TestClient,
    data_root: Path,
) -> None:
    """Pre-006 soft-deleted rows still held the real hex — free on collision."""
    device_id = str(uuid4())
    assert (
        client.post(
            "/v1/devices",
            json={"device_id": device_id, "name": "pixel-legacy-tomb", "kind": "android"},
        ).status_code
        == 200
    )
    va = b"legacy a\n"
    vb = b"legacy b still holding hex\n"
    ha = _put_blob(client, va)
    hb = _put_blob(client, vb)
    fa = client.post(
        "/v1/files",
        json={
            "content_hash": ha,
            "hash_algo": DEFAULT_HASH_ALGO,
            "size_bytes": len(va),
            "title": "a.txt",
            "source_kind": "misc",
            "source_device_id": device_id,
        },
    ).json()["file_id"]
    fb = client.post(
        "/v1/files",
        json={
            "content_hash": hb,
            "hash_algo": DEFAULT_HASH_ALGO,
            "size_bytes": len(vb),
            "title": "b.txt",
            "source_kind": "misc",
            "source_device_id": device_id,
        },
    ).json()["file_id"]
    assert client.delete(f"/v1/files/{fb}").status_code == 200

    # Simulate pre-migration row: soft-deleted but still UNIQUE on real hex.
    _, engine = bootstrap(data_root)
    with session_scope(engine) as session:
        row = session.get(File, fb)
        assert row is not None
        row.content_hash = hb
        session.flush()

    moved = client.post(
        f"/v1/files/{fa}/content",
        json={
            "content_hash": hb,
            "hash_algo": DEFAULT_HASH_ALGO,
            "size_bytes": len(vb),
        },
    )
    assert moved.status_code == 200, moved.text
    assert moved.json()["content_hash"] == hb
