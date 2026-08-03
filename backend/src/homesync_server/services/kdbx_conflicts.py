"""KeePass conflict outbox: keep divergent heads, auto-merge, phone resolve."""

from __future__ import annotations

import json
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session, selectinload

from homesync_server.kdbx import secrets as kdbx_secrets
from homesync_server.kdbx.diff import (
    DiffClassification,
    SemanticDiffResult,
    classify_kdbx_paths,
    is_kdbx_file,
)
from homesync_server.kdbx.merge import merge_kdbx_paths, merge_kdbx_with_choices
from homesync_server.models import File, FilePath, FileVersion, KdbxConflict, KdbxConflictCandidate
from homesync_server.schemas.catalog import (
    FileOut,
    KdbxConflictCandidateOut,
    KdbxConflictOut,
    KdbxContentResult,
)
from homesync_server.services import blobs as blob_svc
from homesync_server.services import catalog as catalog_svc
from homesync_server.storage import blob_path, hash_bytes
from homesync_server.util import new_uuid, next_updated_at, utc_now_iso


class ConflictNotFoundError(Exception):
    pass


class ConflictValidationError(Exception):
    pass


class ConflictStaleError(Exception):
    """Choices or candidate no longer match the conflict (HTTP 409)."""


@dataclass(frozen=True)
class ContentOutcome:
    """Result of a kdbx-aware (or normal) content update."""

    kind: str  # "file" | "conflict"
    file: File | None = None
    conflict: KdbxConflict | None = None


def _file_looks_kdbx(session: Session, file_row: File) -> bool:
    if is_kdbx_file(title=file_row.title, mime_type=file_row.mime_type):
        return True
    paths = list(
        session.scalars(
            select(FilePath).where(FilePath.file_id == file_row.file_id).limit(5)
        ).all()
    )
    return any(is_kdbx_file(relative_path=p.relative_path) for p in paths)


def conflict_to_out(row: KdbxConflict) -> KdbxConflictOut:
    summary: dict[str, Any] | None = None
    if row.diff_summary_json:
        try:
            summary = json.loads(row.diff_summary_json)
        except json.JSONDecodeError:
            summary = {"error": "invalid stored summary"}
    cands = sorted(row.candidates, key=lambda c: (c.created_at, c.id))
    return KdbxConflictOut(
        conflict_id=row.conflict_id,
        file_id=row.file_id,
        state=row.state,
        created_at=row.created_at,
        updated_at=row.updated_at,
        diff_summary=summary,
        resolved_content_hash=row.resolved_content_hash,
        candidates=[
            KdbxConflictCandidateOut(
                content_hash=c.content_hash,
                size_bytes=c.size_bytes,
                source_device_id=c.source_device_id,
                role=c.role,
                created_at=c.created_at,
            )
            for c in cands
        ],
    )


def get_conflict(session: Session, conflict_id: str) -> KdbxConflict:
    row = session.scalars(
        select(KdbxConflict)
        .where(KdbxConflict.conflict_id == conflict_id)
        .options(selectinload(KdbxConflict.candidates))
    ).first()
    if row is None:
        raise ConflictNotFoundError(conflict_id)
    return row


def list_conflicts(
    session: Session,
    *,
    state: str | None = "active",
    limit: int = 100,
) -> list[KdbxConflict]:
    """List conflicts.

    ``state=active`` (default) = unresolved outbox rows
    (``open`` | ``needs_secret`` | ``diff_failed``).
    Pass an exact state string for a single status, or ``None`` for all rows.
    """
    stmt = (
        select(KdbxConflict)
        .options(selectinload(KdbxConflict.candidates))
        .order_by(KdbxConflict.updated_at.desc())
        .limit(limit)
    )
    if state == "active":
        stmt = stmt.where(
            KdbxConflict.state.in_(("open", "needs_secret", "diff_failed"))
        )
    elif state:
        stmt = stmt.where(KdbxConflict.state == state)
    return list(session.scalars(stmt).all())


def open_conflict_for_file(session: Session, file_id: str) -> KdbxConflict | None:
    return session.scalars(
        select(KdbxConflict)
        .where(
            KdbxConflict.file_id == file_id,
            KdbxConflict.state.in_(("open", "needs_secret", "diff_failed")),
        )
        .options(selectinload(KdbxConflict.candidates))
        .order_by(KdbxConflict.updated_at.desc())
        .limit(1)
    ).first()


def _add_candidate(
    session: Session,
    conflict: KdbxConflict,
    *,
    content_hash: str,
    size_bytes: int,
    role: str,
    source_device_id: str | None,
) -> None:
    existing = session.scalars(
        select(KdbxConflictCandidate).where(
            KdbxConflictCandidate.conflict_id == conflict.conflict_id,
            KdbxConflictCandidate.content_hash == content_hash,
        )
    ).first()
    if existing is not None:
        return
    session.add(
        KdbxConflictCandidate(
            id=new_uuid(),
            conflict_id=conflict.conflict_id,
            content_hash=content_hash,
            size_bytes=size_bytes,
            source_device_id=source_device_id,
            role=role,
            created_at=utc_now_iso(),
        )
    )


def _ensure_blob(
    data_root: Path,
    algo: str,
    digest: str,
    size_bytes: int,
) -> None:
    if not blob_svc.managed_blob_exists(data_root, algo, digest):
        raise catalog_svc.IngestValidationError(
            "blob not present in managed store; PUT /v1/blobs first"
        )
    from homesync_server.storage import blob_path

    on_disk = blob_path(data_root, algo, digest)
    actual = on_disk.stat().st_size
    if actual != size_bytes:
        raise catalog_svc.IngestValidationError(
            f"size_bytes mismatch: body claims {size_bytes}, on disk {actual}"
        )


def _run_diff(
    data_root: Path,
    algo: str,
    hash_a: str,
    hash_b: str,
    password: str,
) -> SemanticDiffResult:
    from homesync_server.storage import blob_path

    path_a = blob_path(data_root, algo, hash_a)
    path_b = blob_path(data_root, algo, hash_b)
    return classify_kdbx_paths(path_a, path_b, password=password)


def _build_merged_blob(
    data_root: Path,
    algo: str,
    hash_a: str,
    hash_b: str,
    password: str,
) -> tuple[str, int]:
    """Merge A+B into managed store; return (digest, size_bytes)."""
    from homesync_server.storage import blob_path

    path_a = blob_path(data_root, algo, hash_a)
    path_b = blob_path(data_root, algo, hash_b)
    with tempfile.TemporaryDirectory(prefix="homesync-kdbx-merge-") as tmp:
        dest = Path(tmp) / "merged.kdbx"
        merge_kdbx_paths(path_a, path_b, password=password, dest=dest)
        body = dest.read_bytes()
    digest = hash_bytes(body, algo=algo)
    blob_svc.put_blob_bytes(data_root, algo, digest, body)
    return digest, len(body)


def _archive_hash(
    session: Session,
    file_id: str,
    *,
    content_hash: str,
    size_bytes: int,
    note: str,
    seen: set[str],
) -> None:
    if content_hash in seen:
        return
    session.add(
        FileVersion(
            version_id=new_uuid(),
            file_id=file_id,
            content_hash=content_hash,
            size_bytes=size_bytes,
            created_at=utc_now_iso(),
            note=note,
        )
    )
    seen.add(content_hash)


def _promote_merged_head(
    session: Session,
    data_root: Path,
    file_row: File,
    *,
    algo: str,
    merged_hash: str,
    merged_size: int,
    archive: list[tuple[str, int, str]],
    note: str,
) -> File:
    """Set merged blob as head; archive prior hashes into versions."""
    previous_head = catalog_svc._stored_head_hash(file_row.content_hash)
    seen: set[str] = {merged_hash}
    if previous_head != merged_hash:
        _archive_hash(
            session,
            file_row.file_id,
            content_hash=previous_head,
            size_bytes=file_row.size_bytes,
            note=note or "pre-merge head",
            seen=seen,
        )
    for h, size, n in archive:
        _archive_hash(
            session,
            file_row.file_id,
            content_hash=h,
            size_bytes=size,
            note=n,
            seen=seen,
        )

    other = session.scalars(
        select(File).where(
            File.content_hash == merged_hash,
            File.hash_algo == algo,
            File.file_id != file_row.file_id,
        )
    ).first()
    if other is not None:
        if other.deleted_at is not None:
            catalog_svc._free_tombstone_hash(session, other)
        else:
            raise catalog_svc.CatalogConflictError(other)

    file_row.content_hash = merged_hash
    file_row.size_bytes = merged_size
    file_row.updated_at = next_updated_at(file_row.updated_at)
    from homesync_server.db import ensure_local_device
    from homesync_server.services import availability as avail_svc

    linux = ensure_local_device(session)
    avail_svc.set_availability(
        session, file_row.file_id, linux.device_id, mode="pinned"
    )
    session.flush()
    return catalog_svc.get_file(session, file_row.file_id)


def _auto_merge_and_promote(
    session: Session,
    data_root: Path,
    file_row: File,
    *,
    algo: str,
    head_hash: str,
    incoming_hash: str,
    incoming_size: int,
    password: str,
    note: str | None,
    conflict: KdbxConflict | None = None,
) -> ContentOutcome:
    """Union-merge head+incoming (LWW), promote result, optionally close outbox."""
    merged_hash, merged_size = _build_merged_blob(
        data_root, algo, head_hash, incoming_hash, password
    )
    updated = _promote_merged_head(
        session,
        data_root,
        file_row,
        algo=algo,
        merged_hash=merged_hash,
        merged_size=merged_size,
        archive=[
            (incoming_hash, incoming_size, note or "kdbx merge candidate"),
        ],
        note=note or "kdbx auto-merge",
    )
    if conflict is not None:
        conflict.state = "resolved"
        conflict.resolved_content_hash = merged_hash
        conflict.updated_at = next_updated_at(conflict.updated_at)
        conflict.diff_summary_json = json.dumps(
            {
                "classification": "real",
                "auto_merged": True,
                "resolved_content_hash": merged_hash,
            }
        )
        session.flush()
    return ContentOutcome(kind="file", file=updated)


def apply_kdbx_content(
    session: Session,
    data_root: Path,
    file_id: str,
    *,
    content_hash: str,
    hash_algo: str,
    size_bytes: int,
    note: str | None = None,
    source_device_id: str | None = None,
) -> ContentOutcome:
    """kdbx-aware content replace: trivial / auto-merge or open outbox.

    Non-kdbx files fall through to normal ``update_file_content``.
    """
    algo = hash_algo.strip().lower()
    digest = content_hash.strip().lower()
    row = catalog_svc.get_file(session, file_id)

    if not _file_looks_kdbx(session, row):
        updated = catalog_svc.update_file_content(
            session,
            data_root,
            file_id,
            content_hash=digest,
            hash_algo=algo,
            size_bytes=size_bytes,
            note=note,
        )
        return ContentOutcome(kind="file", file=updated)

    if row.deleted_at is not None:
        # Same revive policy as update_file_content / create_file dedup.
        row.deleted_at = None
        row.updated_at = next_updated_at(row.updated_at)
    if algo != row.hash_algo.strip().lower():
        raise catalog_svc.IngestValidationError(
            f"hash_algo mismatch: file uses {row.hash_algo}, got {algo}"
        )

    previous_head = catalog_svc._stored_head_hash(row.content_hash)
    if digest == previous_head:
        if size_bytes != row.size_bytes and not row.content_hash.startswith(
            "tombstone:"
        ):
            raise catalog_svc.IngestValidationError(
                f"size_bytes mismatch for current head: body claims {size_bytes}, "
                f"catalog has {row.size_bytes}"
            )
        if row.content_hash.startswith("tombstone:"):
            row.content_hash = digest
            row.size_bytes = size_bytes
            row.updated_at = next_updated_at(row.updated_at)
            session.flush()
        return ContentOutcome(kind="file", file=row)

    _ensure_blob(data_root, algo, digest, size_bytes)

    other = session.scalars(
        select(File).where(
            File.content_hash == digest,
            File.hash_algo == algo,
            File.file_id != file_id,
        )
    ).first()
    if other is not None:
        if other.deleted_at is not None:
            catalog_svc._free_tombstone_hash(session, other)
        else:
            raise catalog_svc.CatalogConflictError(other)

    # Also ensure current head is in managed store for diff (may be hash-in-place).
    head_hash = previous_head
    head_managed = blob_svc.managed_blob_exists(data_root, algo, head_hash)
    if not head_managed:
        # Try to copy from hash-in-place resolve if possible.
        try:
            src = blob_svc.resolve_blob_path(session, data_root, algo, head_hash)
            from homesync_server.storage import blob_path, write_blob_atomic

            dest = blob_path(data_root, algo, head_hash)
            dest.parent.mkdir(parents=True, exist_ok=True)
            write_blob_atomic(dest, src.read_bytes())
            head_managed = True
        except Exception:  # noqa: BLE001 — resolve_blob_path / IO may raise variously
            head_managed = False

    open_c = open_conflict_for_file(session, file_id)
    password = kdbx_secrets.get_password(file_id)

    if open_c is not None:
        # Extra candidate while conflict already open.
        _add_candidate(
            session,
            open_c,
            content_hash=digest,
            size_bytes=size_bytes,
            role="extra",
            source_device_id=source_device_id,
        )
        session.flush()
        open_c.updated_at = next_updated_at(open_c.updated_at)
        n_cands = len(
            list(
                session.scalars(
                    select(KdbxConflictCandidate).where(
                        KdbxConflictCandidate.conflict_id == open_c.conflict_id
                    )
                ).all()
            )
        )
        if password and head_managed:
            base = session.scalars(
                select(KdbxConflictCandidate).where(
                    KdbxConflictCandidate.conflict_id == open_c.conflict_id,
                    KdbxConflictCandidate.role == "base",
                )
            ).first()
            if base is not None:
                diff = _run_diff(
                    data_root, algo, base.content_hash, digest, password
                )
                open_c.diff_summary_json = json.dumps(diff.redacted_summary())
                if diff.classification == DiffClassification.unlock_failed:
                    open_c.state = "needs_secret"
                elif diff.classification == DiffClassification.parse_failed:
                    open_c.state = "diff_failed"
                elif diff.is_trivial and n_cands <= 2:
                    return _auto_resolve_trivial(
                        session,
                        data_root,
                        row,
                        open_c,
                        keep_hash=head_hash,
                        other_hash=digest,
                        other_size=size_bytes,
                        note=note or "trivial kdbx auto-resolve",
                    )
                elif diff.is_auto_mergeable and n_cands <= 2:
                    base_hash = base.content_hash
                    try:
                        return _auto_merge_and_promote(
                            session,
                            data_root,
                            row,
                            algo=algo,
                            head_hash=base_hash,
                            incoming_hash=digest,
                            incoming_size=size_bytes,
                            password=password,
                            note=note or "kdbx auto-merge",
                            conflict=open_c,
                        )
                    except Exception as exc:  # noqa: BLE001 — merge/IO; keep outbox
                        open_c.state = "diff_failed"
                        open_c.diff_summary_json = json.dumps(
                            {
                                "classification": "diff_failed",
                                "error": f"auto-merge failed: {exc}",
                            }
                        )
                else:
                    open_c.state = "open"
        elif not password:
            open_c.state = "needs_secret"
        session.flush()
        session.expire_all()
        return ContentOutcome(
            kind="conflict", conflict=get_conflict(session, open_c.conflict_id)
        )

    # No open conflict yet — classify head vs incoming.
    if not password:
        conflict = _create_conflict(
            session,
            file_row=row,
            incoming_hash=digest,
            incoming_size=size_bytes,
            source_device_id=source_device_id,
            state="needs_secret",
            summary={"classification": "needs_secret", "error": "vault secret not set"},
        )
        session.flush()
        return ContentOutcome(kind="conflict", conflict=get_conflict(session, conflict.conflict_id))

    if not head_managed:
        conflict = _create_conflict(
            session,
            file_row=row,
            incoming_hash=digest,
            incoming_size=size_bytes,
            source_device_id=source_device_id,
            state="diff_failed",
            summary={
                "classification": "diff_failed",
                "error": "current head blob not in managed store",
            },
        )
        session.flush()
        return ContentOutcome(kind="conflict", conflict=get_conflict(session, conflict.conflict_id))

    diff = _run_diff(data_root, algo, head_hash, digest, password)
    if diff.classification == DiffClassification.unlock_failed:
        conflict = _create_conflict(
            session,
            file_row=row,
            incoming_hash=digest,
            incoming_size=size_bytes,
            source_device_id=source_device_id,
            state="needs_secret",
            summary=diff.redacted_summary(),
        )
        session.flush()
        return ContentOutcome(kind="conflict", conflict=get_conflict(session, conflict.conflict_id))

    if diff.classification == DiffClassification.parse_failed:
        conflict = _create_conflict(
            session,
            file_row=row,
            incoming_hash=digest,
            incoming_size=size_bytes,
            source_device_id=source_device_id,
            state="diff_failed",
            summary=diff.redacted_summary(),
        )
        session.flush()
        return ContentOutcome(kind="conflict", conflict=get_conflict(session, conflict.conflict_id))

    if diff.is_trivial:
        # Auto-resolve: promote incoming as head (newer write), archive old.
        updated = catalog_svc.update_file_content(
            session,
            data_root,
            file_id,
            content_hash=digest,
            hash_algo=algo,
            size_bytes=size_bytes,
            note=note or "trivial kdbx auto-resolve",
        )
        return ContentOutcome(kind="file", file=updated)

    if diff.is_auto_mergeable:
        try:
            return _auto_merge_and_promote(
                session,
                data_root,
                row,
                algo=algo,
                head_hash=head_hash,
                incoming_hash=digest,
                incoming_size=size_bytes,
                password=password,
                note=note or "kdbx auto-merge",
                conflict=None,
            )
        except Exception as exc:  # noqa: BLE001 — merge/IO; open outbox
            conflict = _create_conflict(
                session,
                file_row=row,
                incoming_hash=digest,
                incoming_size=size_bytes,
                source_device_id=source_device_id,
                state="diff_failed",
                summary={
                    "classification": "diff_failed",
                    "error": f"auto-merge failed: {exc}",
                    **{
                        k: v
                        for k, v in diff.redacted_summary().items()
                        if k != "classification" and k != "error"
                    },
                },
            )
            session.flush()
            return ContentOutcome(
                kind="conflict", conflict=get_conflict(session, conflict.conflict_id)
            )

    conflict = _create_conflict(
        session,
        file_row=row,
        incoming_hash=digest,
        incoming_size=size_bytes,
        source_device_id=source_device_id,
        state="open",
        summary=diff.redacted_summary(),
    )
    session.flush()
    return ContentOutcome(kind="conflict", conflict=get_conflict(session, conflict.conflict_id))


def _create_conflict(
    session: Session,
    *,
    file_row: File,
    incoming_hash: str,
    incoming_size: int,
    source_device_id: str | None,
    state: str,
    summary: dict[str, Any],
) -> KdbxConflict:
    now = utc_now_iso()
    conflict = KdbxConflict(
        conflict_id=new_uuid(),
        file_id=file_row.file_id,
        state=state,
        created_at=now,
        updated_at=now,
        diff_summary_json=json.dumps(summary),
        resolved_content_hash=None,
    )
    session.add(conflict)
    session.flush()
    _add_candidate(
        session,
        conflict,
        content_hash=catalog_svc._stored_head_hash(file_row.content_hash),
        size_bytes=file_row.size_bytes,
        role="base",
        source_device_id=None,
    )
    _add_candidate(
        session,
        conflict,
        content_hash=incoming_hash,
        size_bytes=incoming_size,
        role="incoming",
        source_device_id=source_device_id,
    )
    return conflict


def _auto_resolve_trivial(
    session: Session,
    data_root: Path,
    file_row: File,
    conflict: KdbxConflict,
    *,
    keep_hash: str,
    other_hash: str,
    other_size: int,
    note: str,
) -> ContentOutcome:
    """Close conflict keeping catalog head; archive the other hash into versions."""
    _ = other_size
    if other_hash != file_row.content_hash:
        now = utc_now_iso()
        session.add(
            FileVersion(
                version_id=new_uuid(),
                file_id=file_row.file_id,
                content_hash=other_hash,
                size_bytes=other_size,
                created_at=now,
                note=note,
            )
        )
        # Head unchanged (keep_hash == current).
        _ = keep_hash
        file_row.updated_at = next_updated_at(file_row.updated_at)
    conflict.state = "resolved"
    conflict.resolved_content_hash = catalog_svc._stored_head_hash(
        file_row.content_hash
    )
    conflict.updated_at = next_updated_at(conflict.updated_at)
    conflict.diff_summary_json = json.dumps(
        {"classification": "trivial", "auto_resolved": True}
    )
    session.flush()
    return ContentOutcome(kind="file", file=catalog_svc.get_file(session, file_row.file_id))


def resolve_conflict(
    session: Session,
    data_root: Path,
    conflict_id: str,
    *,
    mode: str = "upload",
    content_hash: str | None = None,
    hash_algo: str = "blake3",
    size_bytes: int | None = None,
    note: str | None = None,
    base_hash: str | None = None,
    incoming_hash: str | None = None,
    choices: list[dict[str, str]] | None = None,
) -> File:
    """Close outbox by promoting a blob (upload / candidate) or choice-merge."""
    conflict = get_conflict(session, conflict_id)
    if conflict.state == "resolved":
        raise ConflictValidationError("conflict already resolved")

    mode_norm = mode.strip().lower()
    if mode_norm == "entries":
        return _resolve_by_entries(
            session,
            data_root,
            conflict,
            base_hash=base_hash,
            incoming_hash=incoming_hash,
            choices=choices or [],
            note=note,
        )
    if mode_norm == "candidate":
        if not content_hash or size_bytes is None:
            raise ConflictValidationError(
                "candidate resolve requires content_hash and size_bytes"
            )
        cand_hashes = {c.content_hash for c in conflict.candidates}
        digest = content_hash.strip().lower()
        if digest not in cand_hashes:
            raise ConflictStaleError(
                "content_hash is not a candidate of this conflict"
            )
        return _resolve_promote_blob(
            session,
            data_root,
            conflict,
            content_hash=digest,
            hash_algo=hash_algo,
            size_bytes=size_bytes,
            note=note,
        )
    # upload (legacy)
    if not content_hash or size_bytes is None:
        raise ConflictValidationError(
            "upload resolve requires content_hash and size_bytes"
        )
    return _resolve_promote_blob(
        session,
        data_root,
        conflict,
        content_hash=content_hash.strip().lower(),
        hash_algo=hash_algo,
        size_bytes=size_bytes,
        note=note,
    )


def _resolve_promote_blob(
    session: Session,
    data_root: Path,
    conflict: KdbxConflict,
    *,
    content_hash: str,
    hash_algo: str,
    size_bytes: int,
    note: str | None = None,
) -> File:
    """Upload-already-done: set AB as head, archive other candidates, close outbox."""
    algo = hash_algo.strip().lower()
    digest = content_hash.strip().lower()
    file_row = catalog_svc.get_file(session, conflict.file_id)

    if algo != file_row.hash_algo.strip().lower():
        raise ConflictValidationError(
            f"hash_algo mismatch: file uses {file_row.hash_algo}, got {algo}"
        )

    _ensure_blob(data_root, algo, digest, size_bytes)

    # Archive current head + all non-chosen candidates into versions.
    now = utc_now_iso()
    previous_head = catalog_svc._stored_head_hash(file_row.content_hash)
    seen_hashes = {digest}
    if previous_head not in seen_hashes:
        session.add(
            FileVersion(
                version_id=new_uuid(),
                file_id=file_row.file_id,
                content_hash=previous_head,
                size_bytes=file_row.size_bytes,
                created_at=now,
                note=note or "pre-resolve head",
            )
        )
        seen_hashes.add(previous_head)

    for cand in conflict.candidates:
        if cand.content_hash in seen_hashes:
            continue
        session.add(
            FileVersion(
                version_id=new_uuid(),
                file_id=file_row.file_id,
                content_hash=cand.content_hash,
                size_bytes=cand.size_bytes,
                created_at=now,
                note=note or f"conflict candidate ({cand.role})",
            )
        )
        seen_hashes.add(cand.content_hash)

    if digest != previous_head:
        other = session.scalars(
            select(File).where(
                File.content_hash == digest,
                File.hash_algo == algo,
                File.file_id != file_row.file_id,
            )
        ).first()
        if other is not None:
            if other.deleted_at is not None:
                catalog_svc._free_tombstone_hash(session, other)
            else:
                raise catalog_svc.CatalogConflictError(other)

        file_row.content_hash = digest
        file_row.size_bytes = size_bytes
        file_row.updated_at = next_updated_at(file_row.updated_at)
        from homesync_server.db import ensure_local_device
        from homesync_server.services import availability as avail_svc

        linux = ensure_local_device(session)
        avail_svc.set_availability(
            session, file_row.file_id, linux.device_id, mode="pinned"
        )
    else:
        if file_row.content_hash.startswith("tombstone:"):
            file_row.content_hash = digest
        file_row.updated_at = next_updated_at(file_row.updated_at)

    conflict.state = "resolved"
    conflict.resolved_content_hash = digest
    conflict.updated_at = next_updated_at(conflict.updated_at)
    session.flush()
    return catalog_svc.get_file(session, file_row.file_id)


def _resolve_by_entries(
    session: Session,
    data_root: Path,
    conflict: KdbxConflict,
    *,
    base_hash: str | None,
    incoming_hash: str | None,
    choices: list[dict[str, str]],
    note: str | None,
) -> File:
    file_row = catalog_svc.get_file(session, conflict.file_id)
    algo = file_row.hash_algo.strip().lower()
    password = kdbx_secrets.get_password(conflict.file_id)
    if not password:
        raise ConflictValidationError(
            "vault secret not set; PUT /v1/files/{id}/kdbx-secret first"
        )

    by_role = {c.role: c for c in conflict.candidates}
    extras = [c for c in conflict.candidates if c.role == "extra"]
    if extras:
        raise ConflictStaleError(
            "conflict has extra candidates; use mode=candidate "
            "(Keep PC / Keep phone) first"
        )
    base_cand = by_role.get("base")
    inc_cand = by_role.get("incoming")
    if base_cand is None or inc_cand is None:
        raise ConflictValidationError(
            "entries resolve requires base and incoming candidates"
        )

    base = (base_hash or base_cand.content_hash).strip().lower()
    incoming = (incoming_hash or inc_cand.content_hash).strip().lower()
    if base != base_cand.content_hash or incoming != inc_cand.content_hash:
        raise ConflictStaleError(
            "base_hash/incoming_hash do not match conflict candidates"
        )

    _ensure_blob(data_root, algo, base, base_cand.size_bytes)
    _ensure_blob(data_root, algo, incoming, inc_cand.size_bytes)

    diff = _run_diff(data_root, algo, base, incoming, password)
    if diff.classification in (
        DiffClassification.unlock_failed,
        DiffClassification.parse_failed,
    ):
        raise ConflictValidationError(diff.error or "kdbx diff failed")

    contested = set(diff.removed_entry_uuids) | set(diff.added_entry_uuids)
    for detail in diff.modified_entry_details:
        u = detail.get("uuid")
        if isinstance(u, str) and u:
            contested.add(u.strip().lower())
    contested = {u.strip().lower() for u in contested if u}

    choice_map: dict[str, str] = {}
    for raw in choices:
        uuid = str(raw.get("entry_uuid", "")).strip().lower()
        keep = str(raw.get("keep", "")).strip().lower()
        if not uuid or keep not in ("base", "incoming", "discard"):
            raise ConflictValidationError(
                "each choice needs entry_uuid and keep=base|incoming|discard"
            )
        choice_map[uuid] = keep

    # Plan: 409 if submitted UUID set no longer matches contested UUIDs.
    if contested and set(choice_map) - contested:
        raise ConflictStaleError(
            "choices include entry_uuid(s) not in current base/incoming diff"
        )
    if contested and contested - set(choice_map):
        # Allow omitting choices (defaults apply), but reject if client claimed
        # a full set that is missing contested UUIDs when they sent any.
        # Soft: only reject unknown UUIDs above; omissions use defaults.
        pass

    path_a = blob_path(data_root, algo, base)
    path_b = blob_path(data_root, algo, incoming)
    with tempfile.TemporaryDirectory(prefix="homesync-kdbx-choice-") as tmp:
        dest = Path(tmp) / "merged.kdbx"
        merge_kdbx_with_choices(
            path_a,
            path_b,
            password=password,
            dest=dest,
            choices=choice_map,
        )
        body = dest.read_bytes()
    digest = hash_bytes(body, algo=algo)
    blob_svc.put_blob_bytes(data_root, algo, digest, body)
    merged_size = len(body)

    updated = _promote_merged_head(
        session,
        data_root,
        file_row,
        algo=algo,
        merged_hash=digest,
        merged_size=merged_size,
        archive=[
            (incoming, inc_cand.size_bytes, note or "kdbx choice merge incoming"),
        ],
        note=note or "kdbx choice merge",
    )
    conflict.state = "resolved"
    conflict.resolved_content_hash = digest
    conflict.updated_at = next_updated_at(conflict.updated_at)
    conflict.diff_summary_json = json.dumps(
        {
            "classification": "real",
            "resolved_by": "entries",
            "resolved_content_hash": digest,
            "choices": choice_map,
        }
    )
    session.flush()
    return updated


def recheck_conflict(
    session: Session,
    data_root: Path,
    conflict_id: str,
) -> ContentOutcome:
    """Re-run classify/auto-merge on stored base+incoming after secret is set."""
    conflict = get_conflict(session, conflict_id)
    if conflict.state == "resolved":
        raise ConflictValidationError("conflict already resolved")

    file_row = catalog_svc.get_file(session, conflict.file_id)
    algo = file_row.hash_algo.strip().lower()
    password = kdbx_secrets.get_password(conflict.file_id)
    if not password:
        raise ConflictValidationError(
            "vault secret not set; PUT /v1/files/{id}/kdbx-secret first"
        )

    by_role = {c.role: c for c in conflict.candidates}
    base_cand = by_role.get("base")
    # Prefer newest incoming-like candidate: incoming then latest extra.
    inc_cand = by_role.get("incoming")
    extras = sorted(
        [c for c in conflict.candidates if c.role == "extra"],
        key=lambda c: c.created_at,
    )
    if extras:
        inc_cand = extras[-1]
    if base_cand is None or inc_cand is None:
        raise ConflictValidationError("conflict missing base/incoming candidates")

    _ensure_blob(data_root, algo, base_cand.content_hash, base_cand.size_bytes)
    _ensure_blob(data_root, algo, inc_cand.content_hash, inc_cand.size_bytes)

    diff = _run_diff(
        data_root,
        algo,
        base_cand.content_hash,
        inc_cand.content_hash,
        password,
    )
    if diff.classification == DiffClassification.unlock_failed:
        conflict.state = "needs_secret"
        conflict.diff_summary_json = json.dumps(
            {"classification": "needs_secret", "error": diff.error}
        )
        conflict.updated_at = next_updated_at(conflict.updated_at)
        session.flush()
        return ContentOutcome(
            kind="conflict", conflict=get_conflict(session, conflict.conflict_id)
        )

    if diff.is_trivial:
        updated = _resolve_promote_blob(
            session,
            data_root,
            conflict,
            content_hash=inc_cand.content_hash,
            hash_algo=algo,
            size_bytes=inc_cand.size_bytes,
            note="trivial kdbx recheck",
        )
        return ContentOutcome(kind="file", file=updated)

    if diff.is_auto_mergeable:
        try:
            return _auto_merge_and_promote(
                session,
                data_root,
                file_row,
                algo=algo,
                head_hash=base_cand.content_hash,
                incoming_hash=inc_cand.content_hash,
                incoming_size=inc_cand.size_bytes,
                password=password,
                note="kdbx recheck auto-merge",
                conflict=conflict,
            )
        except Exception as exc:  # noqa: BLE001
            conflict.state = "diff_failed"
            conflict.diff_summary_json = json.dumps(
                {
                    "classification": "diff_failed",
                    "error": f"recheck auto-merge failed: {exc}",
                    **{
                        k: v
                        for k, v in diff.redacted_summary().items()
                        if k not in ("classification", "error")
                    },
                }
            )
            conflict.updated_at = next_updated_at(conflict.updated_at)
            session.flush()
            return ContentOutcome(
                kind="conflict", conflict=get_conflict(session, conflict.conflict_id)
            )

    conflict.state = "open"
    conflict.diff_summary_json = json.dumps(diff.redacted_summary())
    conflict.updated_at = next_updated_at(conflict.updated_at)
    session.flush()
    return ContentOutcome(
        kind="conflict", conflict=get_conflict(session, conflict.conflict_id)
    )


def set_file_kdbx_secret(file_id: str, password: str) -> None:
    kdbx_secrets.set_password(file_id, password)

def content_result_to_schema(outcome: ContentOutcome) -> KdbxContentResult | FileOut:
    if outcome.kind == "file" and outcome.file is not None:
        return catalog_svc.file_to_out(outcome.file)
    assert outcome.conflict is not None
    return KdbxContentResult(
        status="conflict",
        conflict=conflict_to_out(outcome.conflict),
        file=None,
    )
