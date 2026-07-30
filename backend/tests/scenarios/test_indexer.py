"""Milestone 1 exit check: indexer fills catalog; re-run idempotent; gone soft-detect."""

from __future__ import annotations

from pathlib import Path

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from homesync_server.db import bootstrap, session_scope
from homesync_server.db.migrate import current_version
from homesync_server.indexer import ensure_library_root, index_all_roots
from homesync_server.models import File, FilePath, LibraryRoot, SchemaVersion


def test_bootstrap_creates_schema(data_root: Path) -> None:
    _, engine = bootstrap(data_root)
    with engine.connect() as conn:
        assert current_version(conn) >= 1
    with Session(engine) as session:
        versions = session.scalars(select(SchemaVersion)).all()
        assert any(v.version == 1 for v in versions)


def test_index_library_idempotent_and_gone(data_root: Path, library_root: Path) -> None:
    _, engine = bootstrap(data_root)

    with session_scope(engine) as session:
        ensure_library_root(session, library_root, label="fixture")
        stats1 = index_all_roots(session)
        file_ids_1 = set(session.scalars(select(File.file_id)).all())
        hashes_1 = set(session.scalars(select(File.content_hash)).all())
        paths_1 = {
            (p.relative_path, p.file_id, p.is_current, p.gone_at)
            for p in session.scalars(select(FilePath)).all()
        }

    assert stats1.roots == 1
    assert stats1.seen == 2
    assert stats1.upserted == 2
    assert stats1.gone == 0
    assert stats1.errors == 0
    assert len(file_ids_1) == 2
    assert "hello.txt" in {p[0] for p in paths_1}
    assert "subdir/note.md" in {p[0] for p in paths_1}
    assert all(p[2] == 1 and p[3] is None for p in paths_1)

    # Re-run: same logical rows, no new upserts beyond unchanged seen.
    with session_scope(engine) as session:
        stats2 = index_all_roots(session)
        file_ids_2 = set(session.scalars(select(File.file_id)).all())
        hashes_2 = set(session.scalars(select(File.content_hash)).all())
        path_count = session.scalar(select(func.count()).select_from(FilePath)) or 0
        root = session.scalars(select(LibraryRoot)).one()
        assert root.abs_path == str(library_root.resolve())

    assert stats2.seen == 2
    assert stats2.upserted == 0
    assert stats2.unchanged == 2
    assert stats2.gone == 0
    assert file_ids_2 == file_ids_1
    assert hashes_2 == hashes_1
    assert path_count == 2

    # Soft-detect gone path.
    (library_root / "hello.txt").unlink()

    with session_scope(engine) as session:
        stats3 = index_all_roots(session)
        remaining = session.scalars(
            select(FilePath).where(FilePath.relative_path == "hello.txt")
        ).one()
        note = session.scalars(
            select(FilePath).where(FilePath.relative_path == "subdir/note.md")
        ).one()
        current = session.scalar(
            select(func.count()).select_from(FilePath).where(FilePath.is_current == 1)
        )

    assert stats3.seen == 1
    assert stats3.gone == 1
    assert remaining.is_current == 0
    assert remaining.gone_at is not None
    assert note.is_current == 1
    assert note.gone_at is None
    assert current == 1

    # File returns: clear gone_at.
    (library_root / "hello.txt").write_bytes(b"hello homesync\n")

    with session_scope(engine) as session:
        stats4 = index_all_roots(session)
        restored = session.scalars(
            select(FilePath).where(FilePath.relative_path == "hello.txt")
        ).one()

    assert stats4.seen == 2
    assert stats4.gone == 0
    assert restored.is_current == 1
    assert restored.gone_at is None
