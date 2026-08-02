"""Blob download / upload routes (content-addressed GET + PUT)."""

from __future__ import annotations

from pathlib import Path
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Request, Response
from fastapi.responses import FileResponse
from sqlalchemy.orm import Session

from homesync_server.api.deps import get_session
from homesync_server.config import data_root
from homesync_server.services import blobs as blob_svc

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
    """Store content-addressed bytes (atomic write; identical body = dedup)."""
    body = await request.body()
    try:
        path, created = blob_svc.put_blob_bytes(
            _data_root(request), algo, hex_hash, body
        )
    except blob_svc.BlobHashMismatchError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except blob_svc.BlobCollisionError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    return Response(
        status_code=201 if created else 200,
        headers={
            "Content-Length": "0",
            "ETag": f'"{algo}:{hex_hash.lower()}"',
            "X-Content-Hash": hex_hash.strip().lower(),
            "X-Hash-Algo": algo.strip().lower(),
            "X-Blob-Path": str(path),
            "X-Blob-Created": "1" if created else "0",
        },
    )
