"""HTTP API routers."""

from fastapi import APIRouter

from homesync_server.api import blobs, catalog, devices, files

api_router = APIRouter()
api_router.include_router(files.router)
api_router.include_router(catalog.router)
api_router.include_router(devices.router)
api_router.include_router(blobs.router)

__all__ = ["api_router"]
