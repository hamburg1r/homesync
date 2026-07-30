from fastapi import FastAPI

app = FastAPI(title="Homesync", version="0.1.0")


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


def run() -> None:
    import uvicorn

    uvicorn.run("homesync_server.main:app", host="127.0.0.1", port=8787, reload=True)


if __name__ == "__main__":
    run()
