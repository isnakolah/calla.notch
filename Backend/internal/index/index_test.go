package index

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"strconv"
	"strings"
	"testing"

	"calla.notch/backend/internal/manifest"
	"calla.notch/backend/internal/vault"
)

// Shapes copied from a real call directory and store dump.
const (
	liveTranscript = `{"confidence":0.8,"id":"5BE8","seq":0,"source":"me","t0":55.56,"t1":60.36,"text":"He also has a very good life.","utteranceID":"A0A6"}
{"confidence":0.5,"id":"85C9","seq":1,"source":"them","t0":61.0,"t1":63.0,"text":"live words"}
`
	archiveTranscript = `{"id":"94C0","seq":0,"source":"me","t0":0.06,"t1":3.38,"text":"You have some nerve showing up here."}
{"id":"5628","seq":1,"source":"them","t0":3.38,"t1":4.42,"text":"You're here."}
{"torn line`
	storeTurns = `{"call_id":"call-12345678","seq":0,"revision":1,"source":"me","t0":0.06,"t1":3.38,"text":"You have some nerve showing up here.","confidence":null,"no_speech":null,"speaker_id":null}
{"call_id":"call-12345678","seq":1,"revision":1,"source":"them","t0":3.38,"t1":4.42,"text":"You're here.","confidence":0.9,"no_speech":0.01,"speaker_id":"S1"}
`
	storeSpeakers = `{"call_id":"call-12345678","speaker_id":"S1","label":"Professor Plum","person_id":"p1","name_source":"voiceprint","confidence":0.82,"speech_seconds":12.5,"embedding":{"$b64":"AAAA"}}
`
	captures = `{"file":"00-08-00.jpg","offset":480.48,"taken_at":"2026-10-15T22:16:16Z","text":"Warp\nBUILD SUCCEEDED"}
`
)

type fakeEmbedder struct{ calls int }

func (f *fakeEmbedder) Embed(_ context.Context, texts []string) ([][]float32, error) {
	f.calls++
	out := make([][]float32, len(texts))
	for i := range out {
		out[i] = make([]float32, 384)
		out[i][0] = 1
	}
	return out, nil
}
func (f *fakeEmbedder) EmbedQuery(context.Context, string) ([]float32, error) { return nil, nil }

func put(t *testing.T, v *vault.Vault, m *manifest.Call, p, body string) {
	t.Helper()
	sum := sha256.Sum256([]byte(body))
	sha := hex.EncodeToString(sum[:])
	if _, err := v.PutBlob(sha, strings.NewReader(body), int64(len(body)), 1<<20); err != nil {
		t.Fatal(err)
	}
	m.Files = append(m.Files, manifest.File{Path: p, SHA256: sha, Size: int64(len(body))})
}

func TestBuildPrefersStoreRowsAndNamesSpeakers(t *testing.T) {
	v, _ := vault.Open(t.TempDir(), 0)
	m := &manifest.Call{Format: 1, CallID: "call-12345678"}
	put(t, v, m, "raw/transcript.jsonl", liveTranscript)
	put(t, v, m, "raw/transcript-archive.jsonl", archiveTranscript)
	put(t, v, m, "store/call_turn.jsonl", storeTurns)
	put(t, v, m, "store/call_speaker.jsonl", storeSpeakers)
	put(t, v, m, "raw/captures/captures.jsonl", captures)
	put(t, v, m, "raw/captures/00-08-00.jpg", "jpegbytes")
	put(t, v, m, "export/summary.md", "# Standup\nShipped the build.")

	e := &fakeEmbedder{}
	ix, err := Build(context.Background(), v, m, e)
	if err != nil {
		t.Fatal(err)
	}
	// Store rows supply revision 1; the raw archive must not duplicate them,
	// and the live raw transcript still fills revision 0.
	var r0, r1 int
	for _, tr := range ix.Turns {
		if tr.Revision == 0 {
			r0++
		} else {
			r1++
		}
	}
	if r0 != 2 || r1 != 2 {
		t.Fatalf("revision counts r0=%d r1=%d", r0, r1)
	}
	if len(ix.Speakers) != 1 || *ix.Speakers[0].Label != "Professor Plum" {
		t.Fatalf("speakers %+v", ix.Speakers)
	}
	if len(ix.Captures) != 1 || ix.Captures[0].BlobSHA == "" || ix.Captures[0].TakenAt == nil {
		t.Fatalf("captures %+v", ix.Captures)
	}
	kinds := map[string]int{}
	var transcript string
	for _, c := range ix.Chunks {
		kinds[c.Kind]++
		if c.Kind == "transcript" {
			transcript = c.Text
		}
		if len(c.Embedding) != 384 {
			t.Fatalf("chunk %s not embedded", c.Ref)
		}
	}
	if kinds["transcript"] != 1 || kinds["capture"] != 1 || kinds["recap"] != 1 {
		t.Fatalf("chunk kinds %v", kinds)
	}
	if !strings.Contains(transcript, "Professor Plum: You're here.") || !strings.Contains(transcript, "Me: You have some nerve") {
		t.Fatalf("transcript chunk:\n%s", transcript)
	}
}

func TestBuildFallsBackToRawTranscripts(t *testing.T) {
	v, _ := vault.Open(t.TempDir(), 0)
	m := &manifest.Call{Format: 1, CallID: "call-12345678"}
	put(t, v, m, "raw/transcript.jsonl", liveTranscript)
	ix, err := Build(context.Background(), v, m, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(ix.Turns) != 2 || ix.Turns[0].Revision != 0 || len(ix.Chunks) != 1 {
		t.Fatalf("turns %+v chunks %+v", ix.Turns, ix.Chunks)
	}
}

func TestChunksSplitLongCalls(t *testing.T) {
	var b strings.Builder
	for i := range 40 {
		b.WriteString(`{"seq":` + itoa(i) + `,"source":"them","t0":` + itoa(i*10) + `,"t1":` + itoa(i*10+9) + `,"text":"sentence number ` + itoa(i) + `"}` + "\n")
	}
	v, _ := vault.Open(t.TempDir(), 0)
	m := &manifest.Call{Format: 1, CallID: "call-12345678"}
	put(t, v, m, "raw/transcript-archive.jsonl", b.String())
	ix, _ := Build(context.Background(), v, m, nil)
	if len(ix.Chunks) < 8 {
		t.Fatalf("400s of speech in %d chunks", len(ix.Chunks))
	}
	for _, c := range ix.Chunks {
		if *c.T1-*c.T0 > chunkSeconds {
			t.Fatalf("chunk %s spans %.0fs", c.Ref, *c.T1-*c.T0)
		}
	}
}

func itoa(i int) string { return strconv.Itoa(i) }
