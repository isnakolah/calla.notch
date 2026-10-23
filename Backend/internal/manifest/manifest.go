// Package manifest is the wire contract between calla.notch and the backend.
//
// A call upload is a set of content-addressed blobs plus one manifest naming
// them. Paths inside a manifest follow three prefixes:
//
//	raw/     files copied verbatim from the Mac's call directory
//	export/  the readable copy calla.notch writes to ~/Documents/Calls
//	store/   one <table>.jsonl per SQLite table, rows for this call only
//
// The Swift side of this contract lives in CallaEngine/CallaBackendSync.swift.
package manifest

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"path"
	"regexp"
	"sort"
	"strings"
	"time"
)

const Format = 1

var (
	callIDPattern = regexp.MustCompile(`^call-[A-Za-z0-9-]{8,72}$`)
	shaPattern    = regexp.MustCompile(`^[0-9a-f]{64}$`)
)

type File struct {
	Path   string `json:"path"`
	SHA256 string `json:"sha256"`
	Size   int64  `json:"size"`
	Type   string `json:"type,omitempty"`
}

type Flags struct {
	AccurateTranscript bool `json:"accurate_transcript"`
	Recap              bool `json:"recap"`
	Speakers           bool `json:"speakers"`
	Audio              bool `json:"audio"`
}

type CallInfo struct {
	Persona   string     `json:"persona,omitempty"`
	Title     string     `json:"title,omitempty"`
	StartedAt *time.Time `json:"started_at,omitempty"`
	EndedAt   *time.Time `json:"ended_at,omitempty"`
	EventID   string     `json:"event_id,omitempty"`
	SeriesID  string     `json:"series_id,omitempty"`
}

type Call struct {
	Format        int        `json:"format"`
	CallID        string     `json:"call_id"`
	AppVersion    string     `json:"app_version,omitempty"`
	SchemaVersion int        `json:"schema_version,omitempty"`
	Flags         Flags      `json:"flags"`
	Call          CallInfo   `json:"call"`
	Files         []File     `json:"files"`
	DeviceID      string     `json:"device_id,omitempty"` // set by the server
	CommittedAt   *time.Time `json:"committed_at,omitempty"`
	Version       int        `json:"version,omitempty"` // set by the server
}

// Device is the device-wide state no single call owns: voiceprints, knowledge
// notes, the settings snapshot.
type Device struct {
	Format        int        `json:"format"`
	AppVersion    string     `json:"app_version,omitempty"`
	SchemaVersion int        `json:"schema_version,omitempty"`
	Hardware      string     `json:"hardware,omitempty"`
	Files         []File     `json:"files"`
	DeviceID      string     `json:"device_id,omitempty"`
	CommittedAt   *time.Time `json:"committed_at,omitempty"`
	Version       int        `json:"version,omitempty"`
}

func ValidCallID(id string) bool { return callIDPattern.MatchString(id) }
func ValidSHA(s string) bool     { return shaPattern.MatchString(s) }

// CleanPath refuses anything that could escape a destination directory when
// the Mac restores files.
func CleanPath(p string) (string, error) {
	if p == "" || len(p) > 512 || strings.ContainsAny(p, "\x00\\") {
		return "", fmt.Errorf("bad path %q", p)
	}
	c := path.Clean(p)
	if c != p || path.IsAbs(c) || c == "." || c == ".." || strings.HasPrefix(c, "../") {
		return "", fmt.Errorf("bad path %q", p)
	}
	return c, nil
}

func validateFiles(files []File, prefixes []string) error {
	if len(files) == 0 {
		return errors.New("manifest has no files")
	}
	if len(files) > 20000 {
		return errors.New("manifest has too many files")
	}
	seen := make(map[string]bool, len(files))
	for _, f := range files {
		if _, err := CleanPath(f.Path); err != nil {
			return err
		}
		ok := false
		for _, p := range prefixes {
			if strings.HasPrefix(f.Path, p) {
				ok = true
			}
		}
		if !ok {
			return fmt.Errorf("path %q is outside %v", f.Path, prefixes)
		}
		if seen[f.Path] {
			return fmt.Errorf("duplicate path %q", f.Path)
		}
		seen[f.Path] = true
		if !ValidSHA(f.SHA256) {
			return fmt.Errorf("bad sha256 for %q", f.Path)
		}
		if f.Size < 0 {
			return fmt.Errorf("bad size for %q", f.Path)
		}
	}
	return nil
}

func (m *Call) Validate() error {
	if m.Format != Format {
		return fmt.Errorf("unsupported manifest format %d", m.Format)
	}
	if !ValidCallID(m.CallID) {
		return fmt.Errorf("bad call_id %q", m.CallID)
	}
	return validateFiles(m.Files, []string{"raw/", "export/", "store/"})
}

func (m *Device) Validate() error {
	if m.Format != Format {
		return fmt.Errorf("unsupported manifest format %d", m.Format)
	}
	return validateFiles(m.Files, []string{"store/", "settings/", "meta/"})
}

// Lookup returns the file at an exact manifest path.
func (m *Call) Lookup(p string) (File, bool) {
	for _, f := range m.Files {
		if f.Path == p {
			return f, true
		}
	}
	return File{}, false
}

// Bundle is a server-made container for calla.notch to pick up: context
// files, components, anything the Mac should place under its bundles folder.
type Bundle struct {
	Format      int        `json:"format"`
	ID          string     `json:"id"`
	Description string     `json:"description,omitempty"`
	DeviceID    string     `json:"device_id,omitempty"` // empty: any device may fetch it
	Files       []File     `json:"files"`
	CreatedAt   *time.Time `json:"created_at,omitempty"`
}

var bundleIDPattern = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{1,63}$`)

func ValidBundleID(id string) bool { return bundleIDPattern.MatchString(id) }

// ContentSHA identifies what a call manifest says, ignoring the fields the
// server stamps on commit. Equal digests mean a repeat upload.
func (m *Call) ContentSHA() string {
	c := *m
	c.DeviceID, c.CommittedAt, c.Version = "", nil, 0
	c.Files = append([]File(nil), m.Files...)
	sort.Slice(c.Files, func(i, j int) bool { return c.Files[i].Path < c.Files[j].Path })
	b, _ := json.Marshal(c)
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

func (m *Device) ContentSHA() string {
	c := *m
	c.DeviceID, c.CommittedAt, c.Version = "", nil, 0
	c.Files = append([]File(nil), m.Files...)
	sort.Slice(c.Files, func(i, j int) bool { return c.Files[i].Path < c.Files[j].Path })
	b, _ := json.Marshal(c)
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}
