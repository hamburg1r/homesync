"""File metadata and tag routes."""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response
from sqlalchemy.orm import Session

from homesync_server.api.deps import get_session
from homesync_server.config import data_root
from homesync_server.schemas.catalog import (
    AvailabilityOut,
    AvailabilityPutIn,
    FileContentIn,
    FileCreateIn,
    FileOut,
    FilePatchIn,
    FileTagsPutIn,
    FileVersionsOut,
    KdbxContentResult,
    TagOut,
)
from homesync_server.services import availability as avail_svc
from homesync_server.services import catalog as catalog_svc
from homesync_server.services import kdbx_conflicts as kdbx_svc

router = APIRouter(prefix="/v1", tags=["catalog"])

SessionDep = Annotated[Session, Depends(get_session)]


@router.post("/files", response_model=FileOut)
def create_file(
    body: FileCreateIn,
    session: SessionDep,
    request: Request,
) -> FileOut:
    """Ingest a catalog row after ``PUT /v1/blobs`` (dedup by content hash)."""
    _ = request
    try:
        row = catalog_svc.create_file(
            session,
            data_root(),
            content_hash=body.content_hash,
            hash_algo=body.hash_algo,
            size_bytes=body.size_bytes,
            mime_type=body.mime_type,
            title=body.title,
            taken_at=body.taken_at,
            source_kind=body.source_kind,
            source_device_id=body.source_device_id,
            relative_path=body.relative_path,
        )
    except catalog_svc.NotFoundError as exc:
        detail = (
            "device not found"
            if str(exc).startswith("device:")
            else "file not found"
        )
        raise HTTPException(status_code=404, detail=detail) from exc
    except catalog_svc.IngestValidationError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return catalog_svc.file_to_out(row)


@router.get("/files", response_model=list[FileOut])
def list_files(
    session: SessionDep,
    include_deleted: bool = Query(False),
    limit: int = Query(100, ge=1, le=1000),
    offset: int = Query(0, ge=0),
    q: str | None = Query(
        None,
        description="Basic search: case-insensitive match on title, notes, or tag name",
    ),
) -> list[FileOut]:
    rows = catalog_svc.list_files(
        session,
        include_deleted=include_deleted,
        limit=limit,
        offset=offset,
        q=q,
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


@router.post(
    "/files/{file_id}/content",
    response_model=FileOut | KdbxContentResult,
    responses={202: {"model": KdbxContentResult}},
)
def update_file_content(
    file_id: str,
    body: FileContentIn,
    session: SessionDep,
    request: Request,
    response: Response,
) -> FileOut | KdbxContentResult:
    """Archive current head and set a new content hash (blob must exist).

    For ``.kdbx`` files, a real semantic conflict returns **202** with an
    outbox payload instead of changing the catalog head.
    """
    _ = request
    try:
        outcome = kdbx_svc.apply_kdbx_content(
            session,
            data_root(),
            file_id,
            content_hash=body.content_hash,
            hash_algo=body.hash_algo,
            size_bytes=body.size_bytes,
            note=body.note,
        )
    except catalog_svc.NotFoundError as exc:
        raise HTTPException(status_code=404, detail="file not found") from exc
    except catalog_svc.IngestValidationError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except catalog_svc.CatalogConflictError as exc:
        raise HTTPException(
            status_code=409,
            detail={
                "message": "content hash already used by another file",
                "file": catalog_svc.file_to_out(exc.file_row).model_dump(),
            },
        ) from exc

    if outcome.kind == "conflict" and outcome.conflict is not None:
        response.status_code = 202
        return KdbxContentResult(
            status="conflict",
            conflict=kdbx_svc.conflict_to_out(outcome.conflict),
            file=None,
        )
    assert outcome.file is not None
    return catalog_svc.file_to_out(outcome.file)


@router.get("/files/{file_id}/versions", response_model=FileVersionsOut)
def get_file_versions(file_id: str, session: SessionDep) -> FileVersionsOut:
    try:
        return catalog_svc.list_file_versions(session, file_id)
    except catalog_svc.NotFoundError as exc:
        raise HTTPException(status_code=404, detail="file not found") from exc


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


@router.put(
    "/files/{file_id}/availability/{device_id}",
    response_model=AvailabilityOut,
)
def put_availability(
    file_id: str,
    device_id: str,
    body: AvailabilityPutIn,
    session: SessionDep,
) -> AvailabilityOut:
    try:
        row = avail_svc.set_availability(
            session,
            file_id,
            device_id,
            mode=body.mode,
            updated_at=body.updated_at,
            base_updated_at=body.base_updated_at,
        )
    except catalog_svc.NotFoundError as exc:
        detail = "file not found" if not str(exc).startswith("device:") else "device not found"
        raise HTTPException(status_code=404, detail=detail) from exc
    except avail_svc.AvailabilityValidationError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except catalog_svc.CatalogConflictError as exc:
        raise HTTPException(
            status_code=409,
            detail={
                "message": "availability conflict",
                "file": catalog_svc.file_to_out(exc.file_row).model_dump(),
            },
        ) from exc
    return avail_svc.availability_to_out(row)


@router.get(
    "/files/{file_id}/availability/{device_id}",
    response_model=AvailabilityOut,
)
def get_availability(
    file_id: str,
    device_id: str,
    session: SessionDep,
) -> AvailabilityOut:
    try:
        catalog_svc.get_file(session, file_id)
    except catalog_svc.NotFoundError as exc:
        raise HTTPException(status_code=404, detail="file not found") from exc
    row = avail_svc.get_availability(session, file_id, device_id)
    if row is None:
        raise HTTPException(status_code=404, detail="availability not found")
    return avail_svc.availability_to_out(row)
