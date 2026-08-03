"""Catalog delta sync routes."""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.orm import Session

from homesync_server.api.deps import get_session
from homesync_server.schemas.catalog import CatalogDeltaOut
from homesync_server.services import catalog as catalog_svc

router = APIRouter(prefix="/v1", tags=["catalog"])

SessionDep = Annotated[Session, Depends(get_session)]


@router.get("/catalog/delta", response_model=CatalogDeltaOut)
def catalog_delta(
    session: SessionDep,
    since: str | None = Query(
        None,
        description="Opaque cursor from a prior delta (v1:updated_at|file_id). Empty = full scan.",
    ),
    purge_since: str | None = Query(
        None,
        description="Return gc_purges with purged_at strictly after this ISO timestamp.",
    ),
    limit: int = Query(500, ge=1, le=5000),
) -> CatalogDeltaOut:
    try:
        return catalog_svc.catalog_delta(
            session, since=since, purge_since=purge_since, limit=limit
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
