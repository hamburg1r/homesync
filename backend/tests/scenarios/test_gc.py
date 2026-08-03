"""GC: hard-purge soft-deleted rows + unreferenced managed blobs; delta purged[]."""

from __future__ import annotations

import json
from datetime import UTC, datetime, timedelta
from pathlib import Path
from uuid import uuid4

from fastapi.testclient import TestClient
from sqlalchemy import select

from homesync_server.config import DEFAULT_HASH_ALGO
from homesync_server.db import bootstrap, session_scope
from homesync_server.models import File, GcPurge, KdbxConflict
from homesync_server.services.uploads import upload_dir
from homesync_server.storage import blob_path, hash_bytes, thumb_path, write_blob_atomic
from homesync_server.util import new_uuid, utc_now_iso


def _ingest(
    client: TestClient,
    data_root: Path,
    payload: bytes,
    *,
    title: str = "gone.txt",
) -> tuple[str, str]:
    digest = hash_bytes(payload)
    put = client.put(f"/v1/blobs/{DEFAULT_HASH_ALGO}/{digest}", content=payload)
    assert put.status_code in (200, 201), put.text
    device_id = str(uuid4())
    assert (
        client.post(
            "/v1/devices",
            json={"device_id": device_id, "name": "gc-phone", "kind": "android"},
        ).status_code
        == 200
    )
    created = client.post(
        "/v1/files",
        json={
            "content_hash": digest,
            "hash_algo": DEFAULT_HASH_ALGO,
            "size_bytes": len(payload),
            "mime_type": "text/plain",
            "title": title,
            "source_kind": "misc",
            "source_device_id": device_id,
        },
    )
    assert created.status_code == 200, created.text
    file_id = created.json()["file_id"]
    assert blob_path(data_root, DEFAULT_HASH_ALGO, digest).is_file()
    return file_id, digest


def test_gc_hard_purges_tombstone_and_blob(
    client: TestClient,
    data_root: Path,
) -> None:
    file_id, digest = _ingest(client, data_root, b"gc purge me\n")

    deleted = client.delete(f"/v1/files/{file_id}")
    assert deleted.status_code == 200
    assert deleted.json()["deleted_at"] is not None
    assert blob_path(data_root, DEFAULT_HASH_ALGO, digest).is_file()

    dry = client.post("/v1/gc", json={"dry_run": True})
    assert dry.status_code == 200
    body = dry.json()
    assert body["dry_run"] is True
    assert file_id in body["purged_file_ids"]
    assert any(digest in b for b in body["deleted_blobs"])
    # Dry-run must not mutate.
    assert client.get(f"/v1/files/{file_id}").status_code == 200
    assert blob_path(data_root, DEFAULT_HASH_ALGO, digest).is_file()

    run = client.post("/v1/gc", json={})
    assert run.status_code == 200
    out = run.json()
    assert out["dry_run"] is False
    assert file_id in out["purged_file_ids"]
    assert any(digest in b for b in out["deleted_blobs"])
    assert out["bytes_reclaimed"] >= len(b"gc purge me\n")

    assert client.get(f"/v1/files/{file_id}").status_code == 404
    assert not blob_path(data_root, DEFAULT_HASH_ALGO, digest).is_file()

    _, engine = bootstrap(data_root)
    with session_scope(engine) as session:
        row = session.get(GcPurge, file_id)
        assert row is not None
        assert row.purged_at


def test_gc_keeps_live_blob(
    client: TestClient,
    data_root: Path,
) -> None:
    gone_id, gone_digest = _ingest(client, data_root, b"gone bytes\n", title="gone.txt")
    live_id, live_digest = _ingest(client, data_root, b"live bytes\n", title="live.txt")
    assert client.delete(f"/v1/files/{gone_id}").status_code == 200

    run = client.post("/v1/gc", json={})
    assert run.status_code == 200
    assert gone_id in run.json()["purged_file_ids"]
    assert live_id not in run.json()["purged_file_ids"]
    assert not blob_path(data_root, DEFAULT_HASH_ALGO, gone_digest).is_file()
    assert blob_path(data_root, DEFAULT_HASH_ALGO, live_digest).is_file()
    assert client.get(f"/v1/files/{live_id}").status_code == 200


def test_gc_skips_open_kdbx_conflict(
    client: TestClient,
    data_root: Path,
) -> None:
    file_id, digest = _ingest(client, data_root, b"kdbx holder\n", title="v.kdbx")
    assert client.delete(f"/v1/files/{file_id}").status_code == 200

    _, engine = bootstrap(data_root)
    with session_scope(engine) as session:
        now = utc_now_iso()
        session.add(
            KdbxConflict(
                conflict_id=new_uuid(),
                file_id=file_id,
                state="open",
                created_at=now,
                updated_at=now,
                diff_summary_json=None,
                resolved_content_hash=None,
            )
        )

    run = client.post("/v1/gc", json={})
    assert run.status_code == 200
    out = run.json()
    assert file_id in out["skipped_open_conflict_ids"]
    assert file_id not in out["purged_file_ids"]
    assert blob_path(data_root, DEFAULT_HASH_ALGO, digest).is_file()
    assert client.get(f"/v1/files/{file_id}").status_code == 200


def test_catalog_delta_returns_purged(
    client: TestClient,
    data_root: Path,
) -> None:
    file_id, _digest = _ingest(client, data_root, b"delta purged\n")
    assert client.delete(f"/v1/files/{file_id}").status_code == 200
    assert client.post("/v1/gc", json={}).status_code == 200

    delta = client.get("/v1/catalog/delta", params={"purge_since": ""})
    assert delta.status_code == 200
    body = delta.json()
    purged = [p for p in body["purged"] if p["file_id"] == file_id]
    assert len(purged) == 1
    assert purged[0]["purged_at"]
    assert body["next_purge_cursor"] == purged[0]["purged_at"]

    caught = client.get(
        "/v1/catalog/delta",
        params={"purge_since": body["next_purge_cursor"]},
    )
    assert caught.status_code == 200
    assert caught.json()["purged"] == []
    assert caught.json()["next_purge_cursor"] == body["next_purge_cursor"]


def test_gc_cleans_expired_upload_partials(
    client: TestClient,
    data_root: Path,
) -> None:
    _ = client  # app lifespan / HOMESYNC_DATA
    digest = hash_bytes(b"partial upload forever\n")
    udir = upload_dir(data_root, DEFAULT_HASH_ALGO, digest)
    udir.mkdir(parents=True)
    partial = udir / "partial"
    partial.write_bytes(b"partial upload forever\n")
    old = (datetime.now(UTC) - timedelta(days=8)).isoformat()
    (udir / "meta.json").write_text(
        json.dumps(
            {
                "upload_id": f"{DEFAULT_HASH_ALGO}:{digest}",
                "algo": DEFAULT_HASH_ALGO,
                "content_hash": digest,
                "size_bytes": 1000,
                "offset": len(b"partial upload forever\n"),
                "last_activity": old,
                "complete": False,
            }
        ),
        encoding="utf-8",
    )

    run = client.post("/v1/gc", json={"purge_tombstones": False, "purge_blobs": False})
    assert run.status_code == 200
    assert run.json()["deleted_uploads"] >= 1
    assert not (udir / "meta.json").is_file()


def test_gc_deletes_orphan_thumb(
    client: TestClient,
    data_root: Path,
) -> None:
    _ = client
    orphan = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
    path = thumb_path(data_root, orphan)
    write_blob_atomic(path, b"\xff\xd8\xff orphan jpeg")
    assert path.is_file()

    run = client.post("/v1/gc", json={"purge_tombstones": False, "purge_uploads": False})
    assert run.status_code == 200
    assert orphan in run.json()["deleted_thumbs"]
    assert not path.is_file()


def test_gc_file_ids_filter(
    client: TestClient,
    data_root: Path,
) -> None:
    a, da = _ingest(client, data_root, b"filter a\n", title="a.txt")
    b, db = _ingest(client, data_root, b"filter b\n", title="b.txt")
    assert client.delete(f"/v1/files/{a}").status_code == 200
    assert client.delete(f"/v1/files/{b}").status_code == 200

    run = client.post("/v1/gc", json={"file_ids": [a]})
    assert run.status_code == 200
    assert a in run.json()["purged_file_ids"]
    assert b not in run.json()["purged_file_ids"]
    assert not blob_path(data_root, DEFAULT_HASH_ALGO, da).is_file()
    assert blob_path(data_root, DEFAULT_HASH_ALGO, db).is_file()

    _, engine = bootstrap(data_root)
    with session_scope(engine) as session:
        assert session.get(File, b) is not None
        assert session.scalar(select(File).where(File.file_id == a)) is None
