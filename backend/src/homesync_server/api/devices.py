"""Device registration routes."""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from homesync_server.api.deps import get_session
from homesync_server.models import Device
from homesync_server.schemas.catalog import DeviceIn, DeviceOut
from homesync_server.services import devices as devices_svc

router = APIRouter(prefix="/v1", tags=["devices"])

SessionDep = Annotated[Session, Depends(get_session)]


def _device_out(device: Device) -> DeviceOut:
    return DeviceOut(
        device_id=device.device_id,
        name=device.name,
        kind=device.kind,
        created_at=device.created_at,
        last_seen_at=device.last_seen_at,
    )


@router.post("/devices", response_model=DeviceOut)
def register_device(body: DeviceIn, session: SessionDep) -> DeviceOut:
    try:
        device = devices_svc.register_device(
            session,
            device_id=body.device_id,
            name=body.name,
            kind=body.kind,
        )
    except devices_svc.DeviceValidationError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return _device_out(device)


@router.get("/devices/{device_id}", response_model=DeviceOut)
def get_device(device_id: str, session: SessionDep) -> DeviceOut:
    device = devices_svc.get_device(session, device_id)
    if device is None:
        raise HTTPException(status_code=404, detail="device not found")
    return _device_out(device)
