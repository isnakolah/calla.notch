package db

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/pgvector/pgvector-go"

	"calla.notch/backend/internal/manifest"
)

// ---- devices

type Device struct {
	ID        string     `json:"id"`
	Name      string     `json:"name"`
	TokenHash string     `json:"-"`
	CreatedAt time.Time  `json:"created_at"`
	LastSeen  *time.Time `json:"last_seen,omitempty"`
	RevokedAt *time.Time `json:"revoked_at,omitempty"`
}

func (d *DB) UpsertDevice(ctx context.Context, dev Device) error {
	_, err := d.Pool.Exec(ctx, `
		INSERT INTO devices(id, name, token_hash, created_at, revoked_at) VALUES ($1,$2,$3,$4,$5)
		ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, token_hash = EXCLUDED.token_hash, revoked_at = EXCLUDED.revoked_at`,
		dev.ID, dev.Name, dev.TokenHash, dev.CreatedAt, dev.RevokedAt)
	return err
}

// DeviceByToken returns the live device holding this token hash and marks it seen.
func (d *DB) DeviceByToken(ctx context.Context, hash string) (Device, error) {
	var dev Device
	err := d.Pool.QueryRow(ctx, `
		UPDATE devices SET last_seen = now()
		WHERE token_hash = $1 AND revoked_at IS NULL
		RETURNING id, name, created_at`, hash).Scan(&dev.ID, &dev.Name, &dev.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return dev, ErrNotFound
	}
	return dev, err
}

func (d *DB) Devices(ctx context.Context) ([]Device, error) {
	rows, err := d.Pool.Query(ctx, `SELECT id, name, created_at, last_seen, revoked_at FROM devices ORDER BY created_at`)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(r pgx.CollectableRow) (Device, error) {
		var dev Device
		err := r.Scan(&dev.ID, &dev.Name, &dev.CreatedAt, &dev.LastSeen, &dev.RevokedAt)
		return dev, err
	})
}

func (d *DB) DeviceByName(ctx context.Context, idOrName string) (Device, error) {
	var dev Device
	err := d.Pool.QueryRow(ctx, `
		SELECT id, name, token_hash, created_at, revoked_at FROM devices
		WHERE id = $1 OR (name = $1 AND revoked_at IS NULL)
		ORDER BY revoked_at NULLS FIRST, created_at DESC LIMIT 1`, idOrName).
		Scan(&dev.ID, &dev.Name, &dev.TokenHash, &dev.CreatedAt, &dev.RevokedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return dev, ErrNotFound
	}
	return dev, err
}

// ---- blobs

func (d *DB) RecordBlob(ctx context.Context, sha string, size int64) error {
	_, err := d.Pool.Exec(ctx, `INSERT INTO blobs(sha256, size) VALUES ($1,$2) ON CONFLICT DO NOTHING`, sha, size)
	return err
}

// ---- calls

// LockCall serializes commits for one call across server processes.
func LockCall(ctx context.Context, tx pgx.Tx, callID string) error {
	_, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext('call:' || $1))`, callID)
	return err
}

func LockDevice(ctx context.Context, tx pgx.Tx, deviceID string) error {
	_, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext('device:' || $1))`, deviceID)
	return err
}

// CurrentManifestSHA reports the newest committed manifest digest for a call.
func CurrentManifestSHA(ctx context.Context, tx pgx.Tx, callID string) (string, int, error) {
	var sha string
	var v int
	err := tx.QueryRow(ctx, `SELECT current_manifest, current_version FROM calls WHERE id = $1`, callID).Scan(&sha, &v)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", 0, nil
	}
	return sha, v, err
}

// RecordCallVersion writes the call row and manifest history for one commit.
func RecordCallVersion(ctx context.Context, tx pgx.Tx, m *manifest.Call, manifestSHA string) error {
	flags, _ := json.Marshal(m.Flags)
	_, err := tx.Exec(ctx, `
		INSERT INTO call_manifests(call_id, version, manifest_sha, device_id, committed_at)
		VALUES ($1,$2,$3,$4,COALESCE($5, now())) ON CONFLICT DO NOTHING`,
		m.CallID, m.Version, manifestSHA, m.DeviceID, m.CommittedAt)
	if err != nil {
		return err
	}
	_, err = tx.Exec(ctx, `
		INSERT INTO calls(id, device_id, persona, title, started_at, ended_at, flags, app_version, schema_version,
		                  current_version, current_manifest, updated_at)
		VALUES ($1,$2,NULLIF($3,''),NULLIF($4,''),$5,$6,$7,NULLIF($8,''),NULLIF($9,0),$10,$11,now())
		ON CONFLICT (id) DO UPDATE SET
		  device_id = EXCLUDED.device_id, persona = EXCLUDED.persona, title = EXCLUDED.title,
		  started_at = EXCLUDED.started_at, ended_at = EXCLUDED.ended_at, flags = EXCLUDED.flags,
		  app_version = EXCLUDED.app_version, schema_version = EXCLUDED.schema_version,
		  current_version = EXCLUDED.current_version, current_manifest = EXCLUDED.current_manifest,
		  updated_at = now()
		WHERE calls.current_version <= EXCLUDED.current_version`,
		m.CallID, m.DeviceID, m.Call.Persona, m.Call.Title, m.Call.StartedAt, m.Call.EndedAt, flags,
		m.AppVersion, m.SchemaVersion, m.Version, manifestSHA)
	return err
}

type CallSummary struct {
	ID             string          `json:"id"`
	DeviceID       string          `json:"device_id"`
	Persona        *string         `json:"persona,omitempty"`
	Title          *string         `json:"title,omitempty"`
	StartedAt      *time.Time      `json:"started_at,omitempty"`
	EndedAt        *time.Time      `json:"ended_at,omitempty"`
	Flags          json.RawMessage `json:"flags"`
	Version        int             `json:"version"`
	IndexedVersion *int            `json:"indexed_version,omitempty"`
	UpdatedAt      time.Time       `json:"updated_at"`
}

func scanCall(r pgx.CollectableRow) (CallSummary, error) {
	var c CallSummary
	err := r.Scan(&c.ID, &c.DeviceID, &c.Persona, &c.Title, &c.StartedAt, &c.EndedAt, &c.Flags, &c.Version, &c.IndexedVersion, &c.UpdatedAt)
	return c, err
}

const callColumns = `id, device_id, persona, title, started_at, ended_at, flags, current_version, indexed_version, updated_at`

// Calls lists calls, newest first. An empty deviceID lists every device's calls.
func (d *DB) Calls(ctx context.Context, deviceID string, limit int) ([]CallSummary, error) {
	rows, err := d.Pool.Query(ctx, `SELECT `+callColumns+` FROM calls
		WHERE $1 = '' OR device_id = $1 ORDER BY started_at DESC NULLS LAST, id LIMIT $2`, deviceID, limit)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, scanCall)
}

func (d *DB) Call(ctx context.Context, id string) (CallSummary, error) {
	rows, err := d.Pool.Query(ctx, `SELECT `+callColumns+` FROM calls WHERE id = $1`, id)
	if err != nil {
		return CallSummary{}, err
	}
	c, err := pgx.CollectExactlyOneRow(rows, scanCall)
	if errors.Is(err, pgx.ErrNoRows) {
		return c, ErrNotFound
	}
	return c, err
}

// ---- derived index rows

type Speaker struct {
	SpeakerID     string   `json:"speaker_id"`
	Label         *string  `json:"label"`
	PersonID      *string  `json:"person_id"`
	NameSource    *string  `json:"name_source"`
	Confidence    *float64 `json:"confidence"`
	SpeechSeconds *float64 `json:"speech_seconds"`
}

type Turn struct {
	Revision   int      `json:"revision"`
	Seq        int      `json:"seq"`
	Source     string   `json:"source"`
	SpeakerID  *string  `json:"speaker_id"`
	T0         float64  `json:"t0"`
	T1         float64  `json:"t1"`
	Text       string   `json:"text"`
	Confidence *float64 `json:"confidence"`
}

type Capture struct {
	File        string     `json:"file"`
	BlobSHA     string     `json:"blob_sha,omitempty"`
	Offset      *float64   `json:"offset"`
	TakenAt     *time.Time `json:"taken_at"`
	OCRText     string     `json:"ocr_text,omitempty"`
	Description *string    `json:"description,omitempty"`
}

type Chunk struct {
	Kind      string
	Ref       string
	T0, T1    *float64
	Text      string
	Embedding []float32
}

type CallIndex struct {
	Speakers []Speaker
	Turns    []Turn
	Captures []Capture
	Chunks   []Chunk
	Meeting  json.RawMessage
}

// ReplaceCallIndex swaps every derived row for one call in a single transaction.
func (d *DB) ReplaceCallIndex(ctx context.Context, callID string, version int, ix CallIndex) error {
	return pgx.BeginFunc(ctx, d.Pool, func(tx pgx.Tx) error {
		if err := LockCall(ctx, tx, callID); err != nil {
			return err
		}
		var current int
		if err := tx.QueryRow(ctx, `SELECT current_version FROM calls WHERE id = $1`, callID).Scan(&current); err != nil {
			return err
		}
		if current > version {
			return nil // a newer commit will be indexed by its own job
		}
		for _, t := range []string{"speakers", "turns", "captures", "chunks"} {
			if _, err := tx.Exec(ctx, `DELETE FROM `+t+` WHERE call_id = $1`, callID); err != nil {
				return err
			}
		}
		for _, s := range ix.Speakers {
			if _, err := tx.Exec(ctx, `INSERT INTO speakers VALUES ($1,$2,$3,$4,$5,$6,$7) ON CONFLICT DO NOTHING`,
				callID, s.SpeakerID, s.Label, s.PersonID, s.NameSource, s.Confidence, s.SpeechSeconds); err != nil {
				return err
			}
		}
		if len(ix.Turns) > 0 {
			rows := make([][]any, len(ix.Turns))
			for i, t := range ix.Turns {
				rows[i] = []any{callID, t.Revision, t.Seq, t.Source, t.SpeakerID, t.T0, t.T1, t.Text, t.Confidence}
			}
			if err := copyRows(ctx, tx, "turns",
				[]string{"call_id", "revision", "seq", "source", "speaker_id", "t0", "t1", "text", "confidence"}, rows); err != nil {
				return err
			}
		}
		for _, c := range ix.Captures {
			if _, err := tx.Exec(ctx, `INSERT INTO captures VALUES ($1,$2,NULLIF($3,''),$4,$5,NULLIF($6,''),$7) ON CONFLICT DO NOTHING`,
				callID, c.File, c.BlobSHA, c.Offset, c.TakenAt, c.OCRText, c.Description); err != nil {
				return err
			}
		}
		for _, ch := range ix.Chunks {
			var emb any
			if len(ch.Embedding) > 0 {
				v := pgvector.NewVector(ch.Embedding)
				emb = v
			}
			if _, err := tx.Exec(ctx, `INSERT INTO chunks(call_id, kind, ref, t0, t1, text, embedding) VALUES ($1,$2,$3,$4,$5,$6,$7)`,
				callID, ch.Kind, ch.Ref, ch.T0, ch.T1, ch.Text, emb); err != nil {
				return err
			}
		}
		_, err := tx.Exec(ctx, `UPDATE calls SET indexed_version = $2, meeting = $3 WHERE id = $1`, callID, version, nullJSON(ix.Meeting))
		return err
	})
}

// copyRows bulk-inserts with COPY. Callers pass rows already unique by key.
func copyRows(ctx context.Context, tx pgx.Tx, table string, cols []string, rows [][]any) error {
	_, err := tx.CopyFrom(ctx, pgx.Identifier{table}, cols, pgx.CopyFromRows(rows))
	return err
}

func nullJSON(b json.RawMessage) any {
	if len(b) == 0 || !json.Valid(b) {
		return nil
	}
	return b
}

func (d *DB) Turns(ctx context.Context, callID string, revision int) ([]Turn, error) {
	rows, err := d.Pool.Query(ctx, `SELECT revision, seq, source, speaker_id, t0, t1, text, confidence
		FROM turns WHERE call_id = $1 AND revision = $2 ORDER BY seq`, callID, revision)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(r pgx.CollectableRow) (Turn, error) {
		var t Turn
		err := r.Scan(&t.Revision, &t.Seq, &t.Source, &t.SpeakerID, &t.T0, &t.T1, &t.Text, &t.Confidence)
		return t, err
	})
}

func (d *DB) Speakers(ctx context.Context, callID string) ([]Speaker, error) {
	rows, err := d.Pool.Query(ctx, `SELECT speaker_id, label, person_id, name_source, confidence, speech_seconds
		FROM speakers WHERE call_id = $1 ORDER BY speaker_id`, callID)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(r pgx.CollectableRow) (Speaker, error) {
		var s Speaker
		err := r.Scan(&s.SpeakerID, &s.Label, &s.PersonID, &s.NameSource, &s.Confidence, &s.SpeechSeconds)
		return s, err
	})
}

func (d *DB) Captures(ctx context.Context, callID string) ([]Capture, error) {
	rows, err := d.Pool.Query(ctx, `SELECT file, COALESCE(blob_sha,''), "offset", taken_at, COALESCE(ocr_text,''), description
		FROM captures WHERE call_id = $1 ORDER BY "offset" NULLS LAST, file`, callID)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(r pgx.CollectableRow) (Capture, error) {
		var c Capture
		err := r.Scan(&c.File, &c.BlobSHA, &c.Offset, &c.TakenAt, &c.OCRText, &c.Description)
		return c, err
	})
}

// ResetIndex drops every derived row. Calls, manifests and blobs rows are
// rebuilt from the vault by reindex.
func (d *DB) ResetIndex(ctx context.Context) error {
	_, err := d.Pool.Exec(ctx, `TRUNCATE calls, call_manifests, speakers, turns, captures, chunks, blobs, device_snapshots, jobs RESTART IDENTITY CASCADE`)
	return err
}

// ---- search

type Hit struct {
	CallID string   `json:"call_id"`
	Title  *string  `json:"title,omitempty"`
	Kind   string   `json:"kind"`
	Ref    string   `json:"ref"`
	T0     *float64 `json:"t0,omitempty"`
	T1     *float64 `json:"t1,omitempty"`
	Text   string   `json:"text"`
	Score  float64  `json:"score"`
}

// Search fuses full-text and vector ranks with reciprocal rank fusion. A nil
// query vector falls back to full text alone.
func (d *DB) Search(ctx context.Context, q string, vec []float32, deviceID string, limit int) ([]Hit, error) {
	var qv any
	if len(vec) > 0 {
		qv = pgvector.NewVector(vec)
	}
	rows, err := d.Pool.Query(ctx, `
		WITH scope AS (
		  SELECT id, title FROM calls WHERE $3 = '' OR device_id = $3
		),
		fts AS (
		  SELECT c.id, row_number() OVER (ORDER BY ts_rank_cd(c.tsv, query) DESC) AS r
		  FROM chunks c JOIN scope s ON s.id = c.call_id, websearch_to_tsquery('english', $1) query
		  WHERE c.tsv @@ query LIMIT 100
		),
		vec AS (
		  SELECT c.id, row_number() OVER (ORDER BY c.embedding <=> $2::vector) AS r
		  FROM chunks c JOIN scope s ON s.id = c.call_id
		  WHERE $2::vector IS NOT NULL AND c.embedding IS NOT NULL
		  ORDER BY c.embedding <=> $2::vector LIMIT 100
		),
		fused AS (
		  SELECT id, sum(1.0 / (60 + r)) AS score FROM (SELECT * FROM fts UNION ALL SELECT * FROM vec) u GROUP BY id
		)
		SELECT c.call_id, s.title, c.kind, c.ref, c.t0, c.t1, c.text, f.score
		FROM fused f JOIN chunks c ON c.id = f.id JOIN scope s ON s.id = c.call_id
		ORDER BY f.score DESC LIMIT $4`, q, qv, deviceID, limit)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(r pgx.CollectableRow) (Hit, error) {
		var h Hit
		err := r.Scan(&h.CallID, &h.Title, &h.Kind, &h.Ref, &h.T0, &h.T1, &h.Text, &h.Score)
		return h, err
	})
}

// ---- device snapshots

func (d *DB) RecordDeviceSnapshot(ctx context.Context, m *manifest.Device, sha string) error {
	_, err := d.Pool.Exec(ctx, `INSERT INTO device_snapshots(device_id, version, manifest_sha, committed_at)
		VALUES ($1,$2,$3,COALESCE($4, now())) ON CONFLICT DO NOTHING`, m.DeviceID, m.Version, sha, m.CommittedAt)
	return err
}

func CurrentDeviceSnapshotSHA(ctx context.Context, tx pgx.Tx, deviceID string) (string, error) {
	var sha string
	err := tx.QueryRow(ctx, `SELECT manifest_sha FROM device_snapshots WHERE device_id = $1 ORDER BY version DESC LIMIT 1`, deviceID).Scan(&sha)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", nil
	}
	return sha, err
}

// ---- jobs

type Job struct {
	ID       int64
	Kind     string
	CallID   string
	Version  int
	Attempts int
}

// EnqueueTx queues a job inside an open transaction.
func EnqueueTx(ctx context.Context, tx pgx.Tx, kind, callID string, version int) error {
	_, err := tx.Exec(ctx, `INSERT INTO jobs(kind, call_id, version) VALUES ($1,$2,$3)`, kind, callID, version)
	if err != nil {
		return err
	}
	_, err = tx.Exec(ctx, `SELECT pg_notify('calla_jobs', '')`)
	return err
}

// ClaimJob takes the oldest runnable job. The lease is the run_after bump: a
// worker that dies leaves the job runnable again after five minutes.
func (d *DB) ClaimJob(ctx context.Context) (*Job, error) {
	var j Job
	var callID *string
	var version *int
	err := d.Pool.QueryRow(ctx, `
		UPDATE jobs SET attempts = attempts + 1, run_after = now() + interval '5 minutes'
		WHERE id = (
		  SELECT id FROM jobs WHERE done_at IS NULL AND run_after <= now()
		  ORDER BY run_after, id FOR UPDATE SKIP LOCKED LIMIT 1)
		RETURNING id, kind, call_id, version, attempts`).Scan(&j.ID, &j.Kind, &callID, &version, &j.Attempts)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if callID != nil {
		j.CallID = *callID
	}
	if version != nil {
		j.Version = *version
	}
	return &j, nil
}

func (d *DB) FinishJob(ctx context.Context, id int64) error {
	_, err := d.Pool.Exec(ctx, `UPDATE jobs SET done_at = now(), last_error = NULL WHERE id = $1`, id)
	return err
}

func (d *DB) FailJob(ctx context.Context, id int64, attempts int, cause error) error {
	backoff := time.Duration(1<<min(attempts, 10)) * 10 * time.Second
	_, err := d.Pool.Exec(ctx, `UPDATE jobs SET last_error = $2, run_after = now() + $3::interval WHERE id = $1`,
		id, cause.Error(), backoff.String())
	return err
}

// ---- inbox

type Message struct {
	ID          int64           `json:"id"`
	DeviceID    string          `json:"device_id"`
	Kind        string          `json:"kind"`
	Payload     json.RawMessage `json:"payload"`
	CreatedAt   time.Time       `json:"created_at"`
	DeliveredAt *time.Time      `json:"delivered_at,omitempty"`
	AckedAt     *time.Time      `json:"acked_at,omitempty"`
	Result      json.RawMessage `json:"result,omitempty"`
}

func (d *DB) Push(ctx context.Context, deviceID, kind string, payload json.RawMessage) (int64, error) {
	var id int64
	err := pgx.BeginFunc(ctx, d.Pool, func(tx pgx.Tx) error {
		if err := tx.QueryRow(ctx, `INSERT INTO inbox(device_id, kind, payload) VALUES ($1,$2,$3) RETURNING id`,
			deviceID, kind, payload).Scan(&id); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `SELECT pg_notify('calla_inbox', $1)`, deviceID)
		return err
	})
	return id, err
}

// Pending returns unacked messages after a cursor and marks them delivered.
func (d *DB) Pending(ctx context.Context, deviceID string, after int64, limit int) ([]Message, error) {
	rows, err := d.Pool.Query(ctx, `
		UPDATE inbox SET delivered_at = COALESCE(delivered_at, now())
		WHERE id IN (SELECT id FROM inbox WHERE device_id = $1 AND id > $2 AND acked_at IS NULL ORDER BY id LIMIT $3)
		RETURNING id, device_id, kind, payload, created_at, delivered_at, acked_at, result`, deviceID, after, limit)
	if err != nil {
		return nil, err
	}
	msgs, err := pgx.CollectRows(rows, scanMessage)
	if err != nil {
		return nil, err
	}
	// UPDATE ... RETURNING does not preserve order.
	for i := 1; i < len(msgs); i++ {
		for j := i; j > 0 && msgs[j].ID < msgs[j-1].ID; j-- {
			msgs[j], msgs[j-1] = msgs[j-1], msgs[j]
		}
	}
	return msgs, nil
}

func scanMessage(r pgx.CollectableRow) (Message, error) {
	var m Message
	err := r.Scan(&m.ID, &m.DeviceID, &m.Kind, &m.Payload, &m.CreatedAt, &m.DeliveredAt, &m.AckedAt, &m.Result)
	return m, err
}

func (d *DB) Ack(ctx context.Context, deviceID string, id int64, result json.RawMessage) error {
	tag, err := d.Pool.Exec(ctx, `UPDATE inbox SET acked_at = now(), result = $3 WHERE id = $2 AND device_id = $1`,
		deviceID, id, nullJSON(result))
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

func (d *DB) Messages(ctx context.Context, deviceID string, limit int) ([]Message, error) {
	rows, err := d.Pool.Query(ctx, `SELECT id, device_id, kind, payload, created_at, delivered_at, acked_at, result
		FROM inbox WHERE $1 = '' OR device_id = $1 ORDER BY id DESC LIMIT $2`, deviceID, limit)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, scanMessage)
}
