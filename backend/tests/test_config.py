"""Config resolution: HOMESYNC_DATA > config.toml data_dir > default."""

from __future__ import annotations

from pathlib import Path

import pytest

from homesync_server.config import (
    ConfigError,
    config_path,
    data_root,
    default_data_root,
    env_flag,
    load_config,
    server_bind,
    write_data_dir,
)


def test_missing_config_uses_default(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("HOMESYNC_DATA", raising=False)
    monkeypatch.setenv("HOMESYNC_CONFIG", str(tmp_path / "missing.toml"))
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    assert data_root() == default_data_root()
    assert load_config().data_dir is None


def test_config_file_data_dir(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("HOMESYNC_DATA", raising=False)
    cfg = tmp_path / "config.toml"
    store = tmp_path / "on-hdd" / "homesync"
    cfg.write_text(f'data_dir = "{store}"\n', encoding="utf-8")
    monkeypatch.setenv("HOMESYNC_CONFIG", str(cfg))
    assert data_root() == store.resolve()
    assert load_config().data_dir == store.resolve()


def test_env_wins_over_config(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    cfg = tmp_path / "config.toml"
    file_store = tmp_path / "from-file"
    env_store = tmp_path / "from-env"
    cfg.write_text(f'data_dir = "{file_store}"\n', encoding="utf-8")
    monkeypatch.setenv("HOMESYNC_CONFIG", str(cfg))
    monkeypatch.setenv("HOMESYNC_DATA", str(env_store))
    assert data_root() == env_store.resolve()


def test_xdg_config_home(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("HOMESYNC_CONFIG", raising=False)
    monkeypatch.delenv("HOMESYNC_DATA", raising=False)
    xdg = tmp_path / "xdg"
    store = tmp_path / "store"
    cfg = xdg / "homesync" / "config.toml"
    cfg.parent.mkdir(parents=True)
    cfg.write_text(f'data_dir = "{store}"\n', encoding="utf-8")
    monkeypatch.setenv("XDG_CONFIG_HOME", str(xdg))
    assert config_path() == cfg.resolve()
    assert data_root() == store.resolve()


def test_malformed_config_raises(tmp_path: Path) -> None:
    cfg = tmp_path / "bad.toml"
    cfg.write_text("data_dir = [\n", encoding="utf-8")
    with pytest.raises(ConfigError):
        load_config(cfg)


def test_bad_data_dir_type_raises(tmp_path: Path) -> None:
    cfg = tmp_path / "bad.toml"
    cfg.write_text("data_dir = 123\n", encoding="utf-8")
    with pytest.raises(ConfigError, match="non-empty string"):
        load_config(cfg)


def test_server_bind_defaults(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("HOMESYNC_HOST", raising=False)
    monkeypatch.delenv("HOMESYNC_PORT", raising=False)
    monkeypatch.delenv("HOMESYNC_RELOAD", raising=False)
    assert server_bind() == ("127.0.0.1", 8787, False)


def test_server_bind_env(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("HOMESYNC_HOST", "0.0.0.0")
    monkeypatch.setenv("HOMESYNC_PORT", "9000")
    monkeypatch.setenv("HOMESYNC_RELOAD", "1")
    assert server_bind() == ("0.0.0.0", 9000, True)
    assert env_flag("HOMESYNC_RELOAD") is True


def test_server_bind_bad_port(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("HOMESYNC_PORT", "nope")
    with pytest.raises(ConfigError, match="HOMESYNC_PORT"):
        server_bind()


def test_write_data_dir_creates_and_updates(tmp_path: Path) -> None:
    cfg = tmp_path / "homesync" / "config.toml"
    store = tmp_path / "a"
    write_data_dir(store, path=cfg)
    assert cfg.read_text(encoding="utf-8").strip() == f'data_dir = "{store.resolve()}"'
    store2 = tmp_path / "b"
    write_data_dir(store2, path=cfg)
    assert f'data_dir = "{store2.resolve()}"' in cfg.read_text(encoding="utf-8")
