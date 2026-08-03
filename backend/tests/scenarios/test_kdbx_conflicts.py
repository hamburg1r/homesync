"""Milestone 9: KeePass conflict outbox (trivial / auto-merge / real resolve)."""

from __future__ import annotations

import shutil
from datetime import UTC, datetime, timedelta
from pathlib import Path
from uuid import uuid4

from fastapi.testclient import TestClient
from pykeepass import PyKeePass, create_database

from homesync_server.config import DEFAULT_HASH_ALGO
from homesync_server.db import bootstrap
from homesync_server.db.migrate import current_version
from homesync_server.kdbx import secrets as kdbx_secrets
from homesync_server.kdbx.diff import DiffClassification, classify_kdbx_paths
from homesync_server.kdbx.merge import merge_kdbx_paths
from homesync_server.storage import blob_path, hash_bytes

VAULT_PW = "test-master-password"


def _make_kdbx(path: Path, *, title: str, password: str, username: str = "u") -> None:
    kp = create_database(str(path), password=VAULT_PW)
    kp.add_entry(kp.root_group, title, username, password)
    kp.save()


def _clone_kdbx(src: Path, dest: Path) -> None:
    shutil.copy2(src, dest)


def _put_bytes(client: TestClient, data_root: Path, payload: bytes) -> str:
    digest = hash_bytes(payload)
    put = client.put(f"/v1/blobs/{DEFAULT_HASH_ALGO}/{digest}", content=payload)
    assert put.status_code in (200, 201), put.text
    assert blob_path(data_root, DEFAULT_HASH_ALGO, digest).is_file()
    return digest


def _register_device(client: TestClient) -> str:
    device_id = str(uuid4())
    assert (
        client.post(
            "/v1/devices",
            json={"device_id": device_id, "name": "pixel-kdbx", "kind": "android"},
        ).status_code
        == 200
    )
    return device_id


def _create_vault_file(
    client: TestClient,
    data_root: Path,
    kdbx_path: Path,
    device_id: str,
) -> dict:
    payload = kdbx_path.read_bytes()
    digest = _put_bytes(client, data_root, payload)
    created = client.post(
        "/v1/files",
        json={
            "content_hash": digest,
            "hash_algo": DEFAULT_HASH_ALGO,
            "size_bytes": len(payload),
            "mime_type": "application/x-keepass2",
            "title": "passes.kdbx",
            "source_kind": "misc",
            "source_device_id": device_id,
            "relative_path": "ingest/misc/passes.kdbx",
        },
    )
    assert created.status_code == 200, created.text
    return created.json()


def _set_secret(client: TestClient, file_id: str) -> None:
    assert (
        client.put(
            f"/v1/files/{file_id}/kdbx-secret",
            json={"password": VAULT_PW},
        ).status_code
        == 200
    )


def test_classify_trivial_vs_real(tmp_path: Path) -> None:
    a = tmp_path / "a.kdbx"
    b_same = tmp_path / "b_same.kdbx"
    b_diff = tmp_path / "b_diff.kdbx"
    _make_kdbx(a, title="Bank", password="secret1")
    # Rewrite identical semantic content (new bytes after save).
    _make_kdbx(b_same, title="Bank", password="secret1")
    _make_kdbx(b_diff, title="Bank", password="secret2")

    trivial = classify_kdbx_paths(a, b_same, password=VAULT_PW)
    assert trivial.classification == DiffClassification.trivial

    real = classify_kdbx_paths(a, b_diff, password=VAULT_PW)
    assert real.classification == DiffClassification.real
    assert "password" in real.modified_fields.get("Root/Bank", [])
    summary = real.redacted_summary()
    assert "secret" not in str(summary).lower() or "secret2" not in str(summary)


def test_classify_move_is_auto_mergeable(tmp_path: Path) -> None:
    a = tmp_path / "a.kdbx"
    b = tmp_path / "b.kdbx"
    _make_kdbx(a, title="Bank", password="secret1")
    _clone_kdbx(a, b)
    kp = PyKeePass(str(b), password=VAULT_PW)
    entry = kp.find_entries(title="Bank", first=True)
    assert entry is not None
    work = kp.add_group(kp.root_group, "Work")
    kp.move_entry(entry, work)
    kp.save()

    diff = classify_kdbx_paths(a, b, password=VAULT_PW)
    assert diff.classification == DiffClassification.real
    assert diff.moved_entries
    assert diff.removed_entry_uuids == []
    assert diff.is_auto_mergeable


def test_classify_deletion_not_auto_mergeable(tmp_path: Path) -> None:
    a = tmp_path / "a.kdbx"
    b = tmp_path / "b.kdbx"
    _make_kdbx(a, title="Bank", password="secret1")
    _clone_kdbx(a, b)
    kp = PyKeePass(str(b), password=VAULT_PW)
    entry = kp.find_entries(title="Bank", first=True)
    assert entry is not None
    kp.delete_entry(entry)
    kp.save()

    diff = classify_kdbx_paths(a, b, password=VAULT_PW)
    assert diff.classification == DiffClassification.real
    assert diff.removed_entry_uuids
    assert not diff.is_auto_mergeable


def test_merge_add_and_lww_password(tmp_path: Path) -> None:
    a = tmp_path / "a.kdbx"
    b = tmp_path / "b.kdbx"
    out = tmp_path / "out.kdbx"
    _make_kdbx(a, title="Bank", password="from-a")
    _clone_kdbx(a, b)

    kp_a = PyKeePass(str(a), password=VAULT_PW)
    bank_a = kp_a.find_entries(title="Bank", first=True)
    assert bank_a is not None
    bank_uuid = bank_a.uuid
    kp_a.add_entry(kp_a.root_group, "OnlyA", "u", "a-secret")
    kp_a.save()

    kp_b = PyKeePass(str(b), password=VAULT_PW)
    bank_b = kp_b.find_entries(title="Bank", first=True)
    assert bank_b is not None
    bank_b.password = "from-b"
    bank_b.mtime = datetime.now(UTC) + timedelta(hours=1)
    kp_b.add_entry(kp_b.root_group, "OnlyB", "u", "b-secret")
    kp_b.save()

    # B is missing OnlyA → not auto-mergeable as content upload; merge helper
    # still unions when called directly (service gates on is_auto_mergeable).
    merge_kdbx_paths(a, b, password=VAULT_PW, dest=out)
    merged = PyKeePass(str(out), password=VAULT_PW)
    titles = {e.title for e in merged.entries}
    assert "OnlyA" in titles and "OnlyB" in titles
    bank = merged.find_entries(uuid=bank_uuid, first=True)
    assert bank is not None
    assert bank.password == "from-b"


def test_kdbx_trivial_auto_resolves(
    client: TestClient,
    data_root: Path,
    tmp_path: Path,
    monkeypatch,
) -> None:
    secrets = tmp_path / "kdbx_secrets.json"
    monkeypatch.setenv("HOMESYNC_KDBX_SECRETS", str(secrets))

    _, engine = bootstrap(data_root)
    with engine.connect() as conn:
        assert current_version(conn) >= 5

    device_id = _register_device(client)
    a = tmp_path / "v1.kdbx"
    b = tmp_path / "v2.kdbx"
    _make_kdbx(a, title="Bank", password="same")
    _make_kdbx(b, title="Bank", password="same")
    from pykeepass import PyKeePass as PK

    kp = PK(str(b), password=VAULT_PW)
    if hash_bytes(a.read_bytes()) == hash_bytes(b.read_bytes()):
        entry = kp.find_entries(title="Bank", first=True)
        assert entry is not None
        entry.notes = " "
        kp.save()
    assert hash_bytes(a.read_bytes()) != hash_bytes(b.read_bytes())

    file_body = _create_vault_file(client, data_root, a, device_id)
    file_id = file_body["file_id"]
    head1 = file_body["content_hash"]
    _set_secret(client, file_id)
    assert kdbx_secrets.has_password(file_id)

    payload_b = b.read_bytes()
    h2 = _put_bytes(client, data_root, payload_b)
    resp = client.post(
        f"/v1/files/{file_id}/content",
        json={
            "content_hash": h2,
            "hash_algo": DEFAULT_HASH_ALGO,
            "size_bytes": len(payload_b),
            "note": "phone rewrite",
        },
    )
    assert resp.status_code == 200, resp.text
    assert resp.json()["file_id"] == file_id
    assert resp.json()["content_hash"] == h2
    assert resp.json()["content_hash"] != head1

    open_list = client.get("/v1/conflicts", params={"state": "open"})
    assert open_list.status_code == 200
    assert open_list.json() == []


def test_kdbx_auto_merges_add_and_move(
    client: TestClient,
    data_root: Path,
    tmp_path: Path,
    monkeypatch,
) -> None:
    secrets = tmp_path / "kdbx_secrets.json"
    monkeypatch.setenv("HOMESYNC_KDBX_SECRETS", str(secrets))

    device_id = _register_device(client)
    a = tmp_path / "base.kdbx"
    b = tmp_path / "incoming.kdbx"
    _make_kdbx(a, title="Bank", password="same")
    _clone_kdbx(a, b)

    kp = PyKeePass(str(b), password=VAULT_PW)
    bank = kp.find_entries(title="Bank", first=True)
    assert bank is not None
    work = kp.add_group(kp.root_group, "Work")
    kp.move_entry(bank, work)
    kp.add_entry(kp.root_group, "PhoneOnly", "u", "phone-secret")
    kp.save()

    file_body = _create_vault_file(client, data_root, a, device_id)
    file_id = file_body["file_id"]
    head_a = file_body["content_hash"]
    _set_secret(client, file_id)

    payload_b = b.read_bytes()
    hb = _put_bytes(client, data_root, payload_b)
    resp = client.post(
        f"/v1/files/{file_id}/content",
        json={
            "content_hash": hb,
            "hash_algo": DEFAULT_HASH_ALGO,
            "size_bytes": len(payload_b),
        },
    )
    assert resp.status_code == 200, resp.text
    merged_hash = resp.json()["content_hash"]
    assert merged_hash != head_a
    assert client.get("/v1/conflicts", params={"state": "open"}).json() == []

    merged_path = blob_path(data_root, DEFAULT_HASH_ALGO, merged_hash)
    merged = PyKeePass(str(merged_path), password=VAULT_PW)
    titles = {e.title for e in merged.entries}
    assert "Bank" in titles and "PhoneOnly" in titles
    bank_m = merged.find_entries(title="Bank", first=True)
    assert bank_m is not None
    assert "Work" in (bank_m.group.name or "")


def test_kdbx_auto_merges_lww_field_edit(
    client: TestClient,
    data_root: Path,
    tmp_path: Path,
    monkeypatch,
) -> None:
    secrets = tmp_path / "kdbx_secrets.json"
    monkeypatch.setenv("HOMESYNC_KDBX_SECRETS", str(secrets))

    device_id = _register_device(client)
    a = tmp_path / "base.kdbx"
    b = tmp_path / "incoming.kdbx"
    _make_kdbx(a, title="Bank", password="from-a")
    _clone_kdbx(a, b)

    kp = PyKeePass(str(b), password=VAULT_PW)
    bank = kp.find_entries(title="Bank", first=True)
    assert bank is not None
    bank.password = "from-b"
    bank.mtime = datetime.now(UTC) + timedelta(hours=2)
    kp.save()

    file_body = _create_vault_file(client, data_root, a, device_id)
    file_id = file_body["file_id"]
    _set_secret(client, file_id)

    payload_b = b.read_bytes()
    hb = _put_bytes(client, data_root, payload_b)
    resp = client.post(
        f"/v1/files/{file_id}/content",
        json={
            "content_hash": hb,
            "hash_algo": DEFAULT_HASH_ALGO,
            "size_bytes": len(payload_b),
        },
    )
    assert resp.status_code == 200, resp.text
    merged_hash = resp.json()["content_hash"]
    merged = PyKeePass(
        str(blob_path(data_root, DEFAULT_HASH_ALGO, merged_hash)),
        password=VAULT_PW,
    )
    bank_m = merged.find_entries(title="Bank", first=True)
    assert bank_m is not None
    assert bank_m.password == "from-b"


def test_kdbx_deletion_opens_outbox_and_resolve(
    client: TestClient,
    data_root: Path,
    tmp_path: Path,
    monkeypatch,
) -> None:
    secrets = tmp_path / "kdbx_secrets.json"
    monkeypatch.setenv("HOMESYNC_KDBX_SECRETS", str(secrets))

    device_id = _register_device(client)
    a = tmp_path / "base.kdbx"
    b = tmp_path / "incoming.kdbx"
    c = tmp_path / "extra.kdbx"
    ab = tmp_path / "merged.kdbx"
    _make_kdbx(a, title="Bank", password="from-a")
    _clone_kdbx(a, b)
    kp_b = PyKeePass(str(b), password=VAULT_PW)
    entry = kp_b.find_entries(title="Bank", first=True)
    assert entry is not None
    kp_b.delete_entry(entry)
    kp_b.save()

    _make_kdbx(c, title="Bank", password="from-c")
    _make_kdbx(ab, title="Bank", password="merged-ab")

    file_body = _create_vault_file(client, data_root, a, device_id)
    file_id = file_body["file_id"]
    head_a = file_body["content_hash"]
    _set_secret(client, file_id)

    payload_b = b.read_bytes()
    hb = _put_bytes(client, data_root, payload_b)
    conflict_resp = client.post(
        f"/v1/files/{file_id}/content",
        json={
            "content_hash": hb,
            "hash_algo": DEFAULT_HASH_ALGO,
            "size_bytes": len(payload_b),
        },
    )
    assert conflict_resp.status_code == 202, conflict_resp.text
    body = conflict_resp.json()
    assert body["status"] == "conflict"
    conflict_id = body["conflict"]["conflict_id"]
    assert body["conflict"]["state"] == "open"
    assert body["conflict"]["file_id"] == file_id
    hashes = {c["content_hash"] for c in body["conflict"]["candidates"]}
    assert head_a in hashes and hb in hashes
    assert client.get(f"/v1/files/{file_id}").json()["content_hash"] == head_a

    payload_c = c.read_bytes()
    hc = _put_bytes(client, data_root, payload_c)
    extra = client.post(
        f"/v1/files/{file_id}/content",
        json={
            "content_hash": hc,
            "hash_algo": DEFAULT_HASH_ALGO,
            "size_bytes": len(payload_c),
        },
    )
    assert extra.status_code == 202, extra.text
    cand_hashes = {c["content_hash"] for c in extra.json()["conflict"]["candidates"]}
    assert hc in cand_hashes
    assert len(cand_hashes) == 3

    listed = client.get("/v1/conflicts", params={"state": "open"})
    assert any(c["conflict_id"] == conflict_id for c in listed.json())

    payload_ab = ab.read_bytes()
    hab = _put_bytes(client, data_root, payload_ab)
    resolved = client.post(
        f"/v1/conflicts/{conflict_id}/resolve",
        json={
            "content_hash": hab,
            "hash_algo": DEFAULT_HASH_ALGO,
            "size_bytes": len(payload_ab),
            "note": "merged on phone",
        },
    )
    assert resolved.status_code == 200, resolved.text
    assert resolved.json()["file_id"] == file_id
    assert resolved.json()["content_hash"] == hab

    got = client.get(f"/v1/conflicts/{conflict_id}")
    assert got.json()["state"] == "resolved"
    assert got.json()["resolved_content_hash"] == hab

    open_list = client.get("/v1/conflicts", params={"state": "open"})
    assert open_list.json() == []

    versions = client.get(f"/v1/files/{file_id}/versions").json()
    archived = {v["content_hash"] for v in versions["versions"]}
    assert head_a in archived
    assert hb in archived or hc in archived


def test_kdbx_needs_secret_without_password(
    client: TestClient,
    data_root: Path,
    tmp_path: Path,
    monkeypatch,
) -> None:
    secrets = tmp_path / "empty_secrets.json"
    monkeypatch.setenv("HOMESYNC_KDBX_SECRETS", str(secrets))

    device_id = _register_device(client)
    a = tmp_path / "a.kdbx"
    b = tmp_path / "b.kdbx"
    _make_kdbx(a, title="Bank", password="x")
    _make_kdbx(b, title="Bank", password="y")

    file_body = _create_vault_file(client, data_root, a, device_id)
    file_id = file_body["file_id"]

    payload_b = b.read_bytes()
    hb = _put_bytes(client, data_root, payload_b)
    resp = client.post(
        f"/v1/files/{file_id}/content",
        json={
            "content_hash": hb,
            "hash_algo": DEFAULT_HASH_ALGO,
            "size_bytes": len(payload_b),
        },
    )
    assert resp.status_code == 202, resp.text
    assert resp.json()["conflict"]["state"] == "needs_secret"
