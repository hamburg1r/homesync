"""Resumable blob upload: begin → chunk PATCH with offset ack → resume."""

from __future__ import annotations

from pathlib import Path

from fastapi.testclient import TestClient

from homesync_server.config import DEFAULT_HASH_ALGO
from homesync_server.storage import blob_path, hash_bytes


def test_resumable_upload_chunks_and_resume(
    client: TestClient,
    data_root: Path,
) -> None:
    payload = b"0123456789" * 200  # 2000 bytes
    digest = hash_bytes(payload)
    mid = 700

    begin = client.post(
        "/v1/blob-uploads",
        json={
            "algo": DEFAULT_HASH_ALGO,
            "content_hash": digest,
            "size_bytes": len(payload),
        },
    )
    assert begin.status_code == 200
    body = begin.json()
    upload_id = body["upload_id"]
    assert body["offset"] == 0
    assert body["complete"] is False

    first = client.patch(
        f"/v1/blob-uploads/{upload_id}",
        content=payload[:mid],
        headers={"Upload-Offset": "0"},
    )
    assert first.status_code == 204
    assert first.headers["upload-offset"] == str(mid)
    assert first.headers["x-upload-complete"] == "0"

    # Simulate reconnect: status shows acked offset.
    status = client.get(f"/v1/blob-uploads/{upload_id}")
    assert status.status_code == 200
    assert status.json()["offset"] == mid

    # Stale/low offset (lost ack / retry) → 204 with current server offset.
    replay = client.patch(
        f"/v1/blob-uploads/{upload_id}",
        content=payload[:10],
        headers={"Upload-Offset": "0"},
    )
    assert replay.status_code == 204
    assert replay.headers["upload-offset"] == str(mid)

    # Gap ahead of server → 409 with server ack.
    bad = client.patch(
        f"/v1/blob-uploads/{upload_id}",
        content=payload[mid : mid + 10],
        headers={"Upload-Offset": str(mid + 50)},
    )
    assert bad.status_code == 409
    assert bad.headers["upload-offset"] == str(mid)

    # Resume from mid through end.
    rest = client.patch(
        f"/v1/blob-uploads/{upload_id}",
        content=payload[mid:],
        headers={"Upload-Offset": str(mid)},
    )
    assert rest.status_code == 204
    assert rest.headers["upload-offset"] == str(len(payload))
    assert rest.headers["x-upload-complete"] == "1"

    managed = blob_path(data_root, DEFAULT_HASH_ALGO, digest)
    assert managed.is_file()
    assert managed.read_bytes() == payload

    # Re-begin is immediately complete (dedup).
    again = client.post(
        "/v1/blob-uploads",
        json={
            "algo": DEFAULT_HASH_ALGO,
            "content_hash": digest,
            "size_bytes": len(payload),
        },
    )
    assert again.status_code == 200
    assert again.json()["complete"] is True
    assert again.json()["offset"] == len(payload)


def test_resumable_upload_rejects_hash_mismatch(
    client: TestClient,
    data_root: Path,
) -> None:
    payload = b"hello-resumable\n"
    wrong_digest = hash_bytes(b"other")
    begin = client.post(
        "/v1/blob-uploads",
        json={
            "algo": DEFAULT_HASH_ALGO,
            "content_hash": wrong_digest,
            "size_bytes": len(payload),
        },
    )
    upload_id = begin.json()["upload_id"]
    done = client.patch(
        f"/v1/blob-uploads/{upload_id}",
        content=payload,
        headers={"Upload-Offset": "0"},
    )
    assert done.status_code == 409
    assert not blob_path(data_root, DEFAULT_HASH_ALGO, wrong_digest).is_file()
