"""Homesync FastAPI app entry."""

from __future__ import annotations

from contextlib import asynccontextmanager
from collections.abc import AsyncIterator

from fastapi import FastAPI

from homesync_server.config import data_root
from homesync_server.db import bootstrap


@asynccontextmanager
async def lifespan(_app: FastAPI) -> AsyncIterator[None]:
    bootstrap(data_root())
    yield


app = FastAPI(title="Homesync", version="0.1.0", lifespan=lifespan)


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


def run() -> None:
    import uvicorn

    uvicorn.run("homesync_server.main:app", host="127.0.0.1", port=8787, reload=True)


if __name__ == "__main__":
    run()
