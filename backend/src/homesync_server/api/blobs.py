"""Blob download / upload routes (content-addressed GET + PUT)."""

from __future__ import annotations

from pathlib import Path
from typing import Annotated

import blake3
from fastapi import APIRouter, Depends, HTTPException, Request, Response
from fastapi.responses import FileResponse
from sqlalchemy.orm import Session

from homesync_server.api.deps import get_session
from homesync_server.config import data_root
from homesync_server.services import blobs as blob_svc
from homesync_server.storage import blob_path, hash_file

router = APIRouter(prefix="/v1", tags=["blobs"])

SessionDep = Annotated[Session, Depends(get_session)]


def _data_root(request: Request) -> Path:
    # Prefer env/config resolution so TestClient HOMESYNC_DATA overrides work.
    _ = request
    return data_root()


@router.get("/blobs/{algo}/{hex_hash}")
def get_blob(
    algo: str,
    hex_hash: str,
    session: SessionDep,
    request: Request,
) -> FileResponse:
    """Serve content-addressed bytes (managed store or hash-in-place path)."""
    try:
        path, size = blob_svc.open_blob_bytes(
            session, _data_root(request), algo, hex_hash
        )
    except blob_svc.BlobNotFoundError as exc:
        raise HTTPException(status_code=404, detail="blob not found") from exc
    except blob_svc.BlobIntegrityError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    return FileResponse(
        path,
        media_type="application/octet-stream",
        headers={
            "Content-Length": str(size),
            "ETag": f'"{algo}:{hex_hash.lower()}"',
            "X-Content-Hash": hex_hash.lower(),
            "X-Hash-Algo": algo.lower(),
        },
    )


@router.put("/blobs/{algo}/{hex_hash}")
async def put_blob(
    algo: str,
    hex_hash: str,
    request: Request,
) -> Response:
    """Store content-addressed bytes (streamed atomic write; identical = dedup)."""
    algo_norm = algo.strip().lower()
    digest = hex_hash.strip().lower()
    if len(digest) < 4:
        raise HTTPException(status_code=400, detail="hash too short")

    root = _data_root(request)
    dest = blob_path(root, algo_norm, digest)

    content_length = request.headers.get("content-length")
    expected_size: int | None = None
    if content_length is not None and content_length.isdigit():
        expected_size = int(content_length)

    # Dedup without buffering the body when size already matches.
    if (
        dest.is_file()
        and expected_size is not None
        and dest.stat().st_size == expected_size
        and hash_file(dest, algo=algo_norm) == digest
    ):
        async for _ in request.stream():
            pass
        return Response(
            status_code=200,
            headers={
                "Content-Length": "0",
                "ETag": f'"{algo_norm}:{digest}"',
                "X-Content-Hash": digest,
                "X-Hash-Algo": algo_norm,
                "X-Blob-Path": str(dest),
                "X-Blob-Created": "0",
            },
        )

    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_name(dest.name + ".tmp")
    hasher = blake3.blake3()
    size = 0
    created = True
    try:
        with tmp.open("wb") as fh:
            async for chunk in request.stream():
                if not chunk:
                    continue
                hasher.update(chunk)
                fh.write(chunk)
                size += len(chunk)
                if expected_size is not None and size > expected_size:
                    raise blob_svc.BlobHashMismatchError(
                        f"body larger than Content-Length ({expected_size})"
                    )
        actual = hasher.hexdigest()
        if actual != digest:
            raise blob_svc.BlobHashMismatchError(
                f"hash mismatch: expected {digest}, got {actual}"
            )
        if expected_size is not None and size != expected_size:
            raise blob_svc.BlobHashMismatchError(
                f"size mismatch: Content-Length={expected_size}, got {size}"
            )
        if dest.is_file():
            if dest.stat().st_size == size and hash_file(dest, algo=algo_norm) == digest:
                created = False
            else:
                raise blob_svc.BlobCollisionError(
                    f"blob collision for {algo_norm}/{digest}: "
                    f"existing size={dest.stat().st_size} new size={size}"
                )
        if created:
            tmp.replace(dest)
        else:
            tmp.unlink(missing_ok=True)
    except blob_svc.BlobHashMismatchError as exc:
        tmp.unlink(missing_ok=True)
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except blob_svc.BlobCollisionError as exc:
        tmp.unlink(missing_ok=True)
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    except Exception:
        tmp.unlink(missing_ok=True)
        raise
    finally:
        if tmp.exists():
            tmp.unlink(missing_ok=True)

    return Response(
        status_code=201 if created else 200,
        headers={
            "Content-Length": "0",
            "ETag": f'"{algo_norm}:{digest}"',
            "X-Content-Hash": digest,
            "X-Hash-Algo": algo_norm,
            "X-Blob-Path": str(dest),
            "X-Blob-Created": "1" if created else "0",
        },
    )
