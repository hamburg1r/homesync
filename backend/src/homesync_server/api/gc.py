"""Manual garbage-collection routes."""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from homesync_server.api.deps import get_session
from homesync_server.config import data_root
from homesync_server.schemas.catalog import GcRunIn, GcRunOut
from homesync_server.services import gc as gc_svc

router = APIRouter(prefix="/v1", tags=["gc"])

SessionDep = Annotated[Session, Depends(get_session)]


@router.post("/gc", response_model=GcRunOut)
def run_gc(body: GcRunIn, session: SessionDep) -> GcRunOut:
    """Hard-purge soft-deleted catalog rows and unreferenced managed blobs."""
    try:
        result = gc_svc.run_gc(
            session,
            data_root(),
            dry_run=body.dry_run,
            purge_tombstones=body.purge_tombstones,
            purge_blobs=body.purge_blobs,
            purge_uploads=body.purge_uploads,
            min_age_seconds=body.min_age_seconds,
            file_ids=body.file_ids,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return GcRunOut(
        dry_run=result.dry_run,
        purged_file_ids=result.purged_file_ids,
        skipped_open_conflict_ids=result.skipped_open_conflict_ids,
        deleted_blobs=result.deleted_blobs,
        deleted_thumbs=result.deleted_thumbs,
        deleted_uploads=result.deleted_uploads,
        bytes_reclaimed=result.bytes_reclaimed,
    )
