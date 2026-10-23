-- The vault (blob store + manifest files) is the source of truth. Every table
-- below except inbox is derived from call manifests and can be dropped and
-- rebuilt with `calla-backend reindex`.

CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE devices (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  token_hash  TEXT NOT NULL UNIQUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen   TIMESTAMPTZ,
  revoked_at  TIMESTAMPTZ
);

-- Known blobs. The file on disk is authoritative; this row only records that
-- it was verified and how big it is.
CREATE TABLE blobs (
  sha256      TEXT PRIMARY KEY,
  size        BIGINT NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Every commit of a call is kept. A manifest is itself stored as a blob, so
-- reindex can walk manifests without this table.
CREATE TABLE call_manifests (
  call_id       TEXT NOT NULL,
  version       INTEGER NOT NULL,
  manifest_sha  TEXT NOT NULL,
  device_id     TEXT NOT NULL,
  committed_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (call_id, version)
);
CREATE UNIQUE INDEX call_manifests_sha ON call_manifests(call_id, manifest_sha);

CREATE TABLE calls (
  id                TEXT PRIMARY KEY,
  device_id         TEXT NOT NULL,
  persona           TEXT,
  title             TEXT,
  started_at        TIMESTAMPTZ,
  ended_at          TIMESTAMPTZ,
  meeting           JSONB,
  flags             JSONB NOT NULL DEFAULT '{}',
  app_version       TEXT,
  schema_version    INTEGER,
  current_version   INTEGER NOT NULL,
  current_manifest  TEXT NOT NULL,
  indexed_version   INTEGER,
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX calls_started ON calls(started_at DESC);

CREATE TABLE speakers (
  call_id         TEXT NOT NULL REFERENCES calls(id) ON DELETE CASCADE,
  speaker_id      TEXT NOT NULL,
  label           TEXT,
  person_id       TEXT,
  name_source     TEXT,
  confidence      REAL,
  speech_seconds  REAL,
  PRIMARY KEY (call_id, speaker_id)
);

-- revision 0 is the live pass, 1 the archive re-transcription.
CREATE TABLE turns (
  call_id     TEXT NOT NULL REFERENCES calls(id) ON DELETE CASCADE,
  revision    INTEGER NOT NULL,
  seq         INTEGER NOT NULL,
  source      TEXT NOT NULL,
  speaker_id  TEXT,
  t0          REAL NOT NULL,
  t1          REAL NOT NULL,
  text        TEXT NOT NULL,
  confidence  REAL,
  tsv         TSVECTOR GENERATED ALWAYS AS (to_tsvector('english', text)) STORED,
  PRIMARY KEY (call_id, revision, seq)
);
CREATE INDEX turns_tsv ON turns USING GIN (tsv);

CREATE TABLE captures (
  call_id      TEXT NOT NULL REFERENCES calls(id) ON DELETE CASCADE,
  file         TEXT NOT NULL,
  blob_sha     TEXT,
  "offset"     REAL,
  taken_at     TIMESTAMPTZ,
  ocr_text     TEXT,
  description  TEXT,
  PRIMARY KEY (call_id, file)
);

-- Retrieval units: windows of transcript and screenshot text.
CREATE TABLE chunks (
  id         BIGSERIAL PRIMARY KEY,
  call_id    TEXT NOT NULL REFERENCES calls(id) ON DELETE CASCADE,
  kind       TEXT NOT NULL CHECK (kind IN ('transcript', 'capture', 'recap')),
  ref        TEXT NOT NULL,
  t0         REAL,
  t1         REAL,
  text       TEXT NOT NULL,
  embedding  vector(384),
  tsv        TSVECTOR GENERATED ALWAYS AS (to_tsvector('english', text)) STORED
);
CREATE INDEX chunks_call ON chunks(call_id);
CREATE INDEX chunks_tsv ON chunks USING GIN (tsv);
CREATE INDEX chunks_embedding ON chunks USING hnsw (embedding vector_cosine_ops);

-- Device-wide state (voiceprints, knowledge, settings). Versioned like calls.
CREATE TABLE device_snapshots (
  device_id     TEXT NOT NULL,
  version       INTEGER NOT NULL,
  manifest_sha  TEXT NOT NULL,
  committed_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (device_id, version)
);

CREATE TABLE jobs (
  id          BIGSERIAL PRIMARY KEY,
  kind        TEXT NOT NULL,
  call_id     TEXT,
  version     INTEGER,
  attempts    INTEGER NOT NULL DEFAULT 0,
  run_after   TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_error  TEXT,
  done_at     TIMESTAMPTZ,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX jobs_pending ON jobs(run_after) WHERE done_at IS NULL;

-- Server to Mac. Payload kinds are a fixed allowlist the Mac knows how to apply.
CREATE TABLE inbox (
  id            BIGSERIAL PRIMARY KEY,
  device_id     TEXT NOT NULL,
  kind          TEXT NOT NULL,
  payload       JSONB NOT NULL,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  delivered_at  TIMESTAMPTZ,
  acked_at      TIMESTAMPTZ,
  result        JSONB
);
CREATE INDEX inbox_device ON inbox(device_id, id);
