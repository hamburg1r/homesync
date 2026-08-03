"""Per-file_id KeePass unlock secrets (local file, never in catalog SQLite)."""

from __future__ import annotations

import json
import os
from pathlib import Path

from homesync_server.config import config_path


class KdbxSecretError(ValueError):
    pass


def secrets_path() -> Path:
    """``$HOMESYNC_KDBX_SECRETS`` or alongside config: ``kdbx_secrets.json``."""
    override = os.environ.get("HOMESYNC_KDBX_SECRETS")
    if override:
        return Path(override).expanduser().resolve()
    return config_path().parent / "kdbx_secrets.json"


def _load(path: Path | None = None) -> dict[str, str]:
    p = path if path is not None else secrets_path()
    if not p.is_file():
        return {}
    try:
        raw = json.loads(p.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise KdbxSecretError(f"invalid kdbx secrets JSON at {p}: {exc}") from exc
    if not isinstance(raw, dict):
        raise KdbxSecretError(f"invalid kdbx secrets at {p}: expected object")
    out: dict[str, str] = {}
    for k, v in raw.items():
        if isinstance(k, str) and isinstance(v, str) and k and v:
            out[k] = v
    return out


def _save(data: dict[str, str], path: Path | None = None) -> Path:
    p = path if path is not None else secrets_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(p.suffix + ".tmp")
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    tmp.chmod(0o600)
    tmp.replace(p)
    try:
        p.chmod(0o600)
    except OSError:
        pass
    return p


def get_password(file_id: str, path: Path | None = None) -> str | None:
    return _load(path).get(file_id.strip())


def set_password(file_id: str, password: str, path: Path | None = None) -> Path:
    fid = file_id.strip()
    pw = password.strip()
    if not fid:
        raise KdbxSecretError("file_id must be non-empty")
    if not pw:
        raise KdbxSecretError("password must be non-empty")
    data = _load(path)
    data[fid] = pw
    return _save(data, path)


def delete_password(file_id: str, path: Path | None = None) -> bool:
    data = _load(path)
    if file_id.strip() not in data:
        return False
    del data[file_id.strip()]
    _save(data, path)
    return True


def has_password(file_id: str, path: Path | None = None) -> bool:
    return get_password(file_id, path) is not None
