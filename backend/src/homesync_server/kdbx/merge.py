"""Two-way KeePass vault merge: union entries, LWW fields/location by mtime.

Does not apply deletions. Callers must only invoke when ``SemanticDiffResult.is_auto_mergeable``
(incoming retains every head entry UUID; moves/adds/edits are OK).
"""

from __future__ import annotations

import shutil
from datetime import UTC, datetime
from pathlib import Path
from typing import Any
from uuid import UUID

from pykeepass import PyKeePass

from homesync_server.kdbx.diff import (
    EntryData,
    KdbxDiffError,
    KdbxUnlockError,
    build_group_path,
    collect_entries_by_uuid,
    normalize,
)


def _open(path: Path, password: str) -> PyKeePass:
    try:
        return PyKeePass(str(path), password=password)
    except Exception as exc:
        raise KdbxUnlockError(f"failed to open {path.name}: {exc}") from exc


def _mtime_key(value: datetime | None) -> datetime:
    if value is None:
        return datetime.min.replace(tzinfo=UTC)
    if value.tzinfo is None:
        return value.replace(tzinfo=UTC)
    return value


def _prefer_b(a: EntryData, b: EntryData) -> bool:
    """True if B wins last-write-wins (newer mtime; tie → B / incoming)."""
    return _mtime_key(b.mtime) >= _mtime_key(a.mtime)


def _group_path_segments(group_path: str) -> list[str]:
    parts = [p for p in group_path.split("/") if p]
    # pykeepass root is typically named "Root"; path includes it.
    if parts and parts[0].lower() == "root":
        parts = parts[1:]
    return parts


def ensure_group_path(kp: PyKeePass, group_path: str) -> Any:
    """Create nested groups under root for ``group_path``; return leaf group."""
    current = kp.root_group
    for name in _group_path_segments(group_path):
        found = None
        for sub in current.subgroups:
            if normalize(sub.name) == name:
                found = sub
                break
        if found is None:
            found = kp.add_group(current, name)
        current = found
    return current


def _apply_fields(entry: Any, src: EntryData) -> None:
    entry.title = src.title
    entry.username = src.username
    entry.password = src.password
    entry.url = src.url
    entry.notes = src.notes
    if src.mtime is not None:
        entry.mtime = src.mtime


def _copy_entry(kp: PyKeePass, src_entry: Any, dest_group: Any) -> Any:
    """Add entry into ``kp`` preserving UUID and core fields."""
    new_e = kp.add_entry(
        dest_group,
        normalize(src_entry.title) or "untitled",
        normalize(src_entry.username),
        src_entry.password or "",
        url=src_entry.url,
        notes=src_entry.notes,
        tags=src_entry.tags,
        otp=src_entry.otp,
        icon=src_entry.icon,
        force_creation=True,
    )
    new_e.uuid = src_entry.uuid
    if src_entry.ctime is not None:
        new_e.ctime = src_entry.ctime
    if src_entry.mtime is not None:
        new_e.mtime = src_entry.mtime
    if src_entry.atime is not None:
        new_e.atime = src_entry.atime
    return new_e


def _find_entry_uuid(kp: PyKeePass, entry_uuid: UUID) -> Any | None:
    return kp.find_entries(uuid=entry_uuid, first=True)


def merge_kdbx_paths(
    path_a: Path,
    path_b: Path,
    *,
    password: str,
    dest: Path,
) -> Path:
    """Merge B into a copy of A; write result to ``dest``.

    - Entries only in B are copied in.
    - Shared UUIDs: fields + location from the side with newer ``mtime`` (tie → B).
    - Entries only in A are kept (caller should ensure B did not delete any).
    """
    kp_a = _open(path_a, password)
    kp_b = _open(path_b, password)

    by_a: dict[str, EntryData] = {}
    by_b: dict[str, EntryData] = {}
    collect_entries_by_uuid(kp_a.root_group, by_a)
    collect_entries_by_uuid(kp_b.root_group, by_b)

    # Work on a byte copy of A so we preserve history/binaries/settings.
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(path_a, dest)
    try:
        kp = _open(dest, password)
    except KdbxUnlockError as exc:
        dest.unlink(missing_ok=True)
        raise KdbxDiffError(str(exc)) from exc

    try:
        for ukey, data_b in by_b.items():
            if data_b.entry_uuid is None:
                continue
            raw_b = _find_entry_uuid(kp_b, data_b.entry_uuid)
            if raw_b is None:
                continue

            if ukey not in by_a:
                dest_group = ensure_group_path(kp, data_b.group_path)
                _copy_entry(kp, raw_b, dest_group)
                continue

            data_a = by_a[ukey]
            existing = _find_entry_uuid(kp, data_b.entry_uuid)
            if existing is None:
                dest_group = ensure_group_path(kp, data_b.group_path)
                _copy_entry(kp, raw_b, dest_group)
                continue

            # Started from A; only rewrite when B wins LWW.
            if not _prefer_b(data_a, data_b):
                continue

            if data_b.group_path != build_group_path(existing.group):
                dest_group = ensure_group_path(kp, data_b.group_path)
                kp.move_entry(existing, dest_group)
            _apply_fields(existing, data_b)

        kp.save()
    except Exception as exc:
        dest.unlink(missing_ok=True)
        raise KdbxDiffError(f"merge failed: {exc}") from exc

    return dest
