"""Runtime configuration for the Homesync daemon and indexer."""

from __future__ import annotations

import os
import re
import tomllib
from dataclasses import dataclass
from pathlib import Path

DEFAULT_HASH_ALGO = "blake3"


class ConfigError(ValueError):
    """Invalid Homesync config file or value."""


@dataclass(frozen=True)
class HomesyncConfig:
    """Parsed user config (optional fields)."""

    data_dir: Path | None = None


def default_data_root() -> Path:
    return (Path.home() / ".local" / "share" / "homesync").resolve()


def config_path() -> Path:
    """Path to the TOML config file (`$HOMESYNC_CONFIG` or XDG)."""
    override = os.environ.get("HOMESYNC_CONFIG")
    if override:
        return Path(override).expanduser().resolve()
    xdg = os.environ.get("XDG_CONFIG_HOME")
    if xdg:
        return (Path(xdg).expanduser() / "homesync" / "config.toml").resolve()
    return (Path.home() / ".config" / "homesync" / "config.toml").resolve()


def load_config(path: Path | None = None) -> HomesyncConfig:
    """Load config from disk. Missing file → empty config. Bad file → ConfigError."""
    cfg_path = path if path is not None else config_path()
    if not cfg_path.is_file():
        return HomesyncConfig()
    try:
        raw = tomllib.loads(cfg_path.read_text(encoding="utf-8"))
    except tomllib.TOMLDecodeError as exc:
        raise ConfigError(f"invalid config TOML at {cfg_path}: {exc}") from exc
    if not isinstance(raw, dict):
        raise ConfigError(f"invalid config at {cfg_path}: expected a table")

    data_dir_raw = raw.get("data_dir")
    if data_dir_raw is None:
        return HomesyncConfig()
    if not isinstance(data_dir_raw, str) or not data_dir_raw.strip():
        raise ConfigError(
            f"invalid config at {cfg_path}: data_dir must be a non-empty string"
        )
    return HomesyncConfig(data_dir=Path(data_dir_raw).expanduser().resolve())


def write_data_dir(data_dir: Path, path: Path | None = None) -> Path:
    """Write or update ``data_dir`` in the config file. Returns the config path."""
    cfg_path = path if path is not None else config_path()
    cfg_path.parent.mkdir(parents=True, exist_ok=True)
    resolved = str(data_dir.expanduser().resolve())
    line = f'data_dir = "{_toml_escape(resolved)}"'
    if cfg_path.is_file():
        text = cfg_path.read_text(encoding="utf-8")
        if re.search(r"(?m)^data_dir\s*=", text):
            text = re.sub(r"(?m)^data_dir\s*=\s*.*$", line, text)
        else:
            text = text.rstrip() + "\n" + line + "\n"
        if not text.endswith("\n"):
            text += "\n"
        cfg_path.write_text(text, encoding="utf-8")
    else:
        cfg_path.write_text(line + "\n", encoding="utf-8")
    return cfg_path


def _toml_escape(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"')


def data_root() -> Path:
    """Canonical data directory.

    Resolution: ``$HOMESYNC_DATA`` > config ``data_dir`` > ``~/.local/share/homesync``.
    """
    override = os.environ.get("HOMESYNC_DATA")
    if override:
        return Path(override).expanduser().resolve()
    cfg = load_config()
    if cfg.data_dir is not None:
        return cfg.data_dir
    return default_data_root()


def catalog_db_path(root: Path | None = None) -> Path:
    return (root or data_root()) / "catalog.sqlite"


def ensure_data_dirs(root: Path | None = None) -> Path:
    """Create data root layout; return the resolved root."""
    base = root or data_root()
    base.mkdir(parents=True, exist_ok=True)
    (base / "blobs").mkdir(exist_ok=True)
    (base / "thumbs").mkdir(exist_ok=True)
    (base / "quarantine").mkdir(exist_ok=True)
    return base
