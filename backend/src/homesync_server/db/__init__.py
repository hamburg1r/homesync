"""Database engine, sessions, and bootstrap."""

from __future__ import annotations

from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path

from sqlalchemy import create_engine, select
from sqlalchemy.engine import Engine
from sqlalchemy.orm import Session, sessionmaker

from homesync_server.config import catalog_db_path, ensure_data_dirs
from homesync_server.db.migrate import apply_migrations
from homesync_server.models import Device
from homesync_server.util import new_uuid, utc_now_iso

# Stable device_id for the Linux host in a given data root ( regenerated only if missing).
_LOCAL_DEVICE_NAME = "linux-host"
_LOCAL_DEVICE_KIND = "linux"


def make_engine(db_path: Path) -> Engine:
    return create_engine(
        f"sqlite:///{db_path}",
        connect_args={"check_same_thread": False},
    )


def bootstrap(data_dir: Path | None = None) -> tuple[Path, Engine]:
    """Ensure data dirs + SQLite schema; return (data_root, engine)."""
    root = ensure_data_dirs(data_dir)
    db_path = catalog_db_path(root)
    engine = make_engine(db_path)
    apply_migrations(engine)
    with Session(engine) as session:
        ensure_local_device(session)
        session.commit()
    return root, engine


def ensure_local_device(session: Session) -> Device:
    """Register the Linux host device if absent; return it."""
    existing = session.scalars(
        select(Device).where(Device.kind == _LOCAL_DEVICE_KIND).limit(1)
    ).first()
    if existing is not None:
        return existing
    now = utc_now_iso()
    device = Device(
        device_id=new_uuid(),
        name=_LOCAL_DEVICE_NAME,
        kind=_LOCAL_DEVICE_KIND,
        created_at=now,
        last_seen_at=now,
    )
    session.add(device)
    session.flush()
    return device


@contextmanager
def session_scope(engine: Engine) -> Iterator[Session]:
    session = sessionmaker(bind=engine, expire_on_commit=False)()
    try:
        yield session
        session.commit()
    except Exception:
        session.rollback()
        raise
    finally:
        session.close()
