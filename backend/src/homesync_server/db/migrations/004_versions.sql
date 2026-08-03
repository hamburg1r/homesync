-- Milestone 8: content version history under a stable file_id.
-- Head remains on files; prior heads are archived here on content replace.

CREATE TABLE versions (
    version_id TEXT PRIMARY KEY,
    file_id TEXT NOT NULL REFERENCES files(file_id),
    content_hash TEXT NOT NULL,
    size_bytes INTEGER NOT NULL,
    created_at TEXT NOT NULL,
    note TEXT
);

CREATE INDEX ix_versions_file_id_created ON versions(file_id, created_at);
