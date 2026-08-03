"""Semantic KeePass database comparison (ported from ~/t/diffkpdb.py).

Compares entry fields (title/username/password/url/notes) and group paths.
Entry timestamps alone do not count as a real conflict — empty field-diff
means ``trivial`` (byte hashes may still differ).
"""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import StrEnum
from pathlib import Path
from typing import Any

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

    @property
    def identity(self) -> str:
        return f"{self.group_path}/{self.title}"


@dataclass
class SemanticDiffResult:
    classification: DiffClassification
    removed_groups: list[str] = field(default_factory=list)
    added_groups: list[str] = field(default_factory=list)
    removed_entries: list[str] = field(default_factory=list)
    added_entries: list[str] = field(default_factory=list)
    # identity -> list of field names that changed (never values)
    modified_fields: dict[str, list[str]] = field(default_factory=dict)
    error: str | None = None

    @property
    def is_trivial(self) -> bool:
        return self.classification == DiffClassification.trivial

    def redacted_summary(self) -> dict[str, Any]:
        """JSON-safe summary safe to store/show (no secrets)."""
        return {
            "classification": self.classification.value,
            "removed_groups": list(self.removed_groups),
            "added_groups": list(self.added_groups),
            "removed_entries": list(self.removed_entries),
            "added_entries": list(self.added_entries),
            "modified_entries": [
                {"identity": ident, "fields": fields}
                for ident, fields in sorted(self.modified_fields.items())
            ],
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
        )
        result[data.identity] = data
    for subgroup in group.subgroups:
        collect_entries(subgroup, result)


def collect_groups(group: Any, result: set[str]) -> None:
    result.add(build_group_path(group))
    for subgroup in group.subgroups:
        collect_groups(subgroup, result)


def _open(path: Path, password: str) -> PyKeePass:
    try:
        return PyKeePass(str(path), password=password)
    except Exception as exc:  # pykeepass raises CredentialsError / others
        raise KdbxUnlockError(f"failed to open {path.name}: {exc}") from exc


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
        groups1: set[str] = set()
        groups2: set[str] = set()

        collect_entries(kp1.root_group, entries1)
        collect_entries(kp2.root_group, entries2)
        collect_groups(kp1.root_group, groups1)
        collect_groups(kp2.root_group, groups2)

        removed_groups = sorted(groups1 - groups2)
        added_groups = sorted(groups2 - groups1)

        keys1 = set(entries1.keys())
        keys2 = set(entries2.keys())
        removed_entries = sorted(keys1 - keys2)
        added_entries = sorted(keys2 - keys1)

        modified_fields: dict[str, list[str]] = {}
        for key in sorted(keys1 & keys2):
            e1 = entries1[key]
            e2 = entries2[key]
            changes: list[str] = []
            if e1.username != e2.username:
                changes.append("username")
            if e1.password != e2.password:
                changes.append("password")
            if e1.url != e2.url:
                changes.append("url")
            if e1.notes != e2.notes:
                changes.append("notes")
            if changes:
                modified_fields[key] = changes

        has_real = bool(
            removed_groups
            or added_groups
            or removed_entries
            or added_entries
            or modified_fields
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
        )
    except Exception as exc:
        return SemanticDiffResult(
            classification=DiffClassification.parse_failed,
            error=str(exc),
        )
