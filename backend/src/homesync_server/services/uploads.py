"""Resumable content-addressed blob uploads (chunked, offset-acked)."""

from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

import blake3

from homesync_server.storage import blob_path, hash_file

# Client may reconnect and continue while the last chunk was within this window.
# Partials themselves are kept longer so a reconnect after a stall still resumes.
IDLE_RESUME_SECONDS = 60 * 60  # 1 hour
PARTIAL_KEEP_SECONDS = 7 * 24 * 60 * 60  # 7 days


class UploadError(Exception):
    """Base upload error."""


class UploadNotFoundError(UploadError):
    pass


class UploadOffsetError(UploadError):
    """Client Upload-Offset does not match server ack offset."""

    def __init__(self, expected: int, got: int) -> None:
        self.expected = expected
        self.got = got
        super().__init__(f"offset mismatch: server={expected}, client={got}")


class UploadConflictError(UploadError):
    pass


class UploadGoneError(UploadError):
    """Partial expired (no activity for too long)."""


@dataclass
class UploadSession:
    upload_id: str
    algo: str
    content_hash: str
    size_bytes: int
    offset: int
    last_activity: str
    complete: bool = False

    def to_json(self) -> dict[str, object]:
        return {
            "upload_id": self.upload_id,
            "algo": self.algo,
            "content_hash": self.content_hash,
            "size_bytes": self.size_bytes,
            "offset": self.offset,
            "last_activity": self.last_activity,
            "complete": self.complete,
        }


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _parse_iso(raw: str) -> datetime:
    return datetime.fromisoformat(raw.replace("Z", "+00:00"))


def upload_id_for(algo: str, hex_hash: str) -> str:
    return f"{algo.strip().lower()}:{hex_hash.strip().lower()}"


def upload_dir(data_root: Path, algo: str, hex_hash: str) -> Path:
    digest = hex_hash.strip().lower()
    algo_norm = algo.strip().lower()
    return data_root / "uploads" / algo_norm / digest[0:2] / digest[2:4] / digest


def _meta_path(udir: Path) -> Path:
    return udir / "meta.json"


def _partial_path(udir: Path) -> Path:
    return udir / "partial"


def _load_meta(udir: Path) -> UploadSession:
    meta = _meta_path(udir)
    if not meta.is_file():
        raise UploadNotFoundError(udir.name)
    data = json.loads(meta.read_text(encoding="utf-8"))
    partial = _partial_path(udir)
    offset = partial.stat().st_size if partial.is_file() else 0
    # Trust on-disk partial length over stale meta offset.
    return UploadSession(
        upload_id=str(data["upload_id"]),
        algo=str(data["algo"]),
        content_hash=str(data["content_hash"]),
        size_bytes=int(data["size_bytes"]),
        offset=offset,
        last_activity=str(data.get("last_activity") or _now_iso()),
        complete=bool(data.get("complete", False)),
    )


def _save_meta(udir: Path, session: UploadSession) -> None:
    udir.mkdir(parents=True, exist_ok=True)
    _meta_path(udir).write_text(
        json.dumps(session.to_json(), indent=2) + "\n",
        encoding="utf-8",
    )


def begin_upload(
    data_root: Path,
    *,
    algo: str,
    content_hash: str,
    size_bytes: int,
) -> UploadSession:
    """Create or resume an upload session keyed by (algo, hash)."""
    if size_bytes < 0:
        raise ValueError("size_bytes must be non-negative")
    algo_norm = algo.strip().lower()
    digest = content_hash.strip().lower()
    if len(digest) < 4:
        raise ValueError("hash too short")
    if algo_norm != "blake3":
        raise ValueError(f"unsupported algo: {algo_norm}")

    dest = blob_path(data_root, algo_norm, digest)
    uid = upload_id_for(algo_norm, digest)
    if dest.is_file() and dest.stat().st_size == size_bytes:
        if hash_file(dest, algo=algo_norm) == digest:
            return UploadSession(
                upload_id=uid,
                algo=algo_norm,
                content_hash=digest,
                size_bytes=size_bytes,
                offset=size_bytes,
                last_activity=_now_iso(),
                complete=True,
            )

    udir = upload_dir(data_root, algo_norm, digest)
    if _meta_path(udir).is_file():
        session = _load_meta(udir)
        if session.size_bytes != size_bytes:
            raise UploadConflictError(
                f"size mismatch for existing upload: "
                f"{session.size_bytes} vs {size_bytes}"
            )
        # Stale partial (>7d idle): wipe and restart.
        age = (datetime.now(timezone.utc) - _parse_iso(session.last_activity)).total_seconds()
        if age > PARTIAL_KEEP_SECONDS and session.offset < session.size_bytes:
            _wipe_upload(udir)
        else:
            return session

    session = UploadSession(
        upload_id=uid,
        algo=algo_norm,
        content_hash=digest,
        size_bytes=size_bytes,
        offset=0,
        last_activity=_now_iso(),
        complete=False,
    )
    if size_bytes == 0:
        # Empty blob: promote immediately (blake3 of b"").
        dest.parent.mkdir(parents=True, exist_ok=True)
        if not dest.is_file():
            dest.write_bytes(b"")
        actual = hash_file(dest, algo=algo_norm)
        if actual != digest:
            dest.unlink(missing_ok=True)
            raise UploadConflictError(
                f"hash mismatch for empty blob: expected {digest}, got {actual}"
            )
        session.offset = 0
        session.complete = True
        return session

    _save_meta(udir, session)
    _partial_path(udir).write_bytes(b"")
    return session


def get_upload(data_root: Path, upload_id: str) -> UploadSession:
    algo, _, digest = upload_id.partition(":")
    if not algo or not digest:
        raise UploadNotFoundError(upload_id)
    udir = upload_dir(data_root, algo, digest)
    if not _meta_path(udir).is_file():
        # Already promoted?
        dest = blob_path(data_root, algo, digest)
        if dest.is_file():
            return UploadSession(
                upload_id=upload_id,
                algo=algo,
                content_hash=digest,
                size_bytes=dest.stat().st_size,
                offset=dest.stat().st_size,
                last_activity=_now_iso(),
                complete=True,
            )
        raise UploadNotFoundError(upload_id)
    return _load_meta(udir)


def append_chunk(
    data_root: Path,
    upload_id: str,
    *,
    client_offset: int,
    chunk: bytes,
) -> UploadSession:
    """Append ``chunk`` at ``client_offset`` (must match server offset). Ack new offset."""
    session = get_upload(data_root, upload_id)
    if session.complete:
        return session

    age = (datetime.now(timezone.utc) - _parse_iso(session.last_activity)).total_seconds()
    # Soft signal: still accept resume after idle; only refuse ancient partials.
    if age > PARTIAL_KEEP_SECONDS:
        raise UploadGoneError("upload partial expired; restart upload")

    if client_offset != session.offset:
        raise UploadOffsetError(session.offset, client_offset)

    if not chunk:
        session.last_activity = _now_iso()
        udir = upload_dir(data_root, session.algo, session.content_hash)
        _save_meta(udir, session)
        return session

    new_offset = session.offset + len(chunk)
    if new_offset > session.size_bytes:
        raise UploadConflictError(
            f"chunk would exceed size_bytes ({session.size_bytes})"
        )

    udir = upload_dir(data_root, session.algo, session.content_hash)
    partial = _partial_path(udir)
    with partial.open("ab") as fh:
        fh.write(chunk)
        fh.flush()

    session.offset = new_offset
    session.last_activity = _now_iso()

    if session.offset == session.size_bytes:
        _finalize(data_root, session, partial)
        session.complete = True
        _wipe_upload(udir)
        return session

    _save_meta(udir, session)
    return session


def _finalize(data_root: Path, session: UploadSession, partial: Path) -> None:
    actual = hash_file(partial, algo=session.algo)
    if actual != session.content_hash:
        partial.unlink(missing_ok=True)
        raise UploadConflictError(
            f"hash mismatch after upload: expected {session.content_hash}, got {actual}"
        )
    dest = blob_path(data_root, session.algo, session.content_hash)
    if dest.is_file():
        if (
            dest.stat().st_size == session.size_bytes
            and hash_file(dest, algo=session.algo) == session.content_hash
        ):
            return
        raise UploadConflictError(
            f"blob collision for {session.algo}/{session.content_hash}"
        )
    dest.parent.mkdir(parents=True, exist_ok=True)
    partial.replace(dest)


def _wipe_upload(udir: Path) -> None:
    for child in udir.glob("*"):
        child.unlink(missing_ok=True)
    if udir.is_dir():
        try:
            udir.rmdir()
        except OSError:
            pass


def verify_running_hash(partial: Path, expected_prefix_len: int) -> str:
    """Optional helper for tests: blake3 of first N bytes."""
    hasher = blake3.blake3()
    remaining = expected_prefix_len
    with partial.open("rb") as fh:
        while remaining > 0:
            block = fh.read(min(1024 * 1024, remaining))
            if not block:
                break
            hasher.update(block)
            remaining -= len(block)
    return hasher.hexdigest()
