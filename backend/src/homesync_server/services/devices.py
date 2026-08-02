"""Device registration (phone hello / upsert)."""

from __future__ import annotations

from sqlalchemy import select
from sqlalchemy.orm import Session

from homesync_server.models import Device
from homesync_server.util import utc_now_iso

_ALLOWED_KINDS = frozenset({"linux", "android", "other"})


class DeviceValidationError(Exception):
    pass


def register_device(
    session: Session,
    *,
    device_id: str,
    name: str,
    kind: str,
) -> Device:
    """Upsert a device by client-stable ``device_id``; refresh ``last_seen_at``."""
    device_id = device_id.strip()
    name = name.strip()
    kind = kind.strip().lower()

    if not device_id:
        raise DeviceValidationError("device_id must be non-empty")
    if len(device_id) > 36:
        raise DeviceValidationError("device_id must be at most 36 characters")
    if not name:
        raise DeviceValidationError("name must be non-empty")
    if kind not in _ALLOWED_KINDS:
        raise DeviceValidationError(
            f"kind must be one of: {', '.join(sorted(_ALLOWED_KINDS))}"
        )

    now = utc_now_iso()
    existing = session.scalars(
        select(Device).where(Device.device_id == device_id)
    ).first()
    if existing is not None:
        existing.name = name
        existing.kind = kind
        existing.last_seen_at = now
        session.flush()
        return existing

    device = Device(
        device_id=device_id,
        name=name,
        kind=kind,
        created_at=now,
        last_seen_at=now,
    )
    session.add(device)
    session.flush()
    return device


def get_device(session: Session, device_id: str) -> Device | None:
    return session.scalars(select(Device).where(Device.device_id == device_id)).first()


def list_devices(session: Session) -> list[Device]:
    """All registered devices, newest ``last_seen_at`` first."""
    return list(
        session.scalars(
            select(Device).order_by(Device.last_seen_at.desc(), Device.device_id)
        ).all()
    )
