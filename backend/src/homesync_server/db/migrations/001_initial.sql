-- Milestone 1 catalog tables (devices, library_roots, files, file_paths).
-- schema_version is owned by the migrator.

CREATE TABLE devices (
    device_id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    kind TEXT NOT NULL,
    created_at TEXT NOT NULL,
    last_seen_at TEXT
);

CREATE TABLE library_roots (
    root_id TEXT PRIMARY KEY,
    device_id TEXT NOT NULL REFERENCES devices(device_id),
    abs_path TEXT NOT NULL UNIQUE,
    label TEXT,
    enabled INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE files (
    file_id TEXT PRIMARY KEY,
    content_hash TEXT NOT NULL UNIQUE,
    hash_algo TEXT NOT NULL,
    mime_type TEXT,
    size_bytes INTEGER NOT NULL,
    title TEXT,
    notes TEXT,
    taken_at TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    deleted_at TEXT
);

CREATE TABLE file_paths (
    id TEXT PRIMARY KEY,
    file_id TEXT NOT NULL REFERENCES files(file_id),
    root_id TEXT REFERENCES library_roots(root_id),
    relative_path TEXT NOT NULL,
    source_kind TEXT NOT NULL DEFAULT 'unknown',
    source_device_id TEXT REFERENCES devices(device_id),
    is_current INTEGER NOT NULL DEFAULT 1,
    seen_at TEXT NOT NULL,
    gone_at TEXT,
    UNIQUE (root_id, relative_path)
);

CREATE INDEX ix_files_updated_at ON files(updated_at);
CREATE INDEX ix_file_paths_file_id ON file_paths(file_id);
CREATE INDEX ix_file_paths_root_current ON file_paths(root_id, is_current);
