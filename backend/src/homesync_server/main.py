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

    uvicorn.run("homesync_server.main:app", host="127.0.0.1", port=8787, reload=True)


if __name__ == "__main__":
    run()
