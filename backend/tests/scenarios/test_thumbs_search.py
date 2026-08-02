"""Milestone 7 exit check: server thumbs + basic catalog search."""

from __future__ import annotations

from io import BytesIO
from pathlib import Path
from uuid import uuid4

from fastapi.testclient import TestClient
from PIL import Image

from homesync_server.config import DEFAULT_HASH_ALGO
from homesync_server.db import bootstrap, session_scope
from homesync_server.models import File
from homesync_server.storage import blob_path, hash_bytes, thumb_path
from homesync_server.util import new_uuid, utc_now_iso


def _jpeg_bytes(width: int = 80, height: int = 60, color: tuple[int, int, int] = (200, 40, 40)) -> bytes:
    img = Image.new("RGB", (width, height), color=color)
    buf = BytesIO()
    img.save(buf, format="JPEG", quality=90)
    return buf.getvalue()


def _put_managed_image(client: TestClient, data_root: Path, *, title: str) -> dict:
    body = _jpeg_bytes()
    digest = hash_bytes(body)
    put = client.put(
        f"/v1/blobs/{DEFAULT_HASH_ALGO}/{digest}",
        content=body,
        headers={"Content-Type": "application/octet-stream"},
    )
    assert put.status_code in (200, 201)

    device_id = str(uuid4())
    assert (
        client.post(
            "/v1/devices",
            json={"device_id": device_id, "name": "thumb-phone", "kind": "android"},
        ).status_code
        == 200
    )

    created = client.post(
        "/v1/files",
        json={
            "content_hash": digest,
            "hash_algo": DEFAULT_HASH_ALGO,
            "size_bytes": len(body),
            "mime_type": "image/jpeg",
            "title": title,
            "source_kind": "camera",
            "source_device_id": device_id,
        },
    )
    assert created.status_code == 200
    out = created.json()
    out["_bytes"] = body
    out["_hash"] = digest
    return out


def test_thumb_generated_and_cached(
    client: TestClient,
    data_root: Path,
) -> None:
    file_body = _put_managed_image(client, data_root, title="vacation.jpg")
    file_id = file_body["file_id"]
    digest = file_body["_hash"]

    assert file_body["has_thumb"] is True
    assert file_body["mime_type"] == "image/jpeg"

    # First GET generates and caches under thumbs/.
    thumb = client.get(f"/v1/thumbs/{file_id}")
    assert thumb.status_code == 200
    assert thumb.headers.get("content-type", "").startswith("image/jpeg")
    assert len(thumb.content) < len(file_body["_bytes"])
    assert len(thumb.content) > 0
    cached = thumb_path(data_root, digest)
    assert cached.is_file()
    assert cached.read_bytes() == thumb.content

    # Second GET is a cache hit (same bytes).
    again = client.get(f"/v1/thumbs/{file_id}")
    assert again.status_code == 200
    assert again.content == thumb.content

    # Non-image → 415.
    text = b"not an image\n"
    text_hash = hash_bytes(text)
    dest = blob_path(data_root, DEFAULT_HASH_ALGO, text_hash)
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_bytes(text)
    now = utc_now_iso()
    text_id = new_uuid()
    _, engine = bootstrap(data_root)
    with session_scope(engine) as session:
        session.add(
            File(
                file_id=text_id,
                content_hash=text_hash,
                hash_algo=DEFAULT_HASH_ALGO,
                mime_type="text/plain",
                size_bytes=len(text),
                title="note.txt",
                created_at=now,
                updated_at=now,
            )
        )

    unsupported = client.get(f"/v1/thumbs/{text_id}")
    assert unsupported.status_code == 415

    missing = client.get(f"/v1/thumbs/{uuid4()}")
    assert missing.status_code == 404


def test_basic_search_title_and_tags(
    client: TestClient,
    data_root: Path,
) -> None:
    a = _put_managed_image(client, data_root, title="Family picnic.jpg")
    file_id = a["file_id"]

    tagged = client.put(f"/v1/files/{file_id}/tags", json={"tags": ["family", "album"]})
    assert tagged.status_code == 200

    # Second distinct image (different bytes → different hash).
    body2 = _jpeg_bytes(color=(10, 120, 200))
    digest2 = hash_bytes(body2)
    assert (
        client.put(
            f"/v1/blobs/{DEFAULT_HASH_ALGO}/{digest2}",
            content=body2,
        ).status_code
        in (200, 201)
    )
    other = client.post(
        "/v1/files",
        json={
            "content_hash": digest2,
            "hash_algo": DEFAULT_HASH_ALGO,
            "size_bytes": len(body2),
            "mime_type": "image/jpeg",
            "title": "Work invoice scan",
            "source_kind": "download",
        },
    )
    assert other.status_code == 200
    other_id = other.json()["file_id"]
    assert other_id != file_id

    by_title = client.get("/v1/files", params={"q": "picnic"})
    assert by_title.status_code == 200
    titles = {f["file_id"]: f["title"] for f in by_title.json()}
    assert file_id in titles
    assert other_id not in titles

    by_tag = client.get("/v1/files", params={"q": "FAMILY"})
    assert by_tag.status_code == 200
    tag_ids = {f["file_id"] for f in by_tag.json()}
    assert file_id in tag_ids

    by_work = client.get("/v1/files", params={"q": "invoice"})
    assert by_work.status_code == 200
    work_ids = {f["file_id"] for f in by_work.json()}
    assert other_id in work_ids
    assert file_id not in work_ids

    # Empty q behaves like unfiltered list (both present).
    all_files = client.get("/v1/files")
    assert all_files.status_code == 200
    all_ids = {f["file_id"] for f in all_files.json()}
    assert file_id in all_ids and other_id in all_ids

    # Catalog delta includes has_thumb for images.
    delta = client.get("/v1/catalog/delta")
    assert delta.status_code == 200
    image_rows = [f for f in delta.json()["files"] if f["file_id"] in {file_id, other_id}]
    assert image_rows
    assert all(f["has_thumb"] is True for f in image_rows)


def test_thumb_path_layout(data_root: Path) -> None:
    digest = "aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899"
    path = thumb_path(data_root, digest)
    assert path == data_root / "thumbs" / "aa" / "bb" / f"{digest}.jpg"
