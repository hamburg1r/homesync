"""Semantic KeePass database comparison (ported from ~/t/diffkpdb.py).

Compares entry fields (title/username/password/url/notes) and group paths.
Entry identity for merge/conflict decisions is KeePass UUID (moves keep UUID).
Path+title identity is still used for the redacted trivial/real summary.

Entry timestamps alone do not count as a real conflict — empty field-diff
means ``trivial`` (byte hashes may still differ).
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from enum import StrEnum
from pathlib import Path
from typing import Any
from uuid import UUID

from pykeepass import PyKeePass


class DiffClassification(StrEnum):
    trivial = "trivial"
    real = "real"
    unlock_failed = "unlock_failed"
    parse_failed = "parse_failed"


class KdbxUnlockError(Exception):
    """Could not open a .kdbx with the provided password."""


class KdbxDiffError(Exception):
    """Diff failed for a non-unlock reason."""


@dataclass(frozen=True)
class EntryData:
    group_path: str
    title: str
    username: str
    password: str
    url: str
    notes: str
    entry_uuid: UUID | None = None
    mtime: datetime | None = None

    @property
    def identity(self) -> str:
        return f"{self.group_path}/{self.title}"

    @property
    def uuid_key(self) -> str:
        if self.entry_uuid is None:
            return f"path:{self.identity}"
        return str(self.entry_uuid)


@dataclass
class SemanticDiffResult:
    classification: DiffClassification
    removed_groups: list[str] = field(default_factory=list)
    added_groups: list[str] = field(default_factory=list)
    removed_entries: list[str] = field(default_factory=list)
    added_entries: list[str] = field(default_factory=list)
    # identity -> list of field names that changed (never values)
    modified_fields: dict[str, list[str]] = field(default_factory=dict)
    # Stable per-entry rows for clients (uuid + identity + fields).
    modified_entry_details: list[dict[str, Any]] = field(default_factory=list)
    moved_entries: list[dict[str, str]] = field(default_factory=list)
    # UUID keys present in A but not B (true removals from B's perspective)
    removed_entry_uuids: list[str] = field(default_factory=list)
    added_entry_uuids: list[str] = field(default_factory=list)
    error: str | None = None

    @property
    def is_trivial(self) -> bool:
        return self.classification == DiffClassification.trivial

    @property
    def is_auto_mergeable(self) -> bool:
        """True when incoming did not drop any entry UUID (adds/moves/edits OK).

        Path-only ``removed_entries`` that are explained as moves do not block.
        True deletions (UUID in head, absent in incoming) open the outbox.
        """
        if self.classification in (
            DiffClassification.unlock_failed,
            DiffClassification.parse_failed,
        ):
            return False
        if self.is_trivial:
            return True
        return not self.removed_entry_uuids

    def redacted_summary(self) -> dict[str, Any]:
        """JSON-safe summary safe to store/show (no secrets)."""
        modified = list(self.modified_entry_details)
        if not modified and self.modified_fields:
            # Back-compat for callers that only fill modified_fields.
            modified = [
                {"uuid": None, "identity": ident, "fields": fields}
                for ident, fields in sorted(self.modified_fields.items())
            ]
        return {
            "classification": self.classification.value,
            "removed_groups": list(self.removed_groups),
            "added_groups": list(self.added_groups),
            "removed_entries": list(self.removed_entries),
            "added_entries": list(self.added_entries),
            "moved_entries": list(self.moved_entries),
            "modified_entries": modified,
            "removed_entry_uuids": list(self.removed_entry_uuids),
            "added_entry_uuids": list(self.added_entry_uuids),
            "auto_mergeable": self.is_auto_mergeable,
            "error": self.error,
        }


def is_kdbx_file(
    *,
    title: str | None = None,
    mime_type: str | None = None,
    relative_path: str | None = None,
) -> bool:
    """Heuristic: treat as KeePass vault for conflict outbox behavior."""
    mime = (mime_type or "").strip().lower()
    if "keepass" in mime or mime in {
        "application/x-keepass",
        "application/x-keepass2",
    }:
        return True
    for name in (title, relative_path):
        if name and name.strip().lower().endswith(".kdbx"):
            return True
    return False


def normalize(value: str | None) -> str:
    return (value or "").strip()


def build_group_path(group: Any) -> str:
    parts: list[str] = []
    current = group
    while current is not None:
        name = normalize(current.name)
        if name:
            parts.append(name)
        current = current.parentgroup
    return "/".join(reversed(parts))


def collect_entries(group: Any, result: dict[str, EntryData]) -> None:
    """Collect by path/title identity (legacy summary keys)."""
    group_path = build_group_path(group)
    for entry in group.entries:
        title = normalize(entry.title)
        data = EntryData(
            group_path=group_path,
            title=title,
            username=normalize(entry.username),
            password=normalize(entry.password),
            url=normalize(entry.url),
            notes=normalize(entry.notes),
            entry_uuid=entry.uuid,
            mtime=entry.mtime,
        )
        result[data.identity] = data
    for subgroup in group.subgroups:
        collect_entries(subgroup, result)


def collect_entries_by_uuid(group: Any, result: dict[str, EntryData]) -> None:
    """Collect by KeePass entry UUID (stable across moves)."""
    group_path = build_group_path(group)
    for entry in group.entries:
        title = normalize(entry.title)
        data = EntryData(
            group_path=group_path,
            title=title,
            username=normalize(entry.username),
            password=normalize(entry.password),
            url=normalize(entry.url),
            notes=normalize(entry.notes),
            entry_uuid=entry.uuid,
            mtime=entry.mtime,
        )
        result[data.uuid_key] = data
    for subgroup in group.subgroups:
        collect_entries_by_uuid(subgroup, result)


def collect_groups(group: Any, result: set[str]) -> None:
    result.add(build_group_path(group))
    for subgroup in group.subgroups:
        collect_groups(subgroup, result)


def _open(path: Path, password: str) -> PyKeePass:
    try:
        return PyKeePass(str(path), password=password)
    except Exception as exc:  # pykeepass raises CredentialsError / others
        raise KdbxUnlockError(f"failed to open {path.name}: {exc}") from exc


def _field_changes(e1: EntryData, e2: EntryData) -> list[str]:
    changes: list[str] = []
    if e1.username != e2.username:
        changes.append("username")
    if e1.password != e2.password:
        changes.append("password")
    if e1.url != e2.url:
        changes.append("url")
    if e1.notes != e2.notes:
        changes.append("notes")
    if e1.title != e2.title:
        changes.append("title")
    return changes


def classify_kdbx_paths(
    path_a: Path,
    path_b: Path,
    *,
    password: str,
) -> SemanticDiffResult:
    """Compare two .kdbx files; return trivial vs real (redacted)."""
    try:
        kp1 = _open(path_a, password)
        kp2 = _open(path_b, password)
    except KdbxUnlockError as exc:
        return SemanticDiffResult(
            classification=DiffClassification.unlock_failed,
            error=str(exc),
        )

    try:
        entries1: dict[str, EntryData] = {}
        entries2: dict[str, EntryData] = {}
        by_uuid1: dict[str, EntryData] = {}
        by_uuid2: dict[str, EntryData] = {}
        groups1: set[str] = set()
        groups2: set[str] = set()

        collect_entries(kp1.root_group, entries1)
        collect_entries(kp2.root_group, entries2)
        collect_entries_by_uuid(kp1.root_group, by_uuid1)
        collect_entries_by_uuid(kp2.root_group, by_uuid2)
        collect_groups(kp1.root_group, groups1)
        collect_groups(kp2.root_group, groups2)

        removed_groups = sorted(groups1 - groups2)
        added_groups = sorted(groups2 - groups1)

        keys1 = set(entries1.keys())
        keys2 = set(entries2.keys())
        removed_entries = sorted(keys1 - keys2)
        added_entries = sorted(keys2 - keys1)

        uuids1 = set(by_uuid1.keys())
        uuids2 = set(by_uuid2.keys())
        removed_uuids = sorted(uuids1 - uuids2)
        added_uuids = sorted(uuids2 - uuids1)

        moved_entries: list[dict[str, str]] = []
        move_old_paths: set[str] = set()
        move_new_paths: set[str] = set()
        for ukey in sorted(uuids1 & uuids2):
            e1 = by_uuid1[ukey]
            e2 = by_uuid2[ukey]
            if e1.group_path != e2.group_path or e1.title != e2.title:
                moved_entries.append(
                    {
                        "uuid": ukey,
                        "from": e1.identity,
                        "to": e2.identity,
                    }
                )
                move_old_paths.add(e1.identity)
                move_new_paths.add(e2.identity)

        # Path removals/adds explained by UUID moves are not true deletions.
        removed_entries = sorted(
            p for p in removed_entries if p not in move_old_paths
        )
        added_entries = sorted(p for p in added_entries if p not in move_new_paths)

        modified_fields: dict[str, list[str]] = {}
        modified_entry_details: list[dict[str, Any]] = []
        seen_mod_idents: set[str] = set()
        for ukey in sorted(uuids1 & uuids2):
            e1 = by_uuid1[ukey]
            e2 = by_uuid2[ukey]
            changes = _field_changes(e1, e2)
            if changes:
                # Prefer path identity from A for summary stability.
                modified_fields[e1.identity] = changes
                modified_entry_details.append(
                    {"uuid": ukey, "identity": e1.identity, "fields": changes}
                )
                seen_mod_idents.add(e1.identity)

        # Path-key field diffs when both sides share a path identity (covers
        # independently created DBs that collide on title but not UUID).
        for key in sorted(keys1 & keys2):
            if key in seen_mod_idents:
                continue
            changes = _field_changes(entries1[key], entries2[key])
            if changes:
                modified_fields[key] = changes
                e1 = entries1[key]
                uuid_val = str(e1.entry_uuid) if e1.entry_uuid is not None else None
                modified_entry_details.append(
                    {"uuid": uuid_val, "identity": key, "fields": changes}
                )

        has_real = bool(
            removed_groups
            or added_groups
            or removed_entries
            or added_entries
            or modified_fields
            or moved_entries
        )
        return SemanticDiffResult(
            classification=(
                DiffClassification.real if has_real else DiffClassification.trivial
            ),
            removed_groups=removed_groups,
            added_groups=added_groups,
            removed_entries=removed_entries,
            added_entries=added_entries,
            modified_fields=modified_fields,
            modified_entry_details=modified_entry_details,
            moved_entries=moved_entries,
            removed_entry_uuids=removed_uuids,
            added_entry_uuids=added_uuids,
        )
    except Exception as exc:  # noqa: BLE001 — pykeepass/parse errors vary
        return SemanticDiffResult(
            classification=DiffClassification.parse_failed,
            error=str(exc),
        )
