"""Resumable blob upload API (offset-acked chunks)."""

from __future__ import annotations

from pathlib import Path
from typing import Annotated

from fastapi import APIRouter, Header, HTTPException, Request, Response
from pydantic import BaseModel, Field

from homesync_server.config import data_root
from homesync_server.services import uploads as upload_svc

router = APIRouter(prefix="/v1", tags=["blob-uploads"])


def _root(request: Request) -> Path:
    _ = request
    return data_root()


class BeginUploadIn(BaseModel):
    algo: str = "blake3"
    content_hash: str
    size_bytes: int = Field(ge=0)


class UploadStatusOut(BaseModel):
    upload_id: str
    algo: str
    content_hash: str
    size_bytes: int
    offset: int
    complete: bool
    last_activity: str


def _to_out(s: upload_svc.UploadSession) -> UploadStatusOut:
    return UploadStatusOut(
        upload_id=s.upload_id,
        algo=s.algo,
        content_hash=s.content_hash,
        size_bytes=s.size_bytes,
        offset=s.offset,
        complete=s.complete,
        last_activity=s.last_activity,
    )


@router.post("/blob-uploads", response_model=UploadStatusOut)
def begin_blob_upload(body: BeginUploadIn, request: Request) -> UploadStatusOut:
    """Start or resume a resumable upload keyed by (algo, content_hash)."""
    try:
        session = upload_svc.begin_upload(
            _root(request),
            algo=body.algo,
            content_hash=body.content_hash,
            size_bytes=body.size_bytes,
        )
    except upload_svc.UploadConflictError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return _to_out(session)


@router.get("/blob-uploads/{upload_id}", response_model=UploadStatusOut)
def get_blob_upload(upload_id: str, request: Request) -> UploadStatusOut:
    """Return current acked offset (client reconnect / progress poll)."""
    try:
        session = upload_svc.get_upload(_root(request), upload_id)
    except upload_svc.UploadNotFoundError as exc:
        raise HTTPException(status_code=404, detail="upload not found") from exc
    return _to_out(session)


@router.patch("/blob-uploads/{upload_id}")
async def patch_blob_upload(
    upload_id: str,
    request: Request,
    upload_offset: Annotated[int | None, Header(alias="Upload-Offset")] = None,
) -> Response:
    """Append a chunk at Upload-Offset; response Upload-Offset is the server ack."""
    if upload_offset is None:
        raise HTTPException(status_code=400, detail="Upload-Offset header required")

    chunk = await request.body()
    try:
        session = upload_svc.append_chunk(
            _root(request),
            upload_id,
            client_offset=upload_offset,
            chunk=chunk,
        )
    except upload_svc.UploadNotFoundError as exc:
        raise HTTPException(status_code=404, detail="upload not found") from exc
    except upload_svc.UploadOffsetError as exc:
        raise HTTPException(
            status_code=409,
            detail=str(exc),
            headers={"Upload-Offset": str(exc.expected)},
        ) from exc
    except upload_svc.UploadGoneError as exc:
        raise HTTPException(status_code=410, detail=str(exc)) from exc
    except upload_svc.UploadConflictError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc

    return Response(
        status_code=204,
        headers={
            "Upload-Offset": str(session.offset),
            "Upload-Length": str(session.size_bytes),
            "X-Upload-Complete": "1" if session.complete else "0",
            "X-Content-Hash": session.content_hash,
            "X-Hash-Algo": session.algo,
        },
    )
