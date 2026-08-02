-- Milestone 4: per-device availability (listed / cached / pinned).

CREATE TABLE availability (
    file_id TEXT NOT NULL REFERENCES files(file_id),
    device_id TEXT NOT NULL REFERENCES devices(device_id),
    mode TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    PRIMARY KEY (file_id, device_id)
);

CREATE INDEX ix_availability_device_mode ON availability(device_id, mode);
