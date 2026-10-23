package api

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

	"calla.notch/backend/internal/auth"
	"calla.notch/backend/internal/db"
	"calla.notch/backend/internal/inbox"
	"calla.notch/backend/internal/index"
	"calla.notch/backend/internal/manifest"
	"calla.notch/backend/internal/vault"
)

// Needs a disposable pgvector database:
//
//	docker run -d --rm -p 127.0.0.1:55432:5432 -e POSTGRES_PASSWORD=t pgvector/pgvector:pg17
//	CALLA_TEST_DATABASE_URL=postgres://postgres:t@127.0.0.1:55432/postgres go test ./...
//
// The test drops every table first.
func testServer(t *testing.T) (*httptest.Server, *db.DB, *vault.Vault) {
	url := os.Getenv("CALLA_TEST_DATABASE_URL")
	if url == "" {
		t.Skip("CALLA_TEST_DATABASE_URL not set")
	}
	ctx := context.Background()
	d, err := db.Open(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := d.Pool.Exec(ctx, `DROP SCHEMA public CASCADE; CREATE SCHEMA public`); err != nil {
		t.Fatal(err)
	}
	d.Pool.Reset()
	if err := d.Migrate(ctx); err != nil {
		t.Fatal(err)
	}
	v, err := vault.Open(t.TempDir(), 0)
	if err != nil {
		t.Fatal(err)
	}
	broker := inbox.NewBroker()
	lctx, cancel := context.WithCancel(ctx)
	go broker.Listen(lctx, d.Pool)
	s := &Server{DB: d, Vault: v, Broker: broker, MaxBlob: 1 << 20, Heartbeat: time.Second,
		EnrollSecret: "test-enroll-secret", PublicURL: "https://calla.example"}
	ts := httptest.NewServer(s.Handler())
	t.Cleanup(func() { ts.Close(); cancel(); d.Close() })
	return ts, d, v
}

func enrollDevice(t *testing.T, d *db.DB, name string) (string, string) {
	tok, _ := auth.NewToken()
	id, _ := auth.NewDeviceID()
	if err := d.UpsertDevice(context.Background(), db.Device{ID: id, Name: name, TokenHash: auth.Hash(tok), CreatedAt: time.Now()}); err != nil {
		t.Fatal(err)
	}
	return id, tok
}

type client struct {
	t     *testing.T
	base  string
	token string
}

func (c client) do(method, path string, body io.Reader, out any) int {
	c.t.Helper()
	req, _ := http.NewRequest(method, c.base+path, body)
	if c.token != "" {
		req.Header.Set("Authorization", "Bearer "+c.token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		c.t.Fatal(err)
	}
	defer resp.Body.Close()
	if out != nil {
		_ = json.NewDecoder(resp.Body).Decode(out)
	}
	return resp.StatusCode
}

func (c client) json(method, path string, in, out any) int {
	b, _ := json.Marshal(in)
	return c.do(method, path, bytes.NewReader(b), out)
}

func sum(s string) string {
	h := sha256.Sum256([]byte(s))
	return hex.EncodeToString(h[:])
}

func TestEndToEnd(t *testing.T) {
	ts, d, v := testServer(t)
	devID, tok := enrollDevice(t, d, "Studio Mac")
	c := client{t: t, base: ts.URL, token: tok}
	ctx := context.Background()

	// Auth
	if code := (client{t: t, base: ts.URL}).do("GET", "/v1/me", nil, nil); code != 401 {
		t.Fatalf("no token: %d", code)
	}
	if code := (client{t: t, base: ts.URL, token: "cbk_nope"}).do("GET", "/v1/me", nil, nil); code != 401 {
		t.Fatalf("bad token: %d", code)
	}
	var me map[string]string
	if c.do("GET", "/v1/me", nil, &me); me["device_id"] != devID {
		t.Fatalf("me %v", me)
	}

	// Upload
	files := map[string]string{
		"raw/transcript.jsonl":         `{"seq":0,"source":"them","t0":1,"t1":4,"text":"the quarterly budget is approved"}` + "\n",
		"raw/transcript-archive.jsonl": `{"seq":0,"source":"them","t0":1,"t1":4,"text":"the quarterly budget is approved today"}` + "\n",
		"raw/mic.flac":                 "fLaC...audio",
		"store/call.jsonl":             `{"id":"call-12345678-e2e","persona":"standup"}` + "\n",
	}
	m := manifest.Call{Format: 1, CallID: "call-12345678-e2e", Flags: manifest.Flags{AccurateTranscript: true, Audio: true},
		Call: manifest.CallInfo{Persona: "standup", Title: "Budget sync"}}
	var shas []string
	for p, body := range files {
		m.Files = append(m.Files, manifest.File{Path: p, SHA256: sum(body), Size: int64(len(body))})
		shas = append(shas, sum(body))
	}

	var check struct{ Missing []string }
	c.json("POST", "/v1/blobs/check", map[string]any{"sha256": shas}, &check)
	if len(check.Missing) != len(files) {
		t.Fatalf("missing %v", check.Missing)
	}
	if code := c.json("POST", "/v1/calls/call-12345678-e2e/commit", m, nil); code != 409 {
		t.Fatalf("commit before upload: %d", code)
	}
	if code := c.do("PUT", "/v1/blobs/"+sum("x"), strings.NewReader("y"), nil); code != 422 {
		t.Fatalf("hash mismatch: %d", code)
	}
	for _, body := range files {
		if code := c.do("PUT", "/v1/blobs/"+sum(body), strings.NewReader(body), nil); code != 201 {
			t.Fatalf("put: %d", code)
		}
	}

	var res struct {
		Version   int
		Unchanged bool
	}
	if code := c.json("POST", "/v1/calls/call-12345678-e2e/commit", m, &res); code != 200 || res.Version != 1 {
		t.Fatalf("commit: %d %+v", code, res)
	}
	if c.json("POST", "/v1/calls/call-12345678-e2e/commit", m, &res); !res.Unchanged || res.Version != 1 {
		t.Fatalf("repeat commit not idempotent: %+v", res)
	}
	if code := c.json("POST", "/v1/calls/call-99999999-e2e/commit", m, nil); code != 400 {
		t.Fatalf("path/body id mismatch: %d", code)
	}

	// Index, then search
	w := &index.Worker{DB: d, Vault: v}
	if ran, err := w.RunOne(ctx); !ran || err != nil {
		t.Fatalf("index job: %v %v", ran, err)
	}
	var turns struct{ Turns []db.Turn }
	c.do("GET", "/v1/calls/call-12345678-e2e/turns?revision=1", nil, &turns)
	if len(turns.Turns) != 1 || !strings.Contains(turns.Turns[0].Text, "today") {
		t.Fatalf("turns %+v", turns)
	}
	var hits struct{ Hits []db.Hit }
	c.do("GET", "/v1/search?q=budget", nil, &hits)
	if len(hits.Hits) == 0 || hits.Hits[0].CallID != "call-12345678-e2e" {
		t.Fatalf("search %+v", hits)
	}

	// Inbox over SSE: push after connecting, expect delivery, then ack.
	req, _ := http.NewRequest("GET", ts.URL+"/v1/inbox/stream", nil)
	req.Header.Set("Authorization", "Bearer "+tok)
	sctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	resp, err := http.DefaultClient.Do(req.WithContext(sctx))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	id, err := d.Push(ctx, devID, "notify", json.RawMessage(`{"title":"hello"}`))
	if err != nil {
		t.Fatal(err)
	}
	var got db.Message
	sc := bufio.NewScanner(resp.Body)
	for sc.Scan() {
		if data, ok := strings.CutPrefix(sc.Text(), "data: "); ok {
			_ = json.Unmarshal([]byte(data), &got)
			break
		}
	}
	if got.ID != id || got.Kind != "notify" {
		t.Fatalf("stream delivered %+v", got)
	}
	if code := c.json("POST", "/v1/inbox/"+itoa(id)+"/ack", map[string]any{"ok": true}, nil); code != 200 {
		t.Fatalf("ack: %d", code)
	}
	var pending struct{ Messages []db.Message }
	if c.do("GET", "/v1/inbox", nil, &pending); len(pending.Messages) != 0 {
		t.Fatalf("acked message still pending: %+v", pending)
	}

	// Another device cannot ack it, but can restore the call.
	_, tok2 := enrollDevice(t, d, "Laptop")
	c2 := client{t: t, base: ts.URL, token: tok2}
	if code := c2.json("POST", "/v1/inbox/"+itoa(id)+"/ack", map[string]any{"ok": true}, nil); code != 404 {
		t.Fatalf("cross-device ack: %d", code)
	}
	var restore struct {
		Calls []manifest.Call
	}
	c2.do("GET", "/v1/restore", nil, &restore)
	if len(restore.Calls) != 1 || len(restore.Calls[0].Files) != len(files) || restore.Calls[0].DeviceID != devID {
		t.Fatalf("restore %+v", restore)
	}

	// Revocation takes effect immediately.
	if _, err := d.Pool.Exec(ctx, `UPDATE devices SET revoked_at = now() WHERE id = $1`, devID); err != nil {
		t.Fatal(err)
	}
	if code := c.do("GET", "/v1/me", nil, nil); code != 401 {
		t.Fatalf("revoked token: %d", code)
	}
}

func itoa(i int64) string { return strconv.FormatInt(i, 10) }

func TestEnrollOverHTTP(t *testing.T) {
	ts, _, _ := testServer(t)
	enroll := func(secret, body string) (int, map[string]string) {
		req, _ := http.NewRequest("POST", ts.URL+"/v1/enroll", strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer "+secret)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		var out map[string]string
		_ = json.NewDecoder(resp.Body).Decode(&out)
		return resp.StatusCode, out
	}
	if code, _ := enroll("wrong", `{"name":"Mac"}`); code != http.StatusUnauthorized {
		t.Fatalf("wrong secret: %d", code)
	}
	code, first := enroll("test-enroll-secret", `{"name":"Mac"}`)
	if code != 200 || !strings.HasPrefix(first["token"], "cbk_") || first["url"] != "https://calla.example" {
		t.Fatalf("enroll: %d %v", code, first)
	}
	me := client{t: t, base: ts.URL, token: first["token"]}
	var who map[string]string
	if code := me.do("GET", "/v1/me", nil, &who); code != 200 || who["device_id"] != first["device_id"] {
		t.Fatalf("me: %d %v", code, who)
	}
	// Same name again keeps the identity and rotates the token.
	_, again := enroll("test-enroll-secret", `{"name":"Mac"}`)
	if again["device_id"] != first["device_id"] || again["token"] == first["token"] {
		t.Fatalf("reuse: %v", again)
	}
	if code := me.do("GET", "/v1/me", nil, nil); code != http.StatusUnauthorized {
		t.Fatalf("old token still works: %d", code)
	}
	// A device id the server forgot falls back to the name.
	_, byID := enroll("test-enroll-secret", `{"name":"Mac","device_id":"dev_0000000000000000"}`)
	if byID["device_id"] != first["device_id"] {
		t.Fatalf("unknown id: %v", byID)
	}
}
