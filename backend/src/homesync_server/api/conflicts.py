"""KeePass conflict outbox HTTP routes."""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.orm import Session

from homesync_server.api.deps import get_session
from homesync_server.config import data_root
from homesync_server.kdbx import secrets as kdbx_secrets
from homesync_server.schemas.catalog import (
    FileOut,
    KdbxConflictOut,
    KdbxResolveIn,
    KdbxSecretIn,
)
from homesync_server.services import catalog as catalog_svc
from homesync_server.services import kdbx_conflicts as kdbx_svc

router = APIRouter(prefix="/v1", tags=["kdbx"])

SessionDep = Annotated[Session, Depends(get_session)]


@router.put("/files/{file_id}/kdbx-secret")
def put_kdbx_secret(file_id: str, body: KdbxSecretIn, session: SessionDep) -> dict[str, str]:
    try:
        catalog_svc.get_file(session, file_id)
    except catalog_svc.NotFoundError as exc:
        raise HTTPException(status_code=404, detail="file not found") from exc
    try:
        kdbx_svc.set_file_kdbx_secret(file_id, body.password)
    except kdbx_secrets.KdbxSecretError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return {"file_id": file_id, "status": "ok"}


@router.get("/conflicts", response_model=list[KdbxConflictOut])
def list_conflicts(
    session: SessionDep,
    state: str | None = Query("open"),
    limit: int = Query(100, ge=1, le=500),
) -> list[KdbxConflictOut]:
    rows = kdbx_svc.list_conflicts(session, state=state, limit=limit)
    return [kdbx_svc.conflict_to_out(r) for r in rows]


@router.get("/conflicts/{conflict_id}", response_model=KdbxConflictOut)
def get_conflict(conflict_id: str, session: SessionDep) -> KdbxConflictOut:
    try:
        row = kdbx_svc.get_conflict(session, conflict_id)
    except kdbx_svc.ConflictNotFoundError as exc:
        raise HTTPException(status_code=404, detail="conflict not found") from exc
    return kdbx_svc.conflict_to_out(row)


@router.post("/conflicts/{conflict_id}/resolve", response_model=FileOut)
def resolve_conflict(
    conflict_id: str,
    body: KdbxResolveIn,
    session: SessionDep,
) -> FileOut:
    try:
        row = kdbx_svc.resolve_conflict(
            session,
            data_root(),
            conflict_id,
            content_hash=body.content_hash,
            hash_algo=body.hash_algo,
            size_bytes=body.size_bytes,
            note=body.note,
        )
    except kdbx_svc.ConflictNotFoundError as exc:
        raise HTTPException(status_code=404, detail="conflict not found") from exc
    except kdbx_svc.ConflictValidationError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
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
    return catalog_svc.file_to_out(row)
