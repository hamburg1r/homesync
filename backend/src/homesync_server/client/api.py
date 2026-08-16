"""HTTP client for Homesync /v1 (same surface the Flutter app uses)."""

from __future__ import annotations

import json
from collections.abc import Callable
from pathlib import Path
from typing import Any

import httpx

from homesync_server.config import DEFAULT_HASH_ALGO
from homesync_server.schemas.catalog import (
    AvailabilityOut,
    CatalogDeltaOut,
    FileOut,
    FileVersionsOut,
    GcRunOut,
    KdbxConflictOut,
    TagOut,
)
from homesync_server.storage import hash_file

UPLOAD_CHUNK = 4 * 1024 * 1024


class ApiError(Exception):
    def __init__(self, message: str, status_code: int | None = None) -> None:
        self.status_code = status_code
        super().__init__(message)


class ConflictPending(ApiError):
    """HTTP 202: kdbx content update opened an outbox."""

    def __init__(self, payload: dict[str, Any]) -> None:
        self.payload = payload
        super().__init__("kdbx conflict pending", status_code=202)


def _detail(response: httpx.Response) -> str | None:
    text = response.text.strip()
    if not text:
        return None
    try:
        decoded = response.json()
    except json.JSONDecodeError:
        return text[:200]
    if isinstance(decoded, dict):
        detail = decoded.get("detail")
        if isinstance(detail, str):
            return detail
        if detail is not None:
            return str(detail)
    return text[:200]


class HomesyncClient:
    def __init__(
        self,
        base_url: str,
        *,
        http: httpx.Client | None = None,
        timeout: float = 30.0,
    ) -> None:
        self.base_url = base_url.rstrip("/")
        self._owns = http is None
        self._http = http or httpx.Client(base_url=self.base_url, timeout=timeout)

    def close(self) -> None:
        if self._owns:
            self._http.close()

    def _request(
        self,
        method: str,
        path: str,
        *,
        expected: tuple[int, ...] = (200,),
        **kwargs: Any,
    ) -> httpx.Response:
        try:
            response = self._http.request(method, path, **kwargs)
        except httpx.TimeoutException as exc:
            raise ApiError("request timed out") from exc
        except httpx.HTTPError as exc:
            raise ApiError(f"network error: {exc}") from exc
        if response.status_code not in expected:
            detail = _detail(response)
            msg = detail or f"HTTP {response.status_code}"
            raise ApiError(msg, status_code=response.status_code)
        return response

    def health(self) -> dict[str, str]:
        body = self._request("GET", "/health").json()
        if not isinstance(body, dict):
            raise ApiError("invalid health response")
        return {str(k): str(v) for k, v in body.items()}

    def register_device(
        self,
        device_id: str,
        name: str,
        kind: str = "linux",
    ) -> dict[str, Any]:
        return self._request(
            "POST",
            "/v1/devices",
            json={"device_id": device_id, "name": name, "kind": kind},
        ).json()

    def list_devices(self) -> list[dict[str, Any]]:
        body = self._request("GET", "/v1/devices").json()
        if not isinstance(body, list):
            raise ApiError("invalid devices response")
        return body

    def list_files(
        self,
        *,
        q: str | None = None,
        include_deleted: bool = False,
        limit: int = 100,
        offset: int = 0,
    ) -> list[FileOut]:
        params: dict[str, str | int | bool] = {
            "limit": limit,
            "offset": offset,
            "include_deleted": include_deleted,
        }
        if q:
            params["q"] = q
        body = self._request("GET", "/v1/files", params=params).json()
        if not isinstance(body, list):
            raise ApiError("invalid files response")
        return [FileOut.model_validate(row) for row in body]

    def get_file(self, file_id: str) -> FileOut:
        return FileOut.model_validate(
            self._request("GET", f"/v1/files/{file_id}").json()
        )

    def patch_file(
        self,
        file_id: str,
        *,
        title: str | None = None,
        notes: str | None = None,
        source_kind: str | None = None,
    ) -> FileOut:
        payload: dict[str, str] = {}
        if title is not None:
            payload["title"] = title
        if notes is not None:
            payload["notes"] = notes
        if source_kind is not None:
            payload["source_kind"] = source_kind
        return FileOut.model_validate(
            self._request("PATCH", f"/v1/files/{file_id}", json=payload).json()
        )

    def delete_file(self, file_id: str) -> FileOut:
        return FileOut.model_validate(
            self._request("DELETE", f"/v1/files/{file_id}").json()
        )

    def put_tags(self, file_id: str, tags: list[str]) -> FileOut:
        return FileOut.model_validate(
            self._request(
                "PUT", f"/v1/files/{file_id}/tags", json={"tags": tags}
            ).json()
        )

    def list_tags(self) -> list[TagOut]:
        body = self._request("GET", "/v1/tags").json()
        if not isinstance(body, list):
            raise ApiError("invalid tags response")
        return [TagOut.model_validate(row) for row in body]

    def put_availability(
        self, file_id: str, device_id: str, mode: str
    ) -> AvailabilityOut:
        return AvailabilityOut.model_validate(
            self._request(
                "PUT",
                f"/v1/files/{file_id}/availability/{device_id}",
                json={"mode": mode},
            ).json()
        )

    def get_availability(self, file_id: str, device_id: str) -> AvailabilityOut | None:
        try:
            return AvailabilityOut.model_validate(
                self._request(
                    "GET", f"/v1/files/{file_id}/availability/{device_id}"
                ).json()
            )
        except ApiError as exc:
            if exc.status_code == 404:
                return None
            raise

    def catalog_delta(
        self,
        *,
        since: str | None = None,
        purge_since: str | None = None,
        limit: int = 500,
    ) -> CatalogDeltaOut:
        params: dict[str, str | int] = {"limit": limit}
        if since:
            params["since"] = since
        if purge_since:
            params["purge_since"] = purge_since
        return CatalogDeltaOut.model_validate(
            self._request("GET", "/v1/catalog/delta", params=params).json()
        )

    def download_blob(self, algo: str, content_hash: str, dest: Path) -> None:
        dest.parent.mkdir(parents=True, exist_ok=True)
        response = self._request("GET", f"/v1/blobs/{algo}/{content_hash}")
        dest.write_bytes(response.content)

    def upload_blob(
        self,
        path: Path,
        *,
        algo: str = DEFAULT_HASH_ALGO,
        content_hash: str | None = None,
        on_progress: Callable[[int, int], None] | None = None,
    ) -> str:
        digest = content_hash or hash_file(path, algo)
        size = path.stat().st_size
        begin = self._request(
            "POST",
            "/v1/blob-uploads",
            json={"algo": algo, "content_hash": digest, "size_bytes": size},
        ).json()
        offset = int(begin["offset"])
        if begin.get("complete") or offset >= size:
            if on_progress:
                on_progress(size, size)
            return digest
        upload_id = begin["upload_id"]
        with path.open("rb") as fh:
            while offset < size:
                fh.seek(offset)
                chunk = fh.read(min(UPLOAD_CHUNK, size - offset))
                response = self._request(
                    "PATCH",
                    f"/v1/blob-uploads/{upload_id}",
                    content=chunk,
                    headers={"Upload-Offset": str(offset)},
                    expected=(200, 204),
                )
                acked = response.headers.get("upload-offset") or response.headers.get(
                    "Upload-Offset"
                )
                if acked is None:
                    raise ApiError("missing Upload-Offset ack")
                offset = int(acked)
                if on_progress:
                    on_progress(offset, size)
                if response.headers.get("x-upload-complete") == "1":
                    break
        return digest

    def create_file(self, body: dict[str, Any]) -> FileOut:
        return FileOut.model_validate(
            self._request("POST", "/v1/files", json=body).json()
        )

    def update_content(self, file_id: str, body: dict[str, Any]) -> FileOut:
        response = self._request(
            "POST",
            f"/v1/files/{file_id}/content",
            json=body,
            expected=(200, 202),
        )
        data = response.json()
        if response.status_code == 202:
            raise ConflictPending(data if isinstance(data, dict) else {})
        return FileOut.model_validate(data)

    def versions(self, file_id: str) -> FileVersionsOut:
        return FileVersionsOut.model_validate(
            self._request("GET", f"/v1/files/{file_id}/versions").json()
        )

    def list_conflicts(self, state: str = "active") -> list[KdbxConflictOut]:
        body = self._request(
            "GET", "/v1/conflicts", params={"state": state}
        ).json()
        if not isinstance(body, list):
            raise ApiError("invalid conflicts response")
        return [KdbxConflictOut.model_validate(row) for row in body]

    def get_conflict(self, conflict_id: str) -> KdbxConflictOut:
        return KdbxConflictOut.model_validate(
            self._request("GET", f"/v1/conflicts/{conflict_id}").json()
        )

    def resolve_conflict(self, conflict_id: str, body: dict[str, Any]) -> FileOut:
        return FileOut.model_validate(
            self._request(
                "POST", f"/v1/conflicts/{conflict_id}/resolve", json=body
            ).json()
        )

    def recheck_conflict(self, conflict_id: str) -> dict[str, Any]:
        return self._request(
            "POST", f"/v1/conflicts/{conflict_id}/recheck"
        ).json()

    def put_kdbx_secret(self, file_id: str, password: str) -> None:
        self._request(
            "PUT",
            f"/v1/files/{file_id}/kdbx-secret",
            json={"password": password},
        )

    def gc(self, body: dict[str, Any] | None = None) -> GcRunOut:
        return GcRunOut.model_validate(
            self._request("POST", "/v1/gc", json=body or {}).json()
        )
