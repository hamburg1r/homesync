"""Ordered SQL migrations applied at bootstrap."""

from __future__ import annotations

from pathlib import Path

from sqlalchemy import text
from sqlalchemy.engine import Connection, Engine

from homesync_server.util import utc_now_iso

MIGRATIONS_DIR = Path(__file__).parent / "migrations"


def current_version(conn: Connection) -> int:
    conn.execute(
        text(
            """
            CREATE TABLE IF NOT EXISTS schema_version (
                version INTEGER PRIMARY KEY,
                applied_at TEXT NOT NULL
            )
            """
        )
    )
    row = conn.execute(text("SELECT COALESCE(MAX(version), 0) FROM schema_version")).one()
    return int(row[0])


def apply_migrations(engine: Engine) -> int:
    """Apply pending ``NNN_*.sql`` files. Returns the resulting schema version."""
    files = sorted(MIGRATIONS_DIR.glob("*.sql"))
    with engine.begin() as conn:
        version = current_version(conn)
        for path in files:
            try:
                file_version = int(path.name.split("_", 1)[0])
            except ValueError as exc:
                raise RuntimeError(f"Invalid migration filename: {path.name}") from exc
            if file_version <= version:
                continue
            sql = path.read_text(encoding="utf-8")
            # SQLite needs executescript for multi-statement migration files.
            raw = conn.connection.dbapi_connection
            raw.executescript(sql)
            conn.execute(
                text("INSERT INTO schema_version (version, applied_at) VALUES (:v, :t)"),
                {"v": file_version, "t": utc_now_iso()},
            )
            version = file_version
    return version
