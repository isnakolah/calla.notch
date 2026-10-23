// Package api is the HTTP surface calla.notch talks to. Every route except
// /healthz and /v1/enroll needs a device token. All enrolled devices belong to one owner, so
// any device may read any call; that is what lets a reinstalled or new Mac
// restore everything.
package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"

	"calla.notch/backend/internal/auth"
	"calla.notch/backend/internal/db"
	"calla.notch/backend/internal/inbox"
	"calla.notch/backend/internal/index"
	"calla.notch/backend/internal/manifest"
	"calla.notch/backend/internal/vault"
)

type Server struct {
	DB       *db.DB
	Vault    *vault.Vault
	Embedder index.Embedder // nil: full-text search only
	Broker   *inbox.Broker
	MaxBlob  int64
	// Heartbeat for SSE; Cloudflare drops idle streams after ~100s.
	Heartbeat time.Duration
	// EnrollSecret gates POST /v1/enroll; empty disables it.
	EnrollSecret string
	// PublicURL is handed to newly enrolled Macs.
	PublicURL string
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", s.healthz)
	mux.HandleFunc("POST /v1/enroll", s.enroll)

	authed := http.NewServeMux()
	authed.HandleFunc("GET /v1/me", s.me)
	authed.HandleFunc("POST /v1/blobs/check", s.checkBlobs)
	authed.HandleFunc("PUT /v1/blobs/{sha}", s.putBlob)
	authed.HandleFunc("GET /v1/blobs/{sha}", s.getBlob)
	authed.HandleFunc("POST /v1/calls/{id}/commit", s.commitCall)
	authed.HandleFunc("GET /v1/calls", s.listCalls)
	authed.HandleFunc("GET /v1/calls/{id}", s.getCall)
	authed.HandleFunc("GET /v1/calls/{id}/manifest", s.getManifest)
	authed.HandleFunc("GET /v1/calls/{id}/turns", s.getTurns)
	authed.HandleFunc("GET /v1/search", s.search)
	authed.HandleFunc("POST /v1/device/snapshot", s.commitDevice)
	authed.HandleFunc("GET /v1/restore", s.restore)
	authed.HandleFunc("GET /v1/inbox", s.listInbox)
	authed.HandleFunc("GET /v1/inbox/stream", s.streamInbox)
	authed.HandleFunc("POST /v1/inbox/{id}/ack", s.ackInbox)
	authed.HandleFunc("GET /v1/bundles/{id}", s.getBundle)
	mux.Handle("/v1/", s.requireDevice(authed))

	return logRequests(mux)
}

func (s *Server) requireDevice(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		tok := auth.Bearer(r)
		if tok == "" {
			fail(w, http.StatusUnauthorized, "missing device token")
			return
		}
		dev, err := s.DB.DeviceByToken(r.Context(), auth.Hash(tok))
		if errors.Is(err, db.ErrNotFound) {
			fail(w, http.StatusUnauthorized, "unknown or revoked device token")
			return
		}
		if err != nil {
			internal(w, err)
			return
		}
		next.ServeHTTP(w, r.WithContext(auth.WithDevice(r.Context(), auth.Device{ID: dev.ID, Name: dev.Name})))
	})
}

func device(r *http.Request) auth.Device {
	d, _ := auth.DeviceFrom(r.Context())
	return d
}

// ---- health

func (s *Server) healthz(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	defer cancel()
	status := map[string]any{"ok": true}
	if err := s.DB.Pool.Ping(ctx); err != nil {
		status["ok"], status["db"] = false, err.Error()
	}
	if free, err := s.Vault.FreeBytes(); err == nil {
		status["free_bytes"] = free
		status["accepting"] = s.Vault.MinFreeBytes == 0 || free > s.Vault.MinFreeBytes
	}
	code := http.StatusOK
	if status["ok"] != true {
		code = http.StatusServiceUnavailable
	}
	writeJSON(w, code, status)
}

func (s *Server) me(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"device_id": device(r).ID, "name": device(r).Name})
}

// ---- blobs

func (s *Server) checkBlobs(w http.ResponseWriter, r *http.Request) {
	var req struct {
		SHA256 []string `json:"sha256"`
	}
	if !readJSON(w, r, &req, 4<<20) {
		return
	}
	if len(req.SHA256) > 20000 {
		fail(w, http.StatusBadRequest, "too many digests")
		return
	}
	missing := []string{}
	for _, sha := range req.SHA256 {
		if !manifest.ValidSHA(sha) {
			fail(w, http.StatusBadRequest, "bad sha256 "+strconv.Quote(sha))
			return
		}
		if !s.Vault.HasBlob(sha) {
			missing = append(missing, sha)
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"missing": missing})
}

// putBlob stores one blob. Without query parameters the body is the whole
// blob. With ?offset=N&total=T it is one chunk of a resumable upload, for
// files bigger than Cloudflare's 100 MB request limit: chunks go in order,
// a mismatched offset gets 409 with the server's offset, and the last chunk
// is hash-checked before the blob is kept. GET ?offset reports progress.
func (s *Server) putBlob(w http.ResponseWriter, r *http.Request) {
	sha := r.PathValue("sha")
	if !manifest.ValidSHA(sha) {
		fail(w, http.StatusBadRequest, "bad sha256")
		return
	}
	if s.Vault.HasBlob(sha) {
		_, _ = io.Copy(io.Discard, io.LimitReader(r.Body, 1<<20))
		writeJSON(w, http.StatusOK, map[string]any{"sha256": sha, "existed": true, "done": true})
		return
	}
	q := r.URL.Query()
	if q.Has("offset") {
		offset, err1 := strconv.ParseInt(q.Get("offset"), 10, 64)
		total, err2 := strconv.ParseInt(q.Get("total"), 10, 64)
		if err1 != nil || err2 != nil || offset < 0 || total <= 0 {
			fail(w, http.StatusBadRequest, "offset and total must be integers")
			return
		}
		received, done, err := s.Vault.AppendChunk(sha, offset, total, r.Body, r.ContentLength, s.MaxBlob)
		switch {
		case errors.Is(err, vault.ErrBadOffset):
			writeJSON(w, http.StatusConflict, map[string]any{"error": "offset mismatch", "offset": received})
			return
		case err != nil && s.blobError(w, err):
			return
		case err != nil:
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error(), "offset": received})
			return
		}
		if done {
			if err := s.DB.RecordBlob(r.Context(), sha, total); err != nil {
				internal(w, err)
				return
			}
		}
		writeJSON(w, http.StatusOK, map[string]any{"sha256": sha, "offset": received, "done": done})
		return
	}
	if r.ContentLength > s.MaxBlob {
		fail(w, http.StatusRequestEntityTooLarge, "blob exceeds size limit")
		return
	}
	n, err := s.Vault.PutBlob(sha, r.Body, r.ContentLength, s.MaxBlob)
	if err != nil {
		if !s.blobError(w, err) {
			internal(w, err)
		}
		return
	}
	if err := s.DB.RecordBlob(r.Context(), sha, n); err != nil {
		internal(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"sha256": sha, "size": n, "done": true})
}

// blobError writes the response for the vault's typed failures.
func (s *Server) blobError(w http.ResponseWriter, err error) bool {
	switch {
	case errors.Is(err, vault.ErrHashMismatch):
		fail(w, http.StatusUnprocessableEntity, "content does not match sha256")
	case errors.Is(err, vault.ErrTooLarge):
		fail(w, http.StatusRequestEntityTooLarge, "blob exceeds size limit")
	case errors.Is(err, vault.ErrLowDisk):
		fail(w, http.StatusInsufficientStorage, "server is low on disk space")
	default:
		return false
	}
	return true
}

func (s *Server) getBlob(w http.ResponseWriter, r *http.Request) {
	sha := r.PathValue("sha")
	if r.URL.Query().Has("offset") {
		if !manifest.ValidSHA(sha) {
			fail(w, http.StatusBadRequest, "bad sha256")
			return
		}
		done := s.Vault.HasBlob(sha)
		writeJSON(w, http.StatusOK, map[string]any{"sha256": sha, "offset": s.Vault.UploadOffset(sha), "done": done})
		return
	}
	f, err := s.Vault.OpenBlob(sha)
	if errors.Is(err, vault.ErrNotFound) {
		fail(w, http.StatusNotFound, "no such blob")
		return
	}
	if err != nil {
		internal(w, err)
		return
	}
	defer f.Close()
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Cache-Control", "private, max-age=31536000, immutable")
	w.Header().Set("ETag", `"`+sha+`"`)
	st, _ := f.Stat()
	http.ServeContent(w, r, "", st.ModTime(), f) // supports Range, so restores resume
}

// ---- calls

func (s *Server) commitCall(w http.ResponseWriter, r *http.Request) {
	callID := r.PathValue("id")
	var m manifest.Call
	if !readJSON(w, r, &m, 32<<20) {
		return
	}
	if m.CallID != callID {
		fail(w, http.StatusBadRequest, "call_id does not match the path")
		return
	}
	if err := m.Validate(); err != nil {
		fail(w, http.StatusBadRequest, err.Error())
		return
	}
	if missing := s.missing(m.Files); len(missing) > 0 {
		writeJSON(w, http.StatusConflict, map[string]any{"error": "blobs missing", "missing": missing})
		return
	}
	digest := m.ContentSHA()
	var version int
	var unchanged bool
	err := pgx.BeginFunc(r.Context(), s.DB.Pool, func(tx pgx.Tx) error {
		if err := db.LockCall(r.Context(), tx, callID); err != nil {
			return err
		}
		current, v, err := db.CurrentManifestSHA(r.Context(), tx, callID)
		if err != nil {
			return err
		}
		if current == digest {
			version, unchanged = v, true
			return nil
		}
		now := time.Now().UTC()
		m.DeviceID, m.CommittedAt = device(r).ID, &now
		// The vault write is the commit point. If the transaction then fails,
		// reindex still finds the manifest, and a retry of this same upload
		// is recorded as the next version.
		if version, err = s.Vault.SaveCallManifest(&m); err != nil {
			return err
		}
		if err := db.RecordCallVersion(r.Context(), tx, &m, digest); err != nil {
			return err
		}
		return db.EnqueueTx(r.Context(), tx, "index", callID, version)
	})
	if err != nil {
		internal(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"call_id": callID, "version": version, "unchanged": unchanged})
}

func (s *Server) missing(files []manifest.File) []string {
	out := []string{}
	for _, f := range files {
		if !s.Vault.HasBlob(f.SHA256) {
			out = append(out, f.SHA256)
		}
	}
	return out
}

func scopeDevice(r *http.Request) string {
	if r.URL.Query().Get("all") == "1" {
		return ""
	}
	return device(r).ID
}

func (s *Server) listCalls(w http.ResponseWriter, r *http.Request) {
	calls, err := s.DB.Calls(r.Context(), scopeDevice(r), intParam(r, "limit", 200, 1, 5000))
	if err != nil {
		internal(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"calls": calls})
}

func (s *Server) getCall(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	call, err := s.DB.Call(r.Context(), id)
	if errors.Is(err, db.ErrNotFound) {
		fail(w, http.StatusNotFound, "no such call")
		return
	}
	if err != nil {
		internal(w, err)
		return
	}
	speakers, err := s.DB.Speakers(r.Context(), id)
	if err != nil {
		internal(w, err)
		return
	}
	captures, err := s.DB.Captures(r.Context(), id)
	if err != nil {
		internal(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"call": call, "speakers": speakers, "captures": captures})
}

func (s *Server) getManifest(w http.ResponseWriter, r *http.Request) {
	m, err := s.Vault.CallManifest(r.PathValue("id"), intParam(r, "version", 0, 0, 1<<30))
	if errors.Is(err, vault.ErrNotFound) {
		fail(w, http.StatusNotFound, "no such call or version")
		return
	}
	if err != nil {
		internal(w, err)
		return
	}
	writeJSON(w, http.StatusOK, m)
}

func (s *Server) getTurns(w http.ResponseWriter, r *http.Request) {
	turns, err := s.DB.Turns(r.Context(), r.PathValue("id"), intParam(r, "revision", 1, 0, 100))
	if err != nil {
		internal(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"turns": turns})
}

func (s *Server) search(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query().Get("q")
	if q == "" || len(q) > 1000 {
		fail(w, http.StatusBadRequest, "q is required")
		return
	}
	var vec []float32
	if s.Embedder != nil {
		v, err := s.Embedder.EmbedQuery(r.Context(), q)
		if err != nil {
			slog.Warn("query embedding failed, using full text only", "err", err)
		} else {
			vec = v
		}
	}
	hits, err := s.DB.Search(r.Context(), q, vec, scopeDevice(r), intParam(r, "limit", 20, 1, 100))
	if err != nil {
		internal(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"hits": hits, "semantic": vec != nil})
}

// ---- device snapshot and restore

func (s *Server) commitDevice(w http.ResponseWriter, r *http.Request) {
	var m manifest.Device
	if !readJSON(w, r, &m, 32<<20) {
		return
	}
	if err := m.Validate(); err != nil {
		fail(w, http.StatusBadRequest, err.Error())
		return
	}
	if missing := s.missing(m.Files); len(missing) > 0 {
		writeJSON(w, http.StatusConflict, map[string]any{"error": "blobs missing", "missing": missing})
		return
	}
	digest := m.ContentSHA()
	dev := device(r).ID
	var version int
	var unchanged bool
	err := pgx.BeginFunc(r.Context(), s.DB.Pool, func(tx pgx.Tx) error {
		if err := db.LockDevice(r.Context(), tx, dev); err != nil {
			return err
		}
		current, err := db.CurrentDeviceSnapshotSHA(r.Context(), tx, dev)
		if err != nil {
			return err
		}
		if current == digest {
			unchanged = true
			return tx.QueryRow(r.Context(), `SELECT max(version) FROM device_snapshots WHERE device_id = $1`, dev).Scan(&version)
		}
		now := time.Now().UTC()
		m.DeviceID, m.CommittedAt = dev, &now
		if version, err = s.Vault.SaveDeviceManifest(&m); err != nil {
			return err
		}
		_, err = tx.Exec(r.Context(), `INSERT INTO device_snapshots(device_id, version, manifest_sha, committed_at) VALUES ($1,$2,$3,$4)`,
			dev, version, digest, now)
		return err
	})
	if err != nil {
		internal(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"version": version, "unchanged": unchanged})
}

// restore hands a fresh install everything it needs to rebuild: a device
// snapshot (this device's, or ?from=<device id> when replacing another Mac)
// and the newest manifest of every call, optionally only one device's with
// ?device=<id>. Blobs are then fetched one by one with Range support, so an
// interrupted restore resumes.
func (s *Server) restore(w http.ResponseWriter, r *http.Request) {
	from := r.URL.Query().Get("from")
	if from == "" {
		from = device(r).ID
	}
	resp := map[string]any{"device_id": device(r).ID}
	if snap, err := s.Vault.DeviceManifest(from, 0); err == nil {
		resp["device_snapshot"] = snap
	} else if !errors.Is(err, vault.ErrNotFound) {
		internal(w, err)
		return
	}
	ids, err := s.Vault.CallIDs()
	if err != nil {
		internal(w, err)
		return
	}
	only := r.URL.Query().Get("device")
	calls := []*manifest.Call{}
	for _, id := range ids {
		m, err := s.Vault.CallManifest(id, 0)
		if err != nil {
			internal(w, fmt.Errorf("%s: %w", id, err))
			return
		}
		if only == "" || m.DeviceID == only {
			calls = append(calls, m)
		}
	}
	resp["calls"] = calls
	writeJSON(w, http.StatusOK, resp)
}

// ---- inbox

func (s *Server) listInbox(w http.ResponseWriter, r *http.Request) {
	after := int64(intParam(r, "after", 0, 0, 1<<62))
	msgs, err := s.DB.Pending(r.Context(), device(r).ID, after, intParam(r, "limit", 100, 1, 500))
	if err != nil {
		internal(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"messages": msgs})
}

func (s *Server) streamInbox(w http.ResponseWriter, r *http.Request) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		internal(w, errors.New("streaming unsupported"))
		return
	}
	dev := device(r).ID
	after, _ := strconv.ParseInt(r.Header.Get("Last-Event-ID"), 10, 64)
	if q := r.URL.Query().Get("after"); q != "" {
		after, _ = strconv.ParseInt(q, 10, 64)
	}
	wake, cancel := s.Broker.Subscribe(dev)
	defer cancel()

	h := w.Header()
	h.Set("Content-Type", "text/event-stream")
	h.Set("Cache-Control", "no-cache")
	h.Set("X-Accel-Buffering", "no")
	w.WriteHeader(http.StatusOK)
	fmt.Fprint(w, "retry: 5000\n: connected\n\n")
	flusher.Flush()

	beat := time.NewTicker(s.Heartbeat)
	defer beat.Stop()
	for {
		msgs, err := s.DB.Pending(r.Context(), dev, after, 100)
		if err != nil {
			if r.Context().Err() == nil {
				slog.Warn("inbox stream", "device", dev, "err", err)
			}
			return
		}
		for _, m := range msgs {
			b, _ := json.Marshal(m)
			fmt.Fprintf(w, "id: %d\nevent: message\ndata: %s\n\n", m.ID, b)
			after = m.ID
		}
		if len(msgs) > 0 {
			flusher.Flush()
			if len(msgs) == 100 {
				continue
			}
		}
		select {
		case <-r.Context().Done():
			return
		case <-wake:
		case <-beat.C:
			fmt.Fprint(w, ": ping\n\n")
			flusher.Flush()
		}
	}
}

func (s *Server) ackInbox(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		fail(w, http.StatusBadRequest, "bad id")
		return
	}
	var body struct {
		OK    bool   `json:"ok"`
		Error string `json:"error,omitempty"`
	}
	if !readJSON(w, r, &body, 64<<10) {
		return
	}
	result, _ := json.Marshal(body)
	err = s.DB.Ack(r.Context(), device(r).ID, id, result)
	if errors.Is(err, db.ErrNotFound) {
		fail(w, http.StatusNotFound, "no such message for this device")
		return
	}
	if err != nil {
		internal(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"id": id, "acked": true})
}

func (s *Server) getBundle(w http.ResponseWriter, r *http.Request) {
	b, err := s.Vault.Bundle(r.PathValue("id"))
	if errors.Is(err, vault.ErrNotFound) || (err == nil && b.DeviceID != "" && b.DeviceID != device(r).ID) {
		fail(w, http.StatusNotFound, "no such bundle")
		return
	}
	if err != nil {
		internal(w, err)
		return
	}
	writeJSON(w, http.StatusOK, b)
}

// ---- helpers

func readJSON(w http.ResponseWriter, r *http.Request, v any, limit int64) bool {
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, limit))
	if err := dec.Decode(v); err != nil {
		fail(w, http.StatusBadRequest, "bad JSON: "+err.Error())
		return false
	}
	return true
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func fail(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]string{"error": msg})
}

func internal(w http.ResponseWriter, err error) {
	slog.Error("request failed", "err", err)
	fail(w, http.StatusInternalServerError, "internal error")
}

func intParam(r *http.Request, name string, def, lo, hi int) int {
	v, err := strconv.Atoi(r.URL.Query().Get(name))
	if err != nil {
		return def
	}
	return max(lo, min(hi, v))
}

type statusWriter struct {
	http.ResponseWriter
	code int
	n    int64
}

func (s *statusWriter) WriteHeader(c int) { s.code = c; s.ResponseWriter.WriteHeader(c) }
func (s *statusWriter) Write(b []byte) (int, error) {
	n, err := s.ResponseWriter.Write(b)
	s.n += int64(n)
	return n, err
}
func (s *statusWriter) Flush() {
	if f, ok := s.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

func logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		sw := &statusWriter{ResponseWriter: w, code: http.StatusOK}
		next.ServeHTTP(sw, r)
		if r.URL.Path == "/healthz" {
			return
		}
		slog.Info("http", "method", r.Method, "path", r.URL.Path, "status", sw.code, "bytes", sw.n,
			"in", r.ContentLength, "took", time.Since(start).Round(time.Millisecond))
	})
}
