-- Milestone 2: tags + file_tags for catalog metadata API.

CREATE TABLE tags (
    tag_id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    color TEXT
);

CREATE UNIQUE INDEX ux_tags_name_ci ON tags(name COLLATE NOCASE);

CREATE TABLE file_tags (
    file_id TEXT NOT NULL REFERENCES files(file_id),
    tag_id TEXT NOT NULL REFERENCES tags(tag_id),
    PRIMARY KEY (file_id, tag_id)
);

CREATE INDEX ix_file_tags_tag_id ON file_tags(tag_id);
