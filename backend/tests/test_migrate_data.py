"""homesync-migrate-data: copy managed store and update config."""

from __future__ import annotations

from pathlib import Path

import pytest

from homesync_server.migrate_data import MigrateError, main_migrate, migrate_data


def _seed_store(root: Path) -> None:
    root.mkdir(parents=True)
    (root / "catalog.sqlite").write_bytes(b"sqlite-fixture")
    (root / "blobs").mkdir()
    (root / "blobs" / "blake3").mkdir()
    (root / "blobs" / "blake3" / "ab").mkdir()
    leaf = root / "blobs" / "blake3" / "ab" / "cd"
    leaf.mkdir(parents=True)
    (leaf / "abcdhash").write_bytes(b"blob")
    (root / "thumbs").mkdir()
    (root / "quarantine").mkdir()


def test_migrate_copies_and_writes_config(tmp_path: Path) -> None:
    src = tmp_path / "old"
    dst = tmp_path / "new"
    cfg = tmp_path / "config.toml"
    _seed_store(src)

    result = migrate_data(
        source=src,
        dest=dst,
        write_config=True,
        config_file=cfg,
    )

    assert result.dest == dst.resolve()
    assert (dst / "catalog.sqlite").read_bytes() == b"sqlite-fixture"
    assert (dst / "blobs" / "blake3" / "ab" / "cd" / "abcdhash").read_bytes() == b"blob"
    assert src.exists()
    assert not result.source_deleted
    assert result.config_written == cfg.resolve()
    assert f'data_dir = "{dst.resolve()}"' in cfg.read_text(encoding="utf-8")


def test_migrate_delete_source(tmp_path: Path) -> None:
    src = tmp_path / "old"
    dst = tmp_path / "new"
    _seed_store(src)

    result = migrate_data(
        source=src,
        dest=dst,
        write_config=False,
        delete_source=True,
    )

    assert result.source_deleted
    assert not src.exists()
    assert (dst / "catalog.sqlite").is_file()


def test_migrate_refuses_nonempty_dest(tmp_path: Path) -> None:
    src = tmp_path / "old"
    dst = tmp_path / "new"
    _seed_store(src)
    dst.mkdir()
    (dst / "keep").write_text("x", encoding="utf-8")

    with pytest.raises(MigrateError, match="not empty"):
        migrate_data(source=src, dest=dst, write_config=False)


def test_migrate_force_overwrites_dest(tmp_path: Path) -> None:
    src = tmp_path / "old"
    dst = tmp_path / "new"
    _seed_store(src)
    dst.mkdir()
    (dst / "stale").write_text("x", encoding="utf-8")

    migrate_data(source=src, dest=dst, force=True, write_config=False)
    assert not (dst / "stale").exists()
    assert (dst / "catalog.sqlite").is_file()


def test_migrate_same_path_refused(tmp_path: Path) -> None:
    src = tmp_path / "same"
    _seed_store(src)
    with pytest.raises(MigrateError, match="same path"):
        migrate_data(source=src, dest=src, write_config=False)


def test_migrate_cli_exit_codes(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    src = tmp_path / "old"
    dst = tmp_path / "new"
    cfg = tmp_path / "config.toml"
    monkeypatch.setenv("HOMESYNC_CONFIG", str(cfg))
    _seed_store(src)

    code = main_migrate(["--from", str(src), "--to", str(dst)])
    assert code == 0
    assert (dst / "catalog.sqlite").is_file()
    assert f'data_dir = "{dst.resolve()}"' in cfg.read_text(encoding="utf-8")

    # Second migrate into nonempty dest without --force → failure.
    assert main_migrate(["--from", str(src), "--to", str(dst)]) == 1
