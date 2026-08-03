-- Milestone 9: KeePass conflict outbox (candidates under a stable file_id).

CREATE TABLE kdbx_conflicts (
    conflict_id TEXT PRIMARY KEY,
    file_id TEXT NOT NULL REFERENCES files(file_id),
    state TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    diff_summary_json TEXT,
    resolved_content_hash TEXT
);

CREATE INDEX ix_kdbx_conflicts_file_state ON kdbx_conflicts(file_id, state);
CREATE INDEX ix_kdbx_conflicts_state ON kdbx_conflicts(state);

CREATE TABLE kdbx_conflict_candidates (
    id TEXT PRIMARY KEY,
    conflict_id TEXT NOT NULL REFERENCES kdbx_conflicts(conflict_id),
    content_hash TEXT NOT NULL,
    size_bytes INTEGER NOT NULL,
    source_device_id TEXT REFERENCES devices(device_id),
    role TEXT NOT NULL,
    created_at TEXT NOT NULL,
    UNIQUE (conflict_id, content_hash)
);

CREATE INDEX ix_kdbx_candidates_conflict ON kdbx_conflict_candidates(conflict_id);
