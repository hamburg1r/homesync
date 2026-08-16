"""Linux catalog CLI — same jobs as the Flutter client, over HTTP."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from collections.abc import Sequence
from pathlib import Path
from typing import Any

from homesync_server.client.api import ApiError, ConflictPending, HomesyncClient
from homesync_server.client.config import (
    ClientSettings,
    default_device_name,
    default_pin_dir,
    load_client_settings,
)
from homesync_server.client.ops import (
    ResolveError,
    ensure_registered,
    files_under_prefix,
    ingest_path,
    iter_walk_files,
    load_pin_map,
    pin_file,
    resolve_file,
    unpin_file,
)
from homesync_server.schemas.catalog import FileOut


def _emit(args: argparse.Namespace, payload: Any) -> None:
    if getattr(args, "json", False):
        if hasattr(payload, "model_dump"):
            print(json.dumps(payload.model_dump(), indent=2, default=str))
        else:
            print(json.dumps(payload, indent=2, default=str))
        return
    if isinstance(payload, str):
        print(payload)
        return
    print(payload)


def _file_line(file: FileOut) -> str:
    title = file.title or file.file_id
    tags = ",".join(file.tags) if file.tags else "-"
    deleted = " tombstone" if file.deleted_at else ""
    return (
        f"{file.file_id}  {title}  {file.size_bytes}B  "
        f"{file.mime_type or '-'}  tags={tags}{deleted}"
    )


def _client_from(args: argparse.Namespace, settings: ClientSettings) -> HomesyncClient:
    url = args.url or settings.base_url
    return HomesyncClient(url, http=getattr(args, "_http", None))


def cmd_status(args: argparse.Namespace, settings: ClientSettings) -> int:
    client = _client_from(args, settings)
    health = client.health()
    if args.json:
        _emit(
            args,
            {
                "health": health,
                "base_url": args.url or settings.base_url,
                "device_id": settings.device_id,
                "device_name": settings.device_name,
                "pin_dir": str(settings.pin_dir or default_pin_dir()),
            },
        )
        return 0
    print(f"health     {health.get('status', health)}")
    print(f"url        {args.url or settings.base_url}")
    print(f"device_id  {settings.device_id or '(run homesync init)'}")
    print(f"device     {settings.device_name or default_device_name()}")
    print(f"pin_dir    {settings.pin_dir or default_pin_dir()}")
    return 0


def cmd_init(args: argparse.Namespace, settings: ClientSettings) -> int:
    next_settings = ClientSettings(
        base_url=(args.url or settings.base_url).rstrip("/"),
        device_id=args.device_id or settings.device_id,
        device_name=args.name or settings.device_name or default_device_name(),
        pin_dir=Path(args.pin_dir).expanduser().resolve()
        if args.pin_dir
        else settings.pin_dir,
    )
    client = _client_from(args, next_settings)
    registered = ensure_registered(client, next_settings, persist=True)
    if args.json:
        _emit(
            args,
            {
                "device_id": registered.device_id,
                "device_name": registered.device_name,
                "base_url": registered.base_url,
            },
        )
        return 0
    print(f"registered {registered.device_name} ({registered.device_id})")
    print(f"url        {registered.base_url}")
    return 0


def cmd_devices(args: argparse.Namespace, settings: ClientSettings) -> int:
    client = _client_from(args, settings)
    if args.devices_cmd == "use":
        next_settings = ClientSettings(
            base_url=args.url or settings.base_url,
            device_id=args.device_id,
            device_name=settings.device_name or default_device_name(),
            pin_dir=settings.pin_dir,
        )
        ensure_registered(client, next_settings, persist=True)
        print(f"using device {args.device_id}")
        return 0
    rows = client.list_devices()
    if args.json:
        _emit(args, rows)
        return 0
    current = settings.device_id
    for row in rows:
        mark = "*" if row.get("device_id") == current else " "
        print(
            f"{mark} {row.get('device_id')}  {row.get('name')}  "
            f"{row.get('kind')}  last_seen={row.get('last_seen_at')}"
        )
    return 0


def cmd_ls(args: argparse.Namespace, settings: ClientSettings) -> int:
    client = _client_from(args, settings)
    files = client.list_files(
        q=args.q,
        include_deleted=args.deleted,
        limit=args.limit,
        offset=args.offset,
    )
    if args.json:
        _emit(args, [f.model_dump() for f in files])
        return 0
    if not files:
        print("(empty catalog)")
        return 0
    for file in files:
        print(_file_line(file))
    return 0


def cmd_show(args: argparse.Namespace, settings: ClientSettings) -> int:
    client = _client_from(args, settings)
    file = resolve_file(client, args.file)
    avail = None
    if settings.device_id:
        avail = client.get_availability(file.file_id, settings.device_id)
    pins = load_pin_map()
    local = pins.get(file.file_id)
    if args.json:
        payload = file.model_dump()
        payload["availability"] = avail.model_dump() if avail else None
        payload["local_path"] = local
        _emit(args, payload)
        return 0
    print(f"file_id     {file.file_id}")
    print(f"title       {file.title}")
    print(f"hash        {file.hash_algo}:{file.content_hash}")
    print(f"size        {file.size_bytes}")
    print(f"mime        {file.mime_type}")
    print(f"tags        {', '.join(file.tags) or '-'}")
    print(f"notes       {file.notes or '-'}")
    print(f"updated     {file.updated_at}")
    print(f"deleted     {file.deleted_at or '-'}")
    print(f"mode        {avail.mode if avail else 'listed'}")
    print(f"local       {local or '-'}")
    return 0


def cmd_tag(args: argparse.Namespace, settings: ClientSettings) -> int:
    client = _client_from(args, settings)
    file = resolve_file(client, args.file)
    tags = list(file.tags)
    if args.set is not None:
        tags = [t.strip() for t in args.set.split(",") if t.strip()]
    if args.add:
        for name in args.add:
            if name not in tags:
                tags.append(name)
    if args.remove:
        drop = {n.lower() for n in args.remove}
        tags = [t for t in tags if t.lower() not in drop]
    updated = client.put_tags(file.file_id, tags)
    if args.json:
        _emit(args, updated.model_dump())
        return 0
    print(f"{updated.file_id}  tags={', '.join(updated.tags) or '-'}")
    return 0


def cmd_edit(args: argparse.Namespace, settings: ClientSettings) -> int:
    client = _client_from(args, settings)
    file = resolve_file(client, args.file)
    updated = client.patch_file(
        file.file_id,
        title=args.title,
        notes=args.notes,
        source_kind=args.source_kind,
    )
    _emit(args, updated.model_dump() if args.json else _file_line(updated))
    return 0


def cmd_pin(args: argparse.Namespace, settings: ClientSettings) -> int:
    client = _client_from(args, settings)
    settings = ensure_registered(client, settings, persist=True)
    file = resolve_file(client, args.file)
    dest = pin_file(
        client,
        settings,
        file,
        directory=Path(args.to).expanduser().resolve() if args.to else None,
        file_name=args.name,
        overwrite=args.overwrite,
    )
    if args.json:
        _emit(args, {"file_id": file.file_id, "path": str(dest), "mode": "pinned"})
        return 0
    print(f"pinned {file.title or file.file_id} -> {dest}")
    return 0


def cmd_unpin(args: argparse.Namespace, settings: ClientSettings) -> int:
    client = _client_from(args, settings)
    settings = ensure_registered(client, settings, persist=True)
    file = resolve_file(client, args.file)
    unpin_file(client, settings, file, delete_local=not args.keep_bytes)
    if args.json:
        _emit(args, {"file_id": file.file_id, "mode": "listed"})
        return 0
    print(f"listed {file.title or file.file_id} (kept on PC)")
    return 0


def cmd_get(args: argparse.Namespace, settings: ClientSettings) -> int:
    client = _client_from(args, settings)
    file = resolve_file(client, args.file)
    dest = Path(args.out).expanduser().resolve()
    if dest.is_dir() or str(args.out).endswith("/"):
        dest.mkdir(parents=True, exist_ok=True)
        dest = dest / (file.title or file.file_id)
    dest.parent.mkdir(parents=True, exist_ok=True)
    client.download_blob(file.hash_algo, file.content_hash, dest)
    if args.json:
        _emit(args, {"file_id": file.file_id, "path": str(dest)})
        return 0
    print(str(dest))
    return 0


def cmd_ingest(args: argparse.Namespace, settings: ClientSettings) -> int:
    client = _client_from(args, settings)
    settings = ensure_registered(client, settings, persist=True)
    paths: list[Path] = []
    if args.walk:
        root = Path(args.walk).expanduser().resolve()
        if not root.is_dir():
            raise ResolveError(f"not a directory: {args.walk}")
        paths.extend(iter_walk_files(root))
    paths.extend(Path(p) for p in args.paths)
    if not paths:
        raise ResolveError("pass files and/or --walk DIR")
    created: list[FileOut] = []
    for path in paths:
        rel = None
        if args.walk:
            try:
                rel = str(path.resolve().relative_to(Path(args.walk).resolve()))
            except ValueError:
                rel = path.name
        row = ingest_path(
            client,
            settings,
            path,
            source_kind=args.source_kind,
            relative_path=rel,
        )
        created.append(row)
        if not args.json:
            print(f"ingested {row.file_id}  {row.title}")
    if args.json:
        _emit(args, [r.model_dump() for r in created])
    return 0


def cmd_rm(args: argparse.Namespace, settings: ClientSettings) -> int:
    client = _client_from(args, settings)
    file = resolve_file(client, args.file)
    updated = client.delete_file(file.file_id)
    if args.json:
        _emit(args, updated.model_dump())
        return 0
    print(f"tombstone {updated.file_id}  {updated.title}")
    return 0


def cmd_versions(args: argparse.Namespace, settings: ClientSettings) -> int:
    client = _client_from(args, settings)
    file = resolve_file(client, args.file)
    versions = client.versions(file.file_id)
    if args.json:
        _emit(args, versions.model_dump())
        return 0
    print(f"head {versions.head.content_hash}  {versions.head.created_at}")
    for ver in versions.versions:
        mark = "*" if ver.is_head else " "
        print(
            f"{mark} {ver.version_id}  {ver.content_hash}  "
            f"{ver.size_bytes}B  {ver.note or ''}"
        )
    return 0


def cmd_tags(args: argparse.Namespace, settings: ClientSettings) -> int:
    client = _client_from(args, settings)
    tags = client.list_tags()
    if args.json:
        _emit(args, [t.model_dump() for t in tags])
        return 0
    for tag in tags:
        print(f"{tag.tag_id}  {tag.name}")
    return 0


def cmd_conflicts(args: argparse.Namespace, settings: ClientSettings) -> int:
    client = _client_from(args, settings)
    rows = client.list_conflicts(state=args.state)
    if args.json:
        _emit(args, [r.model_dump() for r in rows])
        return 0
    if not rows:
        print("(no conflicts)")
        return 0
    for row in rows:
        print(f"{row.conflict_id}  file={row.file_id}  {row.state}")
    return 0


def cmd_conflict(args: argparse.Namespace, settings: ClientSettings) -> int:
    client = _client_from(args, settings)
    if args.conflict_cmd == "show":
        row = client.get_conflict(args.conflict_id)
        _emit(args, row.model_dump() if args.json else json.dumps(row.model_dump(), indent=2))
        return 0
    if args.conflict_cmd == "recheck":
        body = client.recheck_conflict(args.conflict_id)
        _emit(args, body if args.json else json.dumps(body, indent=2))
        return 0
    payload: dict[str, Any] = {"mode": args.mode}
    if args.hash:
        payload["content_hash"] = args.hash
    if args.note:
        payload["note"] = args.note
    if args.base_hash:
        payload["base_hash"] = args.base_hash
    if args.incoming_hash:
        payload["incoming_hash"] = args.incoming_hash
    if args.choice:
        payload["choices"] = []
        for item in args.choice:
            uuid, _, keep = item.partition("=")
            payload["choices"].append({"entry_uuid": uuid, "keep": keep or "base"})
    updated = client.resolve_conflict(args.conflict_id, payload)
    _emit(args, updated.model_dump() if args.json else _file_line(updated))
    return 0


def cmd_secret(args: argparse.Namespace, settings: ClientSettings) -> int:
    client = _client_from(args, settings)
    file = resolve_file(client, args.file)
    if args.password_file:
        password = Path(args.password_file).read_text(encoding="utf-8").rstrip("\n")
    else:
        password = args.password
    if not password:
        raise ResolveError("pass --password or --password-file")
    client.put_kdbx_secret(file.file_id, password)
    print(f"stored kdbx secret for {file.file_id}")
    return 0


def cmd_gc(args: argparse.Namespace, settings: ClientSettings) -> int:
    client = _client_from(args, settings)
    result = client.gc(
        {
            "dry_run": args.dry_run,
            "min_age_seconds": args.min_age,
            "file_ids": args.file_id or None,
        }
    )
    if args.json:
        _emit(args, result.model_dump())
        return 0
    verb = "would purge" if result.dry_run else "purged"
    print(
        f"{verb} files={len(result.purged_file_ids)} "
        f"blobs={len(result.deleted_blobs)} bytes={result.bytes_reclaimed}"
    )
    return 0


def cmd_keep_folder(args: argparse.Namespace, settings: ClientSettings) -> int:
    client = _client_from(args, settings)
    settings = ensure_registered(client, settings, persist=True)
    dest = Path(args.to).expanduser().resolve() if args.to else None
    files = files_under_prefix(client, args.prefix)
    pinned = []
    for file in files:
        path = pin_file(client, settings, file, directory=dest)
        pinned.append((file, path))
        if not args.json:
            print(f"pinned {file.title or file.file_id} -> {path}")
    if args.json:
        _emit(
            args,
            [{"file_id": f.file_id, "path": str(p)} for f, p in pinned],
        )
    elif not pinned:
        print("(no files under prefix)")
    return 0


def cmd_open(args: argparse.Namespace, settings: ClientSettings) -> int:
    client = _client_from(args, settings)
    settings = ensure_registered(client, settings, persist=True)
    file = resolve_file(client, args.file)
    pins = load_pin_map()
    local = pins.get(file.file_id)
    path = Path(local) if local and Path(local).is_file() else pin_file(
        client, settings, file
    )
    if args.json:
        _emit(args, {"path": str(path)})
        return 0
    opener = args.opener or os_open()
    subprocess.run([opener, str(path)], check=False)
    print(str(path))
    return 0


def os_open() -> str:
    if sys.platform == "darwin":
        return "open"
    return "xdg-open"


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="homesync",
        description=(
            "Linux catalog client (browse, pin, ingest) talking to homesync-server, "
            "same HTTP surface as the Android app."
        ),
    )
    parser.add_argument("--url", help="API base (default: config / http://127.0.0.1:8787)")
    parser.add_argument("--json", action="store_true", help="JSON output")
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("status", help="Daemon health and local client identity")

    init = sub.add_parser("init", help="Register this machine as a linux device")
    init.add_argument("--name", help="Device name (default: hostname)")
    init.add_argument("--device-id", help="Reuse / reclaim an existing device_id")
    init.add_argument("--pin-dir", help="Default folder for materialized pins")

    devices = sub.add_parser("devices", help="List or reclaim devices")
    dsub = devices.add_subparsers(dest="devices_cmd")
    use = dsub.add_parser("use", help="Bind this CLI to an existing device_id")
    use.add_argument("device_id")

    ls = sub.add_parser("ls", help="List catalog files (metadata only)")
    ls.add_argument("-q", "--q", dest="q", help="Search title / notes / tags")
    ls.add_argument("--deleted", action="store_true", help="Include tombstones")
    ls.add_argument("--limit", type=int, default=100)
    ls.add_argument("--offset", type=int, default=0)

    show = sub.add_parser("show", help="File detail")
    show.add_argument("file", help="file_id or unique title")

    tag = sub.add_parser("tag", help="Replace / add / remove tags")
    tag.add_argument("file")
    tag.add_argument("--set", help="Comma-separated replacement list")
    tag.add_argument("--add", action="append", default=[], help="Add a tag (repeatable)")
    tag.add_argument(
        "--remove", action="append", default=[], help="Remove a tag (repeatable)"
    )

    edit = sub.add_parser("edit", help="Patch title / notes / source_kind")
    edit.add_argument("file")
    edit.add_argument("--title")
    edit.add_argument("--notes")
    edit.add_argument("--source-kind")

    pin = sub.add_parser("pin", help="Pin + download bytes (Bring to device)")
    pin.add_argument("file")
    pin.add_argument("--to", help="Destination directory")
    pin.add_argument("--name", help="Destination basename")
    pin.add_argument("--overwrite", action="store_true")

    unpin = sub.add_parser(
        "unpin", help="Keep on PC only: listed, drop local pin bytes"
    )
    unpin.add_argument("file")
    unpin.add_argument(
        "--keep-bytes",
        action="store_true",
        help="Leave local copy; only clear pinned availability",
    )

    getp = sub.add_parser("get", help="Download bytes without changing availability")
    getp.add_argument("file")
    getp.add_argument("--out", required=True, help="Output file or directory")

    ingest = sub.add_parser("ingest", help="Upload local files into the catalog")
    ingest.add_argument("paths", nargs="*", help="Files to ingest")
    ingest.add_argument("--walk", help="Recurse a folder (skip hidden)")
    ingest.add_argument("--source-kind", default="manual")

    rm = sub.add_parser("rm", help="Soft-delete on the PC catalog")
    rm.add_argument("file")

    ver = sub.add_parser("versions", help="Content history for a file")
    ver.add_argument("file")

    sub.add_parser("tags", help="List tag vocabulary")

    conflicts = sub.add_parser("conflicts", help="List KeePass conflict outbox")
    conflicts.add_argument("--state", default="active")

    conflict = sub.add_parser("conflict", help="Show / resolve / recheck a conflict")
    csub = conflict.add_subparsers(dest="conflict_cmd", required=True)
    cshow = csub.add_parser("show")
    cshow.add_argument("conflict_id")
    cre = csub.add_parser("recheck")
    cre.add_argument("conflict_id")
    cresol = csub.add_parser("resolve")
    cresol.add_argument("conflict_id")
    cresol.add_argument("--mode", default="candidate")
    cresol.add_argument("--hash", help="Candidate or uploaded content hash")
    cresol.add_argument("--note")
    cresol.add_argument("--base-hash")
    cresol.add_argument("--incoming-hash")
    cresol.add_argument(
        "--choice",
        action="append",
        default=[],
        help="entries mode: UUID=base|incoming|discard",
    )

    secret = sub.add_parser("secret", help="Store KeePass password for a file")
    secret.add_argument("file")
    secret.add_argument("--password")
    secret.add_argument("--password-file")

    gc = sub.add_parser("gc", help="POST /v1/gc (hard-purge tombstones)")
    gc.add_argument("--dry-run", action="store_true")
    gc.add_argument("--min-age", type=int, default=0)
    gc.add_argument("--file-id", action="append", default=[])

    keep = sub.add_parser(
        "keep-folder",
        help="Pin every catalog file under a relative_path prefix",
    )
    keep.add_argument("prefix")
    keep.add_argument("--to", help="Destination directory")

    openp = sub.add_parser("open", help="Pin if needed, then xdg-open")
    openp.add_argument("file")
    openp.add_argument("--opener", help="Override opener binary")

    return parser


def dispatch(args: argparse.Namespace, settings: ClientSettings) -> int:
    handlers = {
        "status": cmd_status,
        "init": cmd_init,
        "devices": cmd_devices,
        "ls": cmd_ls,
        "show": cmd_show,
        "tag": cmd_tag,
        "edit": cmd_edit,
        "pin": cmd_pin,
        "unpin": cmd_unpin,
        "get": cmd_get,
        "ingest": cmd_ingest,
        "rm": cmd_rm,
        "versions": cmd_versions,
        "tags": cmd_tags,
        "conflicts": cmd_conflicts,
        "conflict": cmd_conflict,
        "secret": cmd_secret,
        "gc": cmd_gc,
        "keep-folder": cmd_keep_folder,
        "open": cmd_open,
    }
    return handlers[args.cmd](args, settings)


def main(argv: Sequence[str] | None = None, *, http: Any | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    args._http = http
    try:
        settings = load_client_settings()
        if args.url:
            settings = ClientSettings(
                base_url=args.url.rstrip("/"),
                device_id=settings.device_id,
                device_name=settings.device_name,
                pin_dir=settings.pin_dir,
            )
        return dispatch(args, settings)
    except (ApiError, ResolveError, ConflictPending) as exc:
        print(f"homesync: {exc}", file=sys.stderr)
        return 1


def run() -> None:
    sys.exit(main())
