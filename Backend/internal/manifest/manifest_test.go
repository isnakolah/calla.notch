package manifest

import (
	"strings"
	"testing"
)

const sha = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

func TestCleanPath(t *testing.T) {
	for _, bad := range []string{"", "/etc/passwd", "../x", "raw/../../x", "raw//x", "raw/./x", `raw\x`, "raw/x\x00"} {
		if _, err := CleanPath(bad); err == nil {
			t.Errorf("%q accepted", bad)
		}
	}
	for _, good := range []string{"raw/mic.flac", "export/notes/a b.md", "store/call_turn.jsonl"} {
		if _, err := CleanPath(good); err != nil {
			t.Errorf("%q refused: %v", good, err)
		}
	}
}

func TestValidate(t *testing.T) {
	m := Call{Format: 1, CallID: "call-c9d6e296-e40c-47", Files: []File{{Path: "raw/transcript.jsonl", SHA256: sha}}}
	if err := m.Validate(); err != nil {
		t.Fatal(err)
	}
	for name, mutate := range map[string]func(*Call){
		"traversal id": func(c *Call) { c.CallID = "call-../../etc" },
		"bad prefix":   func(c *Call) { c.Files[0].Path = "tmp/x" },
		"bad sha":      func(c *Call) { c.Files[0].SHA256 = strings.ToUpper(sha) },
		"dup path":     func(c *Call) { c.Files = append(c.Files, c.Files[0]) },
		"no files":     func(c *Call) { c.Files = nil },
		"format":       func(c *Call) { c.Format = 2 },
	} {
		c := m
		c.Files = append([]File(nil), m.Files...)
		mutate(&c)
		if c.Validate() == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

func TestContentSHAIgnoresServerFieldsAndOrder(t *testing.T) {
	a := Call{Format: 1, CallID: "call-12345678", Files: []File{{Path: "raw/a", SHA256: sha}, {Path: "raw/b", SHA256: sha}}}
	b := a
	b.Files = []File{a.Files[1], a.Files[0]}
	b.DeviceID, b.Version = "dev_x", 7
	if a.ContentSHA() != b.ContentSHA() {
		t.Fatal("digest depends on order or server fields")
	}
	b.Flags.AccurateTranscript = true
	if a.ContentSHA() == b.ContentSHA() {
		t.Fatal("digest ignores flags")
	}
}
