"""Linux catalog CLI — same HTTP flows as the Flutter client."""

from __future__ import annotations

from pathlib import Path

from fastapi.testclient import TestClient

from homesync_server.client.cli import main
from homesync_server.db import bootstrap, session_scope
from homesync_server.indexer import ensure_library_root, index_all_roots


def _run(
    http: TestClient,
    argv: list[str],
    tmp_path: Path,
    monkeypatch,
) -> int:
    monkeypatch.setenv("HOMESYNC_CLIENT_CONFIG", str(tmp_path / "client.toml"))
    monkeypatch.setenv("HOMESYNC_PIN_MAP", str(tmp_path / "pins.json"))
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    (tmp_path / "home").mkdir(exist_ok=True)
    return main(argv, http=http)


def test_linux_cli_browse_pin_ingest_rm(
    client: TestClient,
    data_root: Path,
    library_root: Path,
    tmp_path: Path,
    monkeypatch,
    capsys,
) -> None:
    _, engine = bootstrap(data_root)
    with session_scope(engine) as session:
        ensure_library_root(session, library_root, label="fixture")
        index_all_roots(session)

    assert _run(client, ["init", "--name", "toaster"], tmp_path, monkeypatch) == 0
    out = capsys.readouterr().out
    assert "registered toaster" in out

    assert _run(client, ["status"], tmp_path, monkeypatch) == 0
    status = capsys.readouterr().out
    assert "ok" in status
    assert "toaster" in status

    assert _run(client, ["ls"], tmp_path, monkeypatch) == 0
    listing = capsys.readouterr().out
    assert "hello.txt" in listing
    assert "note.md" in listing

    assert _run(client, ["show", "hello.txt"], tmp_path, monkeypatch) == 0
    detail = capsys.readouterr().out
    assert "hello.txt" in detail
    assert "listed" in detail

    dest = tmp_path / "pins"
    assert (
        _run(
            client,
            ["pin", "hello.txt", "--to", str(dest)],
            tmp_path,
            monkeypatch,
        )
        == 0
    )
    pin_out = capsys.readouterr().out
    assert "pinned" in pin_out
    written = dest / "hello.txt"
    assert written.is_file()
    assert written.read_bytes() == b"hello homesync\n"

    assert _run(client, ["show", "hello.txt"], tmp_path, monkeypatch) == 0
    assert "pinned" in capsys.readouterr().out

    assert _run(client, ["tag", "hello.txt", "--add", "family"], tmp_path, monkeypatch) == 0
    capsys.readouterr()
    assert _run(client, ["show", "hello.txt"], tmp_path, monkeypatch) == 0
    assert "family" in capsys.readouterr().out

    assert _run(client, ["unpin", "hello.txt"], tmp_path, monkeypatch) == 0
    capsys.readouterr()
    assert not written.exists()

    camera = tmp_path / "IMG_001.jpg"
    camera.write_bytes(b"phone-origin-bytes\n")
    assert _run(client, ["ingest", str(camera)], tmp_path, monkeypatch) == 0
    ingested = capsys.readouterr().out
    assert "ingested" in ingested
    assert "IMG_001.jpg" in ingested

    assert _run(client, ["ls", "-q", "IMG_001"], tmp_path, monkeypatch) == 0
    assert "IMG_001.jpg" in capsys.readouterr().out

    got = tmp_path / "copy.jpg"
    assert (
        _run(
            client,
            ["get", "IMG_001.jpg", "--out", str(got)],
            tmp_path,
            monkeypatch,
        )
        == 0
    )
    capsys.readouterr()
    assert got.read_bytes() == b"phone-origin-bytes\n"

    assert _run(client, ["rm", "IMG_001.jpg"], tmp_path, monkeypatch) == 0
    capsys.readouterr()
    assert _run(client, ["ls", "--deleted", "-q", "IMG_001"], tmp_path, monkeypatch) == 0
    assert "tombstone" in capsys.readouterr().out

    prefix_dir = tmp_path / "folder-pins"
    assert (
        _run(
            client,
            ["keep-folder", "subdir", "--to", str(prefix_dir)],
            tmp_path,
            monkeypatch,
        )
        == 0
    )
    keep_out = capsys.readouterr().out
    assert "note.md" in keep_out
    assert (prefix_dir / "note.md").is_file()
    assert (prefix_dir / "note.md").read_bytes() == b"# note\n"
