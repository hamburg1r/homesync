"""File metadata and tag routes."""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.orm import Session

from homesync_server.api.deps import get_session
from homesync_server.schemas.catalog import FileOut, FilePatchIn, FileTagsPutIn, TagOut
from homesync_server.services import catalog as catalog_svc

router = APIRouter(prefix="/v1", tags=["catalog"])

SessionDep = Annotated[Session, Depends(get_session)]


@router.get("/files", response_model=list[FileOut])
def list_files(
    session: SessionDep,
    include_deleted: bool = Query(False),
    limit: int = Query(100, ge=1, le=1000),
    offset: int = Query(0, ge=0),
) -> list[FileOut]:
    rows = catalog_svc.list_files(
        session, include_deleted=include_deleted, limit=limit, offset=offset
    )
    return [catalog_svc.file_to_out(r) for r in rows]


@router.get("/files/{file_id}", response_model=FileOut)
def get_file(file_id: str, session: SessionDep) -> FileOut:
    try:
        row = catalog_svc.get_file(session, file_id)
    except catalog_svc.NotFoundError as exc:
        raise HTTPException(status_code=404, detail="file not found") from exc
    return catalog_svc.file_to_out(row)


@router.patch("/files/{file_id}", response_model=FileOut)
def patch_file(
    file_id: str,
    body: FilePatchIn,
    session: SessionDep,
) -> FileOut:
    try:
        row = catalog_svc.patch_file(
            session,
            file_id,
            title=body.title,
            notes=body.notes,
            updated_at=body.updated_at,
            base_updated_at=body.base_updated_at,
        )
    except catalog_svc.NotFoundError as exc:
        raise HTTPException(status_code=404, detail="file not found") from exc
    except catalog_svc.CatalogConflictError as exc:
        raise HTTPException(
            status_code=409,
            detail={
                "message": "catalog conflict",
                "file": catalog_svc.file_to_out(exc.file_row).model_dump(),
            },
        ) from exc
    return catalog_svc.file_to_out(row)


@router.delete("/files/{file_id}", response_model=FileOut)
def delete_file(file_id: str, session: SessionDep) -> FileOut:
    try:
        row = catalog_svc.soft_delete_file(session, file_id)
    except catalog_svc.NotFoundError as exc:
        raise HTTPException(status_code=404, detail="file not found") from exc
    return catalog_svc.file_to_out(row)


@router.put("/files/{file_id}/tags", response_model=FileOut)
def put_file_tags(
    file_id: str,
    body: FileTagsPutIn,
    session: SessionDep,
) -> FileOut:
    try:
        row = catalog_svc.set_file_tags(session, file_id, body.tags)
    except catalog_svc.NotFoundError as exc:
        raise HTTPException(status_code=404, detail="file not found") from exc
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return catalog_svc.file_to_out(row)


@router.get("/tags", response_model=list[TagOut])
def list_tags(session: SessionDep) -> list[TagOut]:
    return [catalog_svc.tag_to_out(t) for t in catalog_svc.list_tags(session)]
