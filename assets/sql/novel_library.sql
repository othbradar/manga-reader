CREATE TABLE IF NOT EXISTS novels (
  novel_uuid TEXT PRIMARY KEY,
  path_word TEXT NOT NULL UNIQUE,
  title TEXT NOT NULL,
  authors TEXT NOT NULL DEFAULT '',
  alias TEXT NOT NULL DEFAULT '',
  brief TEXT NOT NULL DEFAULT '',
  cover_url TEXT NOT NULL DEFAULT '',
  relative_dir TEXT NOT NULL DEFAULT '',
  cover_relative_path TEXT NOT NULL DEFAULT '',
  source_kind TEXT NOT NULL DEFAULT 'copy_manga',
  library_order INTEGER NOT NULL DEFAULT 0,
  title_sort_key TEXT NOT NULL DEFAULT '',
  updated_at TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS novel_volumes (
  novel_uuid TEXT NOT NULL,
  volume_id TEXT NOT NULL,
  title TEXT NOT NULL,
  volume_order REAL NOT NULL DEFAULT 0,
  txt_url TEXT NOT NULL DEFAULT '',
  txt_encoding TEXT NOT NULL DEFAULT 'UTF-8',
  txt_relative_path TEXT NOT NULL DEFAULT '',
  text_sha256 TEXT NOT NULL DEFAULT '',
  is_downloaded INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(novel_uuid, volume_id)
);
CREATE TABLE IF NOT EXISTS novel_sections (
  novel_uuid TEXT NOT NULL,
  volume_id TEXT NOT NULL,
  section_index INTEGER NOT NULL,
  title TEXT NOT NULL DEFAULT '',
  content_type INTEGER NOT NULL DEFAULT 1,
  start_line INTEGER NOT NULL DEFAULT 0,
  end_line INTEGER NOT NULL DEFAULT 0,
  image_url TEXT NOT NULL DEFAULT '',
  image_relative_path TEXT NOT NULL DEFAULT '',
  PRIMARY KEY(novel_uuid, volume_id, section_index)
);
CREATE TABLE IF NOT EXISTS novel_import_sources (
  source_dir TEXT PRIMARY KEY,
  novel_uuid TEXT NOT NULL,
  match_method TEXT NOT NULL DEFAULT '',
  imported_at TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_novel_volumes_order
  ON novel_volumes(novel_uuid, volume_order);
CREATE INDEX IF NOT EXISTS idx_novel_sections_order
  ON novel_sections(novel_uuid, volume_id, section_index);
