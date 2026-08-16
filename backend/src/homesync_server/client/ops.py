"""Catalog operations that mirror phone pin / ingest / browse flows."""

from __future__ import annotations

import json
import mimetypes
import os
import re
from pathlib import Path
from uuid import UUID

from homesync_server.client.api import ApiError, HomesyncClient
from homesync_server.client.config import (
    ClientSettings,
    default_pin_dir,
    save_client_settings,
)
from homesync_server.config import DEFAULT_HASH_ALGO
from homesync_server.schemas.catalog import FileOut
from homesync_server.storage import hash_file

_UUID_RE = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)


class ResolveError(ValueError):
    pass


def pin_map_path() -> Path:
    override = os.environ.get("HOMESYNC_PIN_MAP")
    if override:
        return Path(override).expanduser().resolve()
    xdg = os.environ.get("XDG_DATA_HOME")
    base = Path(xdg).expanduser() if xdg else Path.home() / ".local" / "share"
    return (base / "homesync-client" / "pins.json").resolve()


def load_pin_map(path: Path | None = None) -> dict[str, str]:
    p = path if path is not None else pin_map_path()
    if not p.is_file():
        return {}
    raw = json.loads(p.read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        return {}
    pins = raw.get("pins", raw)
    if not isinstance(pins, dict):
        return {}
    return {str(k): str(v) for k, v in pins.items() if k and v}


def save_pin_map(pins: dict[str, str], path: Path | None = None) -> Path:
    p = path if path is not None else pin_map_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps({"pins": pins}, indent=2) + "\n", encoding="utf-8")
    return p


def unique_dest(directory: Path, name: str, *, overwrite: bool = False) -> Path:
    dest = directory / name
    if overwrite or not dest.exists():
        return dest
    stem, suffix = dest.stem, dest.suffix
    n = 1
    while True:
        cand = dest.with_name(f"{stem} ({n}){suffix}")
        if not cand.exists():
            return cand
        n += 1


def is_file_id(spec: str) -> bool:
    if not _UUID_RE.match(spec.strip()):
        return False
    try:
        UUID(spec.strip())
    except ValueError:
        return False
    return True


def resolve_file(client: HomesyncClient, spec: str) -> FileOut:
    raw = spec.strip()
    if is_file_id(raw):
        return client.get_file(raw)
    matches = client.list_files(q=raw, limit=50)
    exact = [f for f in matches if (f.title or "") == raw]
    pool = exact or [f for f in matches if (f.title or "").startswith(raw)]
    if len(pool) == 1:
        return pool[0]
    if not pool:
        raise ResolveError(f"no catalog file matching {raw!r}")
    titles = ", ".join((f.title or f.file_id) for f in pool[:8])
    raise ResolveError(f"ambiguous {raw!r}; matches: {titles}")


def ensure_registered(
    client: HomesyncClient,
    settings: ClientSettings,
    *,
    persist: bool = True,
) -> ClientSettings:
    from homesync_server.client.config import default_device_name, ensure_device_id

    updated, minted = ensure_device_id(settings)
    name = updated.device_name or default_device_name()
    assert updated.device_id is not None
    client.register_device(updated.device_id, name, kind="linux")
    if persist and (minted or settings.device_name != name):
        named = ClientSettings(
            base_url=updated.base_url,
            device_id=updated.device_id,
            device_name=name,
            pin_dir=updated.pin_dir,
        )
        save_client_settings(named)
        return named
    return updated


def pin_file(
    client: HomesyncClient,
    settings: ClientSettings,
    file: FileOut,
    *,
    directory: Path | None = None,
    file_name: str | None = None,
    overwrite: bool = False,
) -> Path:
    """Pin = availability update and blob materialization (same as the phone)."""
    device_id = settings.device_id
    if not device_id:
        raise ResolveError("device_id missing; run homesync init")
    pins = load_pin_map()
    existing = pins.get(file.file_id)
    if existing and Path(existing).is_file():
        client.put_availability(file.file_id, device_id, "pinned")
        return Path(existing)

    dest_dir = directory or settings.pin_dir or default_pin_dir()
    dest_dir.mkdir(parents=True, exist_ok=True)
    name = file_name or (file.title or file.file_id)
    dest = unique_dest(dest_dir, name, overwrite=overwrite)
    tmp = dest.with_name(dest.name + ".part")
    try:
        client.put_availability(file.file_id, device_id, "pinned")
        client.download_blob(file.hash_algo, file.content_hash, tmp)
        tmp.replace(dest)
    except Exception:
        tmp.unlink(missing_ok=True)
        try:
            client.put_availability(file.file_id, device_id, "listed")
        except ApiError:
            pass
        raise
    pins[file.file_id] = str(dest)
    save_pin_map(pins)
    return dest


def unpin_file(
    client: HomesyncClient,
    settings: ClientSettings,
    file: FileOut,
    *,
    delete_local: bool = True,
) -> None:
    device_id = settings.device_id
    if not device_id:
        raise ResolveError("device_id missing; run homesync init")
    client.put_availability(file.file_id, device_id, "listed")
    pins = load_pin_map()
    path = pins.pop(file.file_id, None)
    save_pin_map(pins)
    if delete_local and path:
        Path(path).unlink(missing_ok=True)


def ingest_path(
    client: HomesyncClient,
    settings: ClientSettings,
    path: Path,
    *,
    source_kind: str = "manual",
    relative_path: str | None = None,
    title: str | None = None,
) -> FileOut:
    device_id = settings.device_id
    if not device_id:
        raise ResolveError("device_id missing; run homesync init")
    resolved = path.expanduser().resolve()
    if not resolved.is_file():
        raise ResolveError(f"not a file: {path}")
    digest = hash_file(resolved)
    size = resolved.stat().st_size
    mime, _ = mimetypes.guess_type(str(resolved))
    client.upload_blob(resolved, algo=DEFAULT_HASH_ALGO, content_hash=digest)
    created = client.create_file(
        {
            "content_hash": digest,
            "hash_algo": DEFAULT_HASH_ALGO,
            "size_bytes": size,
            "mime_type": mime,
            "title": title or resolved.name,
            "source_kind": source_kind,
            "source_device_id": device_id,
            "relative_path": relative_path or resolved.name,
        }
    )
    # Bytes already on this machine — pin without a second copy (phone origin path).
    client.put_availability(created.file_id, device_id, "pinned")
    pins = load_pin_map()
    pins[created.file_id] = str(resolved)
    save_pin_map(pins)
    return created


def iter_walk_files(root: Path) -> list[Path]:
    files: list[Path] = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if not d.startswith(".")]
        for name in filenames:
            if name.startswith("."):
                continue
            files.append(Path(dirpath) / name)
    files.sort()
    return files


def path_under_prefix(relative_path: str, prefix: str) -> bool:
    norm = relative_path.replace("\\", "/").lstrip("/")
    pre = prefix.replace("\\", "/").strip("/")
    if not pre:
        return True
    return norm == pre or norm.startswith(pre + "/")


def files_under_prefix(client: HomesyncClient, prefix: str) -> list[FileOut]:
    by_id: dict[str, FileOut] = {}
    matching: set[str] = set()
    since: str | None = None
    while True:
        page = client.catalog_delta(since=since, limit=500)
        for row in page.files:
            if row.deleted_at is None:
                by_id[row.file_id] = row
        for path in page.paths:
            if path.is_current and path.gone_at is None and path_under_prefix(
                path.relative_path, prefix
            ):
                matching.add(path.file_id)
        if not page.files:
            break
        if page.next_cursor == since:
            break
        since = page.next_cursor
    return [by_id[fid] for fid in matching if fid in by_id]
