"""Milestone 3 exit check: phone-style device hello + catalog list/delta.

Flutter device E2E is deferred; this scenario covers the API the phone calls.
"""

from __future__ import annotations

from pathlib import Path
from uuid import uuid4

from fastapi.testclient import TestClient

from homesync_server.db import bootstrap, session_scope
from homesync_server.indexer import ensure_library_root, index_all_roots


def test_device_register_and_catalog_delta_as_phone(
    client: TestClient,
    data_root: Path,
    library_root: Path,
) -> None:
    _, engine = bootstrap(data_root)
    with session_scope(engine) as session:
        ensure_library_root(session, library_root, label="fixture")
        stats = index_all_roots(session)

    assert stats.seen == 2

    device_id = str(uuid4())

    # Phone hello / registration.
    hello = client.post(
        "/v1/devices",
        json={"device_id": device_id, "name": "pixel-test", "kind": "android"},
    )
    assert hello.status_code == 200
    body = hello.json()
    assert body["device_id"] == device_id
    assert body["name"] == "pixel-test"
    assert body["kind"] == "android"
    assert body["last_seen_at"] is not None
    created_at = body["created_at"]
    first_seen = body["last_seen_at"]

    # Idempotent re-register refreshes last_seen, keeps created_at.
    hello2 = client.post(
        "/v1/devices",
        json={"device_id": device_id, "name": "pixel-test", "kind": "android"},
    )
    assert hello2.status_code == 200
    assert hello2.json()["created_at"] == created_at
    assert hello2.json()["last_seen_at"] >= first_seen

    got = client.get(f"/v1/devices/{device_id}")
    assert got.status_code == 200
    assert got.json()["device_id"] == device_id

    missing = client.get(f"/v1/devices/{uuid4()}")
    assert missing.status_code == 404

    listed = client.get("/v1/devices")
    assert listed.status_code == 200
    ids = {d["device_id"] for d in listed.json()}
    assert device_id in ids

    bad_kind = client.post(
        "/v1/devices",
        json={"device_id": str(uuid4()), "name": "x", "kind": "toaster"},
    )
    assert bad_kind.status_code == 400

    # Phone-style full catalog pull (paginated delta from empty cursor).
    page1 = client.get("/v1/catalog/delta", params={"limit": 1})
    assert page1.status_code == 200
    d1 = page1.json()
    assert len(d1["files"]) == 1
    assert d1["next_cursor"].startswith("v1:")
    assert "paths" in d1
    assert d1["availability"] == []

    page2 = client.get(
        "/v1/catalog/delta",
        params={"since": d1["next_cursor"], "limit": 10},
    )
    assert page2.status_code == 200
    d2 = page2.json()
    assert len(d2["files"]) == 1
    assert {d1["files"][0]["file_id"], d2["files"][0]["file_id"]} == {
        f["file_id"] for f in client.get("/v1/files").json()
    }

    # Caught up after full pull.
    caught = client.get("/v1/catalog/delta", params={"since": d2["next_cursor"]})
    assert caught.status_code == 200
    assert caught.json()["files"] == []
    assert caught.json()["next_cursor"] == d2["next_cursor"]

    # Soft-delete surfaces as tombstone on next delta (phone must keep listing until GC).
    file_id = d1["files"][0]["file_id"]
    deleted = client.delete(f"/v1/files/{file_id}")
    assert deleted.status_code == 200
    assert deleted.json()["deleted_at"] is not None

    delta_tomb = client.get("/v1/catalog/delta", params={"since": d2["next_cursor"]})
    assert delta_tomb.status_code == 200
    tomb_files = delta_tomb.json()["files"]
    assert len(tomb_files) == 1
    assert tomb_files[0]["file_id"] == file_id
    assert tomb_files[0]["deleted_at"] is not None

    # Active list excludes soft-deleted; phone mirror would hide them in browse UI.
    listed = client.get("/v1/files")
    assert listed.status_code == 200
    assert all(f["file_id"] != file_id for f in listed.json())
    assert len(listed.json()) == 1
