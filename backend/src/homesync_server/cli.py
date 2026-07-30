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
