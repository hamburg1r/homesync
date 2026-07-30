"""Small shared helpers."""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from uuid import uuid4


def utc_now_iso() -> str:
    """UTC timestamp as ISO-8601 with ``Z`` (microsecond precision for delta cursors)."""
    return datetime.now(UTC).isoformat(timespec="microseconds").replace("+00:00", "Z")


def next_updated_at(previous: str | None = None) -> str:
    """Return a timestamp strictly greater than ``previous`` (for LWW / delta ordering)."""
    now = utc_now_iso()
    if previous is None or now > previous:
        return now
    try:
        prev_dt = datetime.fromisoformat(previous)
    except ValueError:
        return f"{previous}+"
    bumped = (prev_dt + timedelta(microseconds=1)).astimezone(UTC)
    return bumped.isoformat(timespec="microseconds").replace("+00:00", "Z")


def new_uuid() -> str:
    return str(uuid4())
