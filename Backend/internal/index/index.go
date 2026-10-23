// Package index derives searchable rows from a call manifest. Nothing here is
// authoritative: it reads blobs and produces rows that reindex can always
// recreate.
package index

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"path"
	"sort"
	"strconv"
	"strings"
	"time"

	"calla.notch/backend/internal/db"
	"calla.notch/backend/internal/manifest"
	"calla.notch/backend/internal/vault"
)

const (
	maxTextBlob   = 64 << 20
	chunkSeconds  = 45.0
	chunkMaxChars = 1500
	captureChars  = 2000
)

// Build reads the manifest's blobs and returns the call's derived rows.
// Embeddings are attached when e is non-nil.
func Build(ctx context.Context, v *vault.Vault, m *manifest.Call, e Embedder) (db.CallIndex, error) {
	var ix db.CallIndex
	read := func(p string) ([]byte, bool, error) {
		f, ok := m.Lookup(p)
		if !ok {
			return nil, false, nil
		}
		b, err := v.ReadBlob(f.SHA256, maxTextBlob)
		if err != nil {
			return nil, false, fmt.Errorf("%s: %w", p, err)
		}
		return b, true, nil
	}

	// Speakers and turns: the store dump is the richest source (revisions and
	// speaker assignments); the raw transcripts are the fallback for calls
	// whose store rows were never written.
	if b, ok, err := read("store/call_speaker.jsonl"); err != nil {
		return ix, err
	} else if ok {
		if err := eachLine(b, func(row map[string]any) {
			id := str(row["speaker_id"])
			if id == "" {
				return
			}
			ix.Speakers = append(ix.Speakers, db.Speaker{
				SpeakerID: id, Label: strp(row["label"]), PersonID: strp(row["person_id"]),
				NameSource: strp(row["name_source"]), Confidence: num(row["confidence"]), SpeechSeconds: num(row["speech_seconds"]),
			})
		}); err != nil {
			return ix, err
		}
	}

	if b, ok, err := read("store/call_turn.jsonl"); err != nil {
		return ix, err
	} else if ok {
		if err := eachLine(b, func(row map[string]any) { ix.Turns = appendTurn(ix.Turns, row, -1) }); err != nil {
			return ix, err
		}
	}
	have := map[int]bool{}
	for _, t := range ix.Turns {
		have[t.Revision] = true
	}
	for _, src := range []struct {
		path     string
		revision int
	}{{"raw/transcript.jsonl", 0}, {"raw/transcript-archive.jsonl", 1}} {
		if have[src.revision] {
			continue
		}
		b, ok, err := read(src.path)
		if err != nil {
			return ix, err
		}
		if ok {
			if err := eachLine(b, func(row map[string]any) { ix.Turns = appendTurn(ix.Turns, row, src.revision) }); err != nil {
				return ix, err
			}
		}
	}
	ix.Turns = dedupeTurns(ix.Turns)

	if b, ok, err := read("raw/captures/captures.jsonl"); err != nil {
		return ix, err
	} else if ok {
		if err := eachLine(b, func(row map[string]any) {
			file := path.Base(str(row["file"]))
			if file == "" || file == "." {
				return
			}
			c := db.Capture{File: file, Offset: num(row["offset"]), OCRText: str(row["text"])}
			if f, ok := m.Lookup("raw/captures/" + file); ok {
				c.BlobSHA = f.SHA256
			}
			if t, err := time.Parse(time.RFC3339, str(row["taken_at"])); err == nil {
				c.TakenAt = &t
			}
			if d := str(row["description"]); d != "" {
				c.Description = &d
			}
			ix.Captures = append(ix.Captures, c)
		}); err != nil {
			return ix, err
		}
	}

	if b, ok, err := read("raw/meeting.json"); err != nil {
		return ix, err
	} else if ok && json.Valid(b) {
		ix.Meeting = b
	}

	ix.Chunks = chunks(ix)
	if b, ok, err := read("export/summary.md"); err != nil {
		return ix, err
	} else if ok && len(bytes.TrimSpace(b)) > 0 {
		ix.Chunks = append(ix.Chunks, db.Chunk{Kind: "recap", Ref: "export/summary.md", Text: clip(string(b), 4000)})
	}

	if e != nil && len(ix.Chunks) > 0 {
		texts := make([]string, len(ix.Chunks))
		for i, c := range ix.Chunks {
			texts[i] = c.Text
		}
		vecs, err := e.Embed(ctx, texts)
		if err != nil {
			return ix, err
		}
		for i := range ix.Chunks {
			ix.Chunks[i].Embedding = vecs[i]
		}
	}
	return ix, nil
}

// chunks windows the best transcript revision into retrieval units, and adds
// one unit per screenshot.
func chunks(ix db.CallIndex) []db.Chunk {
	best := 0
	for _, t := range ix.Turns {
		best = max(best, t.Revision)
	}
	names := map[string]string{}
	for _, s := range ix.Speakers {
		if s.Label != nil && *s.Label != "" {
			names[s.SpeakerID] = *s.Label
		}
	}
	who := func(t db.Turn) string {
		if t.SpeakerID != nil {
			if n, ok := names[*t.SpeakerID]; ok {
				return n
			}
		}
		if t.Source == "me" {
			return "Me"
		}
		return "Them"
	}

	var out []db.Chunk
	var buf strings.Builder
	var start, end float64
	var first, last int
	open := false
	flush := func() {
		if !open || strings.TrimSpace(buf.String()) == "" {
			open = false
			buf.Reset()
			return
		}
		t0, t1 := start, end
		out = append(out, db.Chunk{
			Kind: "transcript", Ref: fmt.Sprintf("r%d:%d-%d", best, first, last),
			T0: &t0, T1: &t1, Text: strings.TrimSpace(buf.String()),
		})
		open = false
		buf.Reset()
	}
	for _, t := range ix.Turns {
		if t.Revision != best || strings.TrimSpace(t.Text) == "" {
			continue
		}
		if open && (t.T1-start > chunkSeconds || buf.Len()+len(t.Text) > chunkMaxChars) {
			flush()
		}
		if !open {
			open, start, first = true, t.T0, t.Seq
		}
		end, last = t.T1, t.Seq
		fmt.Fprintf(&buf, "%s: %s\n", who(t), strings.TrimSpace(t.Text))
	}
	flush()

	for _, c := range ix.Captures {
		text := strings.TrimSpace(c.OCRText)
		if c.Description != nil {
			text = strings.TrimSpace(*c.Description + "\n" + text)
		}
		if text == "" {
			continue
		}
		out = append(out, db.Chunk{Kind: "capture", Ref: c.File, T0: c.Offset, T1: c.Offset, Text: clip("Screenshot: "+text, captureChars)})
	}
	return out
}

func appendTurn(turns []db.Turn, row map[string]any, revision int) []db.Turn {
	text := str(row["text"])
	seq, ok1 := intOf(row["seq"])
	t0, ok2 := row["t0"].(float64)
	t1, ok3 := row["t1"].(float64)
	if !ok1 || !ok2 || !ok3 || text == "" {
		return turns
	}
	if revision < 0 {
		r, _ := intOf(row["revision"])
		revision = r
	}
	source := str(row["source"])
	if source == "" {
		source = "them"
	}
	return append(turns, db.Turn{
		Revision: revision, Seq: seq, Source: source, SpeakerID: strp(row["speaker_id"]),
		T0: t0, T1: t1, Text: text, Confidence: num(row["confidence"]),
	})
}

func dedupeTurns(turns []db.Turn) []db.Turn {
	sort.SliceStable(turns, func(i, j int) bool {
		if turns[i].Revision != turns[j].Revision {
			return turns[i].Revision < turns[j].Revision
		}
		return turns[i].Seq < turns[j].Seq
	})
	out := turns[:0]
	for i, t := range turns {
		if i > 0 && t.Revision == turns[i-1].Revision && t.Seq == turns[i-1].Seq {
			out[len(out)-1] = t // last write wins
			continue
		}
		out = append(out, t)
	}
	return out
}

func eachLine(b []byte, fn func(map[string]any)) error {
	sc := bufio.NewScanner(bytes.NewReader(b))
	sc.Buffer(make([]byte, 0, 1<<20), 32<<20)
	for sc.Scan() {
		line := bytes.TrimSpace(sc.Bytes())
		if len(line) == 0 {
			continue
		}
		var row map[string]any
		if json.Unmarshal(line, &row) != nil {
			continue // a torn last line from a crash is not fatal
		}
		fn(row)
	}
	return sc.Err()
}

func str(v any) string {
	switch t := v.(type) {
	case string:
		return t
	case float64:
		return strconv.FormatFloat(t, 'f', -1, 64)
	}
	return ""
}

func strp(v any) *string {
	if s := str(v); s != "" {
		return &s
	}
	return nil
}

func num(v any) *float64 {
	if f, ok := v.(float64); ok {
		return &f
	}
	return nil
}

func intOf(v any) (int, bool) {
	f, ok := v.(float64)
	return int(f), ok
}

func clip(s string, n int) string {
	if len(s) <= n {
		return s
	}
	for n > 0 && !utf8Start(s[n]) {
		n--
	}
	return s[:n]
}

func utf8Start(b byte) bool { return b&0xC0 != 0x80 }
