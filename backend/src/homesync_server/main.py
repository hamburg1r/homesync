"""Homesync FastAPI app entry."""

from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI

from homesync_server.api import api_router
from homesync_server.config import data_root
from homesync_server.db import bootstrap


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    _root, engine = bootstrap(data_root())
    app.state.engine = engine
    yield
    engine.dispose()
    app.state.engine = None


app = FastAPI(title="Homesync", version="0.1.0", lifespan=lifespan)
app.include_router(api_router)


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


def run() -> None:
    import uvicorn

    from homesync_server.config import server_bind

    # Default localhost. Use HOMESYNC_HOST=0.0.0.0 for LAN/Tailscale (no auth yet).
    host, port, reload = server_bind()
    uvicorn.run("homesync_server.main:app", host=host, port=port, reload=reload)


if __name__ == "__main__":
    run()
