"""Milestone 2 exit check: tag via API; catalog delta returns the change."""

from __future__ import annotations

from pathlib import Path

from fastapi.testclient import TestClient
from sqlalchemy import select

from homesync_server.db import bootstrap, session_scope
from homesync_server.db.migrate import current_version
from homesync_server.indexer import ensure_library_root, index_all_roots
from homesync_server.models import File, SchemaVersion


def test_schema_includes_tags(data_root: Path) -> None:
    _, engine = bootstrap(data_root)
    with engine.connect() as conn:
        assert current_version(conn) >= 2
    with session_scope(engine) as session:
        versions = session.scalars(select(SchemaVersion)).all()
        assert any(v.version == 2 for v in versions)


def test_tag_file_and_delta_returns_it(
    client: TestClient,
    data_root: Path,
    library_root: Path,
) -> None:
    _, engine = bootstrap(data_root)
    with session_scope(engine) as session:
        ensure_library_root(session, library_root, label="fixture")
        stats = index_all_roots(session)
        file_id = session.scalars(select(File.file_id)).first()

    assert stats.seen == 2
    assert file_id is not None

    listed = client.get("/v1/files")
    assert listed.status_code == 200
    files = listed.json()
    assert len(files) == 2
    assert all("file_id" in f and "content_hash" in f for f in files)

    # Baseline delta: both indexed files.
    delta0 = client.get("/v1/catalog/delta")
    assert delta0.status_code == 200
    body0 = delta0.json()
    assert len(body0["files"]) == 2
    cursor = body0["next_cursor"]
    assert cursor.startswith("v1:")

    # Caught up: no further rows.
    delta_idle = client.get("/v1/catalog/delta", params={"since": cursor})
    assert delta_idle.status_code == 200
    assert delta_idle.json()["files"] == []
    assert delta_idle.json()["next_cursor"] == cursor

    # Tag a file.
    tagged = client.put(
        f"/v1/files/{file_id}/tags",
        json={"tags": ["family", "receipts"]},
    )
    assert tagged.status_code == 200
    tag_body = tagged.json()
    assert set(tag_body["tags"]) == {"family", "receipts"}
    assert tag_body["updated_at"] >= body0["files"][0]["updated_at"]

    # Delta since prior cursor must include the tagged file + tag rows.
    delta1 = client.get("/v1/catalog/delta", params={"since": cursor})
    assert delta1.status_code == 200
    body1 = delta1.json()
    assert len(body1["files"]) == 1
    assert body1["files"][0]["file_id"] == file_id
    assert set(body1["files"][0]["tags"]) == {"family", "receipts"}
    assert {t["name"] for t in body1["tags"]} == {"family", "receipts"}
    assert len(body1["file_tags"]) == 2
    assert body1["next_cursor"] != cursor

    got = client.get(f"/v1/files/{file_id}")
    assert got.status_code == 200
    assert set(got.json()["tags"]) == {"family", "receipts"}

    # Metadata patch (LWW).
    patched = client.patch(
        f"/v1/files/{file_id}",
        json={
            "title": "renamed",
            "notes": "via api",
            "base_updated_at": got.json()["updated_at"],
        },
    )
    assert patched.status_code == 200
    assert patched.json()["title"] == "renamed"
    assert patched.json()["notes"] == "via api"

    # Provenance source_kind patch updates current file_paths.
    sk = client.patch(
        f"/v1/files/{file_id}",
        json={
            "source_kind": "whatsapp",
            "base_updated_at": patched.json()["updated_at"],
        },
    )
    assert sk.status_code == 200
    paths = client.get(f"/v1/files/{file_id}/paths")
    if paths.status_code == 404:
        # Paths may only appear via delta — check delta paths instead.
        delta_sk = client.get("/v1/catalog/delta", params={"since": cursor})
        assert delta_sk.status_code == 200
        path_rows = [
            p
            for p in delta_sk.json().get("paths", [])
            if p["file_id"] == file_id
        ]
        assert path_rows
        assert any(p["source_kind"] == "whatsapp" for p in path_rows)
    else:
        assert paths.status_code == 200
        assert any(p["source_kind"] == "whatsapp" for p in paths.json())

    bad_sk = client.patch(
        f"/v1/files/{file_id}",
        json={"source_kind": "not-a-kind"},
    )
    assert bad_sk.status_code == 400

    # Conflict when base is stale.
    conflict = client.patch(
        f"/v1/files/{file_id}",
        json={"title": "stale", "base_updated_at": "1970-01-01T00:00:00Z"},
    )
    assert conflict.status_code == 409

    tags = client.get("/v1/tags")
    assert tags.status_code == 200
    assert {t["name"] for t in tags.json()} == {"family", "receipts"}
