package vault

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"strings"
	"sync"
	"testing"

	"calla.notch/backend/internal/manifest"
)

func digest(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:])
}

func TestPutBlobVerifiesHash(t *testing.T) {
	v, err := Open(t.TempDir(), 0)
	if err != nil {
		t.Fatal(err)
	}
	sha := digest("hello")
	if _, err := v.PutBlob(sha, strings.NewReader("hellO"), 5, 100); !errors.Is(err, ErrHashMismatch) {
		t.Fatalf("want hash mismatch, got %v", err)
	}
	if v.HasBlob(sha) {
		t.Fatal("rejected blob was kept")
	}
	if _, err := v.PutBlob(sha, strings.NewReader("hello"), 5, 100); err != nil {
		t.Fatal(err)
	}
	b, err := v.ReadBlob(sha, 100)
	if err != nil || string(b) != "hello" {
		t.Fatalf("read back %q, %v", b, err)
	}
}

func TestPutBlobSizeLimit(t *testing.T) {
	v, _ := Open(t.TempDir(), 0)
	if _, err := v.PutBlob(digest("123456"), strings.NewReader("123456"), -1, 5); !errors.Is(err, ErrTooLarge) {
		t.Fatalf("want too large, got %v", err)
	}
}

func TestLowDiskRefuses(t *testing.T) {
	v, _ := Open(t.TempDir(), 1<<62)
	if _, err := v.PutBlob(digest("x"), strings.NewReader("x"), 1, 10); !errors.Is(err, ErrLowDisk) {
		t.Fatalf("want low disk, got %v", err)
	}
}

func TestManifestVersionsNeverCollide(t *testing.T) {
	v, _ := Open(t.TempDir(), 0)
	var wg sync.WaitGroup
	var mu sync.Mutex
	seen := map[int]bool{}
	fails := 0
	for range 8 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			m := &manifest.Call{Format: 1, CallID: "call-12345678-abcd"}
			n, err := v.SaveCallManifest(m)
			mu.Lock()
			defer mu.Unlock()
			if err != nil {
				fails++ // lost the race for a version: refused, never overwritten
				return
			}
			if seen[n] {
				t.Errorf("version %d written twice", n)
			}
			seen[n] = true
		}()
	}
	wg.Wait()
	if len(seen)+fails != 8 || len(seen) == 0 {
		t.Fatalf("seen %v fails %d", seen, fails)
	}
	m, err := v.CallManifest("call-12345678-abcd", 0)
	if err != nil || !seen[m.Version] {
		t.Fatalf("latest %+v %v", m, err)
	}
}

func TestChunkedUploadResumesAndVerifies(t *testing.T) {
	v, _ := Open(t.TempDir(), 0)
	body := strings.Repeat("abcdefghij", 10)
	sha := digest(body)
	total := int64(len(body))
	if _, _, err := v.AppendChunk(sha, 0, total, strings.NewReader(body[:30]), 30, 1000); err != nil {
		t.Fatal(err)
	}
	// A retry of the first chunk is refused with the current offset.
	got, _, err := v.AppendChunk(sha, 0, total, strings.NewReader(body[:30]), 30, 1000)
	if !errors.Is(err, ErrBadOffset) || got != 30 {
		t.Fatalf("stale chunk: %d %v", got, err)
	}
	// A torn chunk is cut back so the retry lines up.
	if _, _, err := v.AppendChunk(sha, 30, total, strings.NewReader(body[30:40]), 20, 1000); err == nil {
		t.Fatal("short chunk accepted")
	}
	if v.UploadOffset(sha) != 30 {
		t.Fatalf("offset after torn chunk %d", v.UploadOffset(sha))
	}
	_, done, err := v.AppendChunk(sha, 30, total, strings.NewReader(body[30:]), 70, 1000)
	if err != nil || !done || !v.HasBlob(sha) {
		t.Fatalf("finish: %v %v", done, err)
	}

	bad := digest("other")
	if _, _, err := v.AppendChunk(bad, 0, 5, strings.NewReader("wrong"), 5, 1000); !errors.Is(err, ErrHashMismatch) {
		t.Fatalf("want mismatch, got %v", err)
	}
	if v.HasBlob(bad) || v.UploadOffset(bad) != 0 {
		t.Fatal("bad upload left behind")
	}
}

func TestMarkerGuardsAMissingMount(t *testing.T) {
	root := t.TempDir()
	if CheckMarker(root) == nil {
		t.Fatal("empty directory accepted as a vault")
	}
	if err := Init(root); err != nil {
		t.Fatal(err)
	}
	if err := Init(root); err != nil {
		t.Fatalf("second init: %v", err)
	}
	if err := CheckMarker(root); err != nil {
		t.Fatal(err)
	}
}
