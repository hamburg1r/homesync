"""Availability mode services (listed / cached / pinned)."""

from __future__ import annotations

from sqlalchemy import select
from sqlalchemy.orm import Session

from homesync_server.models import Availability, Device
from homesync_server.schemas.catalog import AvailabilityOut
from homesync_server.services.catalog import CatalogConflictError, NotFoundError, get_file
from homesync_server.util import next_updated_at

_ALLOWED_MODES = frozenset({"listed", "cached", "pinned"})


class AvailabilityValidationError(Exception):
    pass


def availability_to_out(row: Availability) -> AvailabilityOut:
    return AvailabilityOut(
        file_id=row.file_id,
        device_id=row.device_id,
        mode=row.mode,
        updated_at=row.updated_at,
    )


def get_availability(
    session: Session, file_id: str, device_id: str
) -> Availability | None:
    return session.scalars(
        select(Availability).where(
            Availability.file_id == file_id,
            Availability.device_id == device_id,
        )
    ).first()


def set_availability(
    session: Session,
    file_id: str,
    device_id: str,
    *,
    mode: str,
    updated_at: str | None = None,
    base_updated_at: str | None = None,
) -> Availability:
    """Upsert availability for a device; bump ``files.updated_at`` for delta sync."""
    mode = mode.strip().lower()
    if mode not in _ALLOWED_MODES:
        raise AvailabilityValidationError(
            f"mode must be one of: {', '.join(sorted(_ALLOWED_MODES))}"
        )

    file_row = get_file(session, file_id)
    device = session.scalars(
        select(Device).where(Device.device_id == device_id)
    ).first()
    if device is None:
        raise NotFoundError(f"device:{device_id}")

    row = get_availability(session, file_id, device_id)
    if row is not None:
        if base_updated_at is not None and base_updated_at != row.updated_at:
            raise CatalogConflictError(file_row)
        if updated_at is not None and updated_at < row.updated_at:
            raise CatalogConflictError(file_row)
        row.mode = mode
        row.updated_at = (
            updated_at if updated_at is not None else next_updated_at(row.updated_at)
        )
    else:
        now = updated_at if updated_at is not None else next_updated_at(file_row.updated_at)
        row = Availability(
            file_id=file_id,
            device_id=device_id,
            mode=mode,
            updated_at=now,
        )
        session.add(row)

    # Tag-edit pattern: bump file so catalog delta clients observe availability.
    file_row.updated_at = next_updated_at(max(file_row.updated_at, row.updated_at))
    session.flush()
    return row


def list_availability_for_files(
    session: Session, file_ids: list[str]
) -> list[Availability]:
    if not file_ids:
        return []
    return list(
        session.scalars(
            select(Availability).where(Availability.file_id.in_(file_ids))
        ).all()
    )
