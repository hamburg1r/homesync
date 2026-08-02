"""Server-side JPEG thumbnails for listed-mode previews."""

from __future__ import annotations

from io import BytesIO
from pathlib import Path

from PIL import Image, UnidentifiedImageError
from sqlalchemy.orm import Session

from homesync_server.models import File
from homesync_server.services import blobs as blob_svc
from homesync_server.services import catalog as catalog_svc
from homesync_server.storage import thumb_path, write_blob_atomic

# Small enough for listed-mode phone sync; not a substitute for full bytes.
THUMB_MAX_EDGE = 256
THUMB_JPEG_QUALITY = 70


class ThumbNotSupportedError(Exception):
    """File is not an image (or cannot be decoded as one)."""


class ThumbNotFoundError(Exception):
    """Source bytes missing — cannot generate a thumb."""


def is_image_candidate(file_row: File) -> bool:
    """True when the catalog hints that ``GET /v1/thumbs`` may succeed."""
    mime = (file_row.mime_type or "").strip().lower()
    return mime.startswith("image/")


def thumb_exists(data_root: Path, content_hash: str) -> bool:
    try:
        return thumb_path(data_root, content_hash).is_file()
    except ValueError:
        return False


def ensure_thumb(
    session: Session,
    data_root: Path,
    file_id: str,
) -> Path:
    """Return a cached JPEG thumb path, generating on first request.

    Raises ``catalog_svc.NotFoundError``, ``ThumbNotSupportedError``,
    or ``ThumbNotFoundError``.
    """
    file_row = catalog_svc.get_file(session, file_id)
    if file_row.deleted_at is not None:
        raise catalog_svc.NotFoundError(file_id)

    dest = thumb_path(data_root, file_row.content_hash)
    if dest.is_file():
        return dest

    if not is_image_candidate(file_row):
        raise ThumbNotSupportedError(
            f"not an image mime: {file_row.mime_type!r}"
        )

    try:
        src, _size = blob_svc.open_blob_bytes(
            session, data_root, file_row.hash_algo, file_row.content_hash
        )
    except blob_svc.BlobNotFoundError as exc:
        raise ThumbNotFoundError(str(exc)) from exc

    try:
        jpeg = _render_jpeg_thumb(src)
    except (OSError, UnidentifiedImageError, ValueError) as exc:
        raise ThumbNotSupportedError(f"cannot decode image: {exc}") from exc

    write_blob_atomic(dest, jpeg)
    return dest


def _render_jpeg_thumb(src: Path) -> bytes:
    with Image.open(src) as img:
        if img.mode != "RGB":
            img = img.convert("RGB")
        img.thumbnail((THUMB_MAX_EDGE, THUMB_MAX_EDGE), Image.Resampling.LANCZOS)
        buf = BytesIO()
        img.save(buf, format="JPEG", quality=THUMB_JPEG_QUALITY, optimize=True)
        return buf.getvalue()
