"""Thumbnail download routes (listed-mode small JPEG payloads)."""

from __future__ import annotations

from pathlib import Path
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import FileResponse
from sqlalchemy.orm import Session

from homesync_server.api.deps import get_session
from homesync_server.config import data_root
from homesync_server.services import catalog as catalog_svc
from homesync_server.services import thumbs as thumb_svc

router = APIRouter(prefix="/v1", tags=["thumbs"])

SessionDep = Annotated[Session, Depends(get_session)]


def _data_root(request: Request) -> Path:
    _ = request
    return data_root()


@router.get("/thumbs/{file_id}")
def get_thumb(
    file_id: str,
    session: SessionDep,
    request: Request,
) -> FileResponse:
    """Serve a JPEG thumbnail (generated on demand from the full blob)."""
    try:
        path = thumb_svc.ensure_thumb(session, _data_root(request), file_id)
    except catalog_svc.NotFoundError as exc:
        raise HTTPException(status_code=404, detail="file not found") from exc
    except thumb_svc.ThumbNotFoundError as exc:
        raise HTTPException(status_code=404, detail="blob not found") from exc
    except thumb_svc.ThumbNotSupportedError as exc:
        raise HTTPException(status_code=415, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    size = path.stat().st_size
    return FileResponse(
        path,
        media_type="image/jpeg",
        headers={
            "Content-Length": str(size),
            "Cache-Control": "private, max-age=86400",
            "X-Thumb-File-Id": file_id,
        },
    )
