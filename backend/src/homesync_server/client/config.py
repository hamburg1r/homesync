"""Client settings: API URL, device identity, pin destination."""

from __future__ import annotations

import os
import socket
import tomllib
from dataclasses import dataclass
from pathlib import Path
from uuid import uuid4

from homesync_server.config import _toml_escape, config_path

DEFAULT_BASE_URL = "http://127.0.0.1:8787"


class ClientConfigError(ValueError):
    """Invalid client TOML."""


@dataclass(frozen=True)
class ClientSettings:
    base_url: str = DEFAULT_BASE_URL
    device_id: str | None = None
    device_name: str | None = None
    pin_dir: Path | None = None


def client_config_path() -> Path:
    override = os.environ.get("HOMESYNC_CLIENT_CONFIG")
    if override:
        return Path(override).expanduser().resolve()
    return config_path().parent / "client.toml"


def default_pin_dir() -> Path:
    xdg = os.environ.get("XDG_DOWNLOAD_DIR")
    if xdg:
        return Path(xdg).expanduser() / "homesync"
    return (Path.home() / "Downloads" / "homesync").resolve()


def default_device_name() -> str:
    return socket.gethostname() or "linux"


def load_client_settings(path: Path | None = None) -> ClientSettings:
    cfg_path = path if path is not None else client_config_path()
    data: dict[str, object] = {}
    if cfg_path.is_file():
        try:
            raw = tomllib.loads(cfg_path.read_text(encoding="utf-8"))
        except tomllib.TOMLDecodeError as exc:
            raise ClientConfigError(f"invalid client TOML at {cfg_path}: {exc}") from exc
        if not isinstance(raw, dict):
            raise ClientConfigError(f"invalid client config at {cfg_path}")
        data = raw

    url = os.environ.get("HOMESYNC_URL") or _str(data.get("base_url")) or DEFAULT_BASE_URL
    device_id = os.environ.get("HOMESYNC_DEVICE_ID") or _str(data.get("device_id"))
    device_name = os.environ.get("HOMESYNC_DEVICE_NAME") or _str(data.get("device_name"))
    pin_raw = os.environ.get("HOMESYNC_PIN_DIR") or _str(data.get("pin_dir"))
    pin_dir = Path(pin_raw).expanduser().resolve() if pin_raw else None
    return ClientSettings(
        base_url=url.rstrip("/"),
        device_id=device_id or None,
        device_name=device_name or None,
        pin_dir=pin_dir,
    )


def save_client_settings(settings: ClientSettings, path: Path | None = None) -> Path:
    cfg_path = path if path is not None else client_config_path()
    cfg_path.parent.mkdir(parents=True, exist_ok=True)
    lines = [f'base_url = "{_toml_escape(settings.base_url.rstrip("/"))}"']
    if settings.device_id:
        lines.append(f'device_id = "{_toml_escape(settings.device_id)}"')
    if settings.device_name:
        lines.append(f'device_name = "{_toml_escape(settings.device_name)}"')
    if settings.pin_dir is not None:
        lines.append(f'pin_dir = "{_toml_escape(str(settings.pin_dir))}"')
    cfg_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return cfg_path


def ensure_device_id(settings: ClientSettings) -> tuple[ClientSettings, bool]:
    """Return settings with a device_id, minting one if missing."""
    if settings.device_id:
        return settings, False
    minted = ClientSettings(
        base_url=settings.base_url,
        device_id=str(uuid4()),
        device_name=settings.device_name or default_device_name(),
        pin_dir=settings.pin_dir,
    )
    return minted, True


def _str(value: object) -> str | None:
    if isinstance(value, str) and value.strip():
        return value.strip()
    return None
