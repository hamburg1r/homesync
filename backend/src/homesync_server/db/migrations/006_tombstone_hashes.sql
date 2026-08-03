-- Free UNIQUE(content_hash) held by soft-deleted rows so re-uploads can succeed.
-- Real digest is preserved after the last colon for revive/dedup lookups.

UPDATE files
SET content_hash = 'tombstone:' || file_id || ':' || content_hash
WHERE deleted_at IS NOT NULL
  AND content_hash NOT LIKE 'tombstone:%';
