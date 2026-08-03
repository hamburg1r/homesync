-- Hard-purge log so phones can drop leftover soft-deleted catalog rows after GC.

CREATE TABLE IF NOT EXISTS gc_purges (
    file_id TEXT PRIMARY KEY NOT NULL,
    purged_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS ix_gc_purges_purged_at ON gc_purges (purged_at);
