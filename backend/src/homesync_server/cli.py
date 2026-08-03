"""CLI entrypoints for Homesync server utilities."""

from __future__ import annotations

import argparse
import logging
import sys
from pathlib import Path

from sqlalchemy import func, select

from homesync_server.config import data_root
from homesync_server.db import bootstrap, session_scope
from homesync_server.indexer import ensure_library_root, index_all_roots
from homesync_server.models import File, FilePath
from homesync_server.services import gc as gc_svc


def main_index(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="homesync-index",
        description="Index library roots into the Homesync catalog (hash-in-place).",
    )
    parser.add_argument(
        "--root",
        type=Path,
        action="append",
        default=[],
        help="Library folder to register (repeatable). Indexed with all enabled roots.",
    )
    parser.add_argument(
        "--label",
        type=str,
        default=None,
        help="Label for a single --root (ignored if multiple --root).",
    )
    parser.add_argument(
        "-v",
        "--verbose",
        action="store_true",
        help="Debug logging.",
    )
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(levelname)s %(name)s: %(message)s",
    )

    root = data_root()
    _, engine = bootstrap(root)
    logging.info("data root: %s", root)

    with session_scope(engine) as session:
        for lib in args.root:
            label = args.label if len(args.root) == 1 else None
            ensure_library_root(session, lib, label=label)
            logging.info("registered library root: %s", lib.resolve())

        stats = index_all_roots(session)
        file_count = session.scalar(select(func.count()).select_from(File)) or 0
        path_count = session.scalar(select(func.count()).select_from(FilePath)) or 0
        current_count = (
            session.scalar(
                select(func.count()).select_from(FilePath).where(FilePath.is_current == 1)
            )
            or 0
        )

    logging.info(
        "index complete: roots=%d seen=%d upserted=%d unchanged=%d gone=%d errors=%d",
        stats.roots,
        stats.seen,
        stats.upserted,
        stats.unchanged,
        stats.gone,
        stats.errors,
    )
    logging.info(
        "catalog: files=%d paths=%d current_paths=%d",
        file_count,
        path_count,
        current_count,
    )
    return 0 if stats.errors == 0 else 1


def run_index() -> None:
    sys.exit(main_index())


def main_gc(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="homesync-gc",
        description=(
            "Hard-purge soft-deleted catalog rows and unreferenced managed blobs/thumbs."
        ),
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Report what would be deleted without writing.",
    )
    parser.add_argument(
        "--min-age",
        type=int,
        default=0,
        metavar="SECONDS",
        help="Only purge tombstones with deleted_at at least this old (default 0).",
    )
    parser.add_argument(
        "--file-id",
        action="append",
        default=[],
        dest="file_ids",
        help="Limit tombstone purge to these file_ids (repeatable).",
    )
    parser.add_argument(
        "--no-tombstones",
        action="store_true",
        help="Skip hard-purging soft-deleted catalog rows.",
    )
    parser.add_argument(
        "--no-blobs",
        action="store_true",
        help="Skip unreferenced managed blob/thumb deletion.",
    )
    parser.add_argument(
        "--no-uploads",
        action="store_true",
        help="Skip expired upload partial cleanup.",
    )
    parser.add_argument(
        "-v",
        "--verbose",
        action="store_true",
        help="Debug logging.",
    )
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(levelname)s %(name)s: %(message)s",
    )

    root = data_root()
    _, engine = bootstrap(root)
    logging.info("data root: %s", root)

    with session_scope(engine) as session:
        result = gc_svc.run_gc(
            session,
            root,
            dry_run=args.dry_run,
            purge_tombstones=not args.no_tombstones,
            purge_blobs=not args.no_blobs,
            purge_uploads=not args.no_uploads,
            min_age_seconds=args.min_age,
            file_ids=args.file_ids or None,
        )

    prefix = "would purge" if result.dry_run else "purged"
    logging.info(
        "%s files=%d blobs=%d thumbs=%d uploads=%d bytes=%d skipped_conflicts=%d",
        prefix,
        len(result.purged_file_ids),
        len(result.deleted_blobs),
        len(result.deleted_thumbs),
        result.deleted_uploads,
        result.bytes_reclaimed,
        len(result.skipped_open_conflict_ids),
    )
    if result.purged_file_ids:
        logging.info("file_ids: %s", ", ".join(result.purged_file_ids))
    if result.skipped_open_conflict_ids:
        logging.info(
            "skipped open kdbx conflicts: %s",
            ", ".join(result.skipped_open_conflict_ids),
        )
    return 0


def run_gc() -> None:
    sys.exit(main_gc())
