"""Copy the Homesync managed data root to a new path (e.g. onto a larger disk)."""

from __future__ import annotations

import argparse
import logging
import shutil
import sys
from dataclasses import dataclass
from pathlib import Path

from homesync_server.config import (
    config_path,
    data_root,
    ensure_data_dirs,
    write_data_dir,
)

logger = logging.getLogger(__name__)


class MigrateError(RuntimeError):
    """Migration refused or failed verification."""


@dataclass(frozen=True)
class MigrateResult:
    source: Path
    dest: Path
    config_written: Path | None
    source_deleted: bool
    empty_source: bool


def _is_nonempty_dir(path: Path) -> bool:
    return path.is_dir() and any(path.iterdir())


def migrate_data(
    *,
    dest: Path,
    source: Path | None = None,
    force: bool = False,
    write_config: bool = True,
    delete_source: bool = False,
    config_file: Path | None = None,
) -> MigrateResult:
    """Copy managed store from ``source`` to ``dest`` and optionally update config."""
    src = (source if source is not None else data_root()).expanduser().resolve()
    dst = dest.expanduser().resolve()

    if src == dst:
        raise MigrateError(f"source and destination are the same path: {src}")

    if not src.exists():
        raise MigrateError(f"source data root does not exist: {src}")
    if not src.is_dir():
        raise MigrateError(f"source is not a directory: {src}")

    empty_source = not any(src.iterdir())
    if empty_source:
        logger.warning("source data root is empty: %s", src)

    if dst.exists():
        if dst.is_file():
            raise MigrateError(f"destination exists and is a file: {dst}")
        if _is_nonempty_dir(dst):
            if not force:
                raise MigrateError(
                    f"destination exists and is not empty: {dst} (pass --force to overwrite)"
                )
            logger.warning("removing existing destination contents: %s", dst)
            shutil.rmtree(dst)

    logger.info("copying %s -> %s", src, dst)
    if empty_source:
        ensure_data_dirs(dst)
    elif dst.exists():
        # Empty destination directory left in place.
        shutil.copytree(src, dst, dirs_exist_ok=True)
    else:
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(src, dst)

    catalog = dst / "catalog.sqlite"
    if not empty_source and not catalog.is_file():
        raise MigrateError(
            f"migration verification failed: missing catalog.sqlite under {dst}"
        )

    ensure_data_dirs(dst)

    cfg_written: Path | None = None
    if write_config:
        cfg_written = write_data_dir(dst, path=config_file)
        logger.info("wrote data_dir to %s", cfg_written)

    source_deleted = False
    if delete_source:
        logger.info("removing source: %s", src)
        shutil.rmtree(src)
        source_deleted = True

    return MigrateResult(
        source=src,
        dest=dst,
        config_written=cfg_written,
        source_deleted=source_deleted,
        empty_source=empty_source,
    )


def main_migrate(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="homesync-migrate-data",
        description=(
            "Copy the Homesync managed data root (catalog + blobs) to another path "
            "and point config.toml at it. Stop homesync-server before migrating."
        ),
    )
    parser.add_argument(
        "--to",
        type=Path,
        required=True,
        help="Destination data root (e.g. /mnt/hdd/homesync).",
    )
    parser.add_argument(
        "--from",
        dest="from_path",
        type=Path,
        default=None,
        help="Source data root (default: current resolved data_root).",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Overwrite a non-empty destination.",
    )
    parser.add_argument(
        "--no-write-config",
        action="store_true",
        help="Do not update ~/.config/homesync/config.toml (or $HOMESYNC_CONFIG).",
    )
    parser.add_argument(
        "--delete-source",
        action="store_true",
        help="Remove the source directory after a successful copy + verify.",
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

    logger.info(
        "Stop homesync-server before migrating so SQLite is not open for write."
    )
    logger.info("current data_root would be: %s", data_root())
    logger.info("config path: %s", config_path())

    try:
        result = migrate_data(
            dest=args.to,
            source=args.from_path,
            force=args.force,
            write_config=not args.no_write_config,
            delete_source=args.delete_source,
        )
    except MigrateError as exc:
        logger.error("%s", exc)
        return 1

    logger.info("migrated: %s -> %s", result.source, result.dest)
    if result.config_written:
        logger.info("config updated: %s", result.config_written)
    if result.source_deleted:
        logger.info("source removed")
    else:
        logger.info("source left in place (pass --delete-source to remove)")
    logger.info("next homesync-server / homesync-index run will use: %s", result.dest)
    return 0


def run_migrate() -> None:
    sys.exit(main_migrate())
