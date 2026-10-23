// Package vault is the backend's durable, file-based source of truth.
//
//	<root>/blobs/sha256/ab/cd/<sha>             content-addressed files
//	<root>/manifests/calls/<call_id>/<n>.json   every committed call manifest
//	<root>/manifests/devices/<id>/<n>.json      every device snapshot manifest
//	<root>/devices/<id>.json                    enrolled devices (token hash only)
//	<root>/bundles/<id>.json                    containers made for the Macs to pull
//
// Postgres holds nothing that cannot be rebuilt from this tree, except the
// inbox, which is transient by design. Back this directory up; back up
// Postgres only for convenience.
package vault

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"

	"calla.notch/backend/internal/manifest"
)

var (
	ErrHashMismatch = errors.New("content does not match sha256")
	ErrTooLarge     = errors.New("blob exceeds size limit")
	ErrLowDisk      = errors.New("not enough free disk space")
	ErrNotFound     = errors.New("not found")
	ErrBadOffset    = errors.New("offset does not match bytes received")
)

type Vault struct {
	Root string
	// MinFreeBytes refuses writes that would leave less than this free.
	MinFreeBytes uint64

	uploadMu sync.Mutex
	uploads  map[string]*sync.Mutex
}

// Marker names the file that proves root is the real vault. With a network
// mount (the NAS), a missing mount leaves an empty directory behind; serving
// from it would quietly start a second, empty archive on the local disk.
const Marker = ".calla-vault"

// CheckMarker fails unless root carries the vault marker.
func CheckMarker(root string) error {
	if _, err := os.Stat(filepath.Join(root, Marker)); err != nil {
		return fmt.Errorf("%s is not an initialized vault (no %s): is the NAS mounted? Run `calla-backend init-vault` only for a brand-new vault", root, Marker)
	}
	return nil
}

// Init marks root as a vault.
func Init(root string) error {
	if err := os.MkdirAll(root, 0o700); err != nil {
		return err
	}
	f, err := os.OpenFile(filepath.Join(root, Marker), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if errors.Is(err, os.ErrExist) {
		return nil
	}
	if err != nil {
		return err
	}
	_, err = fmt.Fprintln(f, "calla-backend vault; see Backend/README.md")
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	return err
}

func Open(root string, minFree uint64) (*Vault, error) {
	for _, d := range []string{"blobs/sha256", "manifests/calls", "manifests/devices", "devices", "bundles", "tmp"} {
		if err := os.MkdirAll(filepath.Join(root, d), 0o700); err != nil {
			return nil, err
		}
	}
	return &Vault{Root: root, MinFreeBytes: minFree}, nil
}

func (v *Vault) blobPath(sha string) string {
	return filepath.Join(v.Root, "blobs", "sha256", sha[0:2], sha[2:4], sha)
}

func (v *Vault) HasBlob(sha string) bool {
	if !manifest.ValidSHA(sha) {
		return false
	}
	_, err := os.Stat(v.blobPath(sha))
	return err == nil
}

// FreeBytes reports free space on the vault's filesystem.
func (v *Vault) FreeBytes() (uint64, error) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(v.Root, &st); err != nil {
		return 0, err
	}
	return uint64(st.Bavail) * uint64(st.Bsize), nil
}

func (v *Vault) ensureRoom(size int64) error {
	if v.MinFreeBytes == 0 {
		return nil
	}
	free, err := v.FreeBytes()
	if err != nil {
		return err
	}
	if size < 0 {
		size = 0
	}
	if free < v.MinFreeBytes+uint64(size) {
		return ErrLowDisk
	}
	return nil
}

// PutBlob streams r into the store and keeps it only if its hash is sha.
// It is safe to call concurrently for the same sha.
func (v *Vault) PutBlob(sha string, r io.Reader, declaredSize, maxSize int64) (int64, error) {
	if !manifest.ValidSHA(sha) {
		return 0, fmt.Errorf("bad sha256 %q", sha)
	}
	if err := v.ensureRoom(declaredSize); err != nil {
		return 0, err
	}
	tmp, err := os.CreateTemp(filepath.Join(v.Root, "tmp"), "blob-*")
	if err != nil {
		return 0, err
	}
	defer os.Remove(tmp.Name())
	h := sha256.New()
	n, err := io.Copy(io.MultiWriter(tmp, h), io.LimitReader(r, maxSize+1))
	if cerr := tmp.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return n, err
	}
	if n > maxSize {
		return n, ErrTooLarge
	}
	if hex.EncodeToString(h.Sum(nil)) != sha {
		return n, ErrHashMismatch
	}
	dst := v.blobPath(sha)
	if err := os.MkdirAll(filepath.Dir(dst), 0o700); err != nil {
		return n, err
	}
	if err := os.Chmod(tmp.Name(), 0o600); err != nil {
		return n, err
	}
	return n, os.Rename(tmp.Name(), dst)
}

func (v *Vault) OpenBlob(sha string) (*os.File, error) {
	if !manifest.ValidSHA(sha) {
		return nil, ErrNotFound
	}
	f, err := os.Open(v.blobPath(sha))
	if errors.Is(err, os.ErrNotExist) {
		return nil, ErrNotFound
	}
	return f, err
}

func (v *Vault) ReadBlob(sha string, limit int64) ([]byte, error) {
	f, err := v.OpenBlob(sha)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return io.ReadAll(io.LimitReader(f, limit))
}

// writeJSON writes atomically and refuses to replace an existing file when
// exclusive is set, so two commits can never claim the same version.
func (v *Vault) writeJSON(path string, val any, exclusive bool) error {
	b, err := json.MarshalIndent(val, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Join(v.Root, "tmp"), "json-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(append(b, '\n')); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if exclusive {
		// Link fails with EEXIST instead of overwriting.
		return os.Link(tmp.Name(), path)
	}
	return os.Rename(tmp.Name(), path)
}

func versions(dir string) ([]int, error) {
	entries, err := os.ReadDir(dir)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var out []int
	for _, e := range entries {
		n, err := strconv.Atoi(strings.TrimSuffix(e.Name(), ".json"))
		if err == nil && strings.HasSuffix(e.Name(), ".json") {
			out = append(out, n)
		}
	}
	sort.Ints(out)
	return out, nil
}

// SaveCallManifest stores m as the next version for its call. The caller must
// serialize commits per call (the API does so with an advisory lock).
func (v *Vault) SaveCallManifest(m *manifest.Call) (int, error) {
	dir := filepath.Join(v.Root, "manifests", "calls", m.CallID)
	vs, err := versions(dir)
	if err != nil {
		return 0, err
	}
	next := 1
	if len(vs) > 0 {
		next = vs[len(vs)-1] + 1
	}
	m.Version = next
	return next, v.writeJSON(filepath.Join(dir, strconv.Itoa(next)+".json"), m, true)
}

func (v *Vault) CallManifest(callID string, version int) (*manifest.Call, error) {
	if !manifest.ValidCallID(callID) {
		return nil, ErrNotFound
	}
	dir := filepath.Join(v.Root, "manifests", "calls", callID)
	if version <= 0 {
		vs, err := versions(dir)
		if err != nil {
			return nil, err
		}
		if len(vs) == 0 {
			return nil, ErrNotFound
		}
		version = vs[len(vs)-1]
	}
	b, err := os.ReadFile(filepath.Join(dir, strconv.Itoa(version)+".json"))
	if errors.Is(err, os.ErrNotExist) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	var m manifest.Call
	return &m, json.Unmarshal(b, &m)
}

// CallIDs lists every call that has at least one manifest.
func (v *Vault) CallIDs() ([]string, error) {
	entries, err := os.ReadDir(filepath.Join(v.Root, "manifests", "calls"))
	if err != nil {
		return nil, err
	}
	var out []string
	for _, e := range entries {
		if e.IsDir() && manifest.ValidCallID(e.Name()) {
			out = append(out, e.Name())
		}
	}
	sort.Strings(out)
	return out, nil
}

func (v *Vault) CallVersions(callID string) ([]int, error) {
	return versions(filepath.Join(v.Root, "manifests", "calls", callID))
}

func (v *Vault) SaveDeviceManifest(m *manifest.Device) (int, error) {
	dir := filepath.Join(v.Root, "manifests", "devices", m.DeviceID)
	vs, err := versions(dir)
	if err != nil {
		return 0, err
	}
	next := 1
	if len(vs) > 0 {
		next = vs[len(vs)-1] + 1
	}
	m.Version = next
	return next, v.writeJSON(filepath.Join(dir, strconv.Itoa(next)+".json"), m, true)
}

func (v *Vault) DeviceManifest(deviceID string, version int) (*manifest.Device, error) {
	dir := filepath.Join(v.Root, "manifests", "devices", deviceID)
	if version <= 0 {
		vs, err := versions(dir)
		if err != nil {
			return nil, err
		}
		if len(vs) == 0 {
			return nil, ErrNotFound
		}
		version = vs[len(vs)-1]
	}
	b, err := os.ReadFile(filepath.Join(dir, strconv.Itoa(version)+".json"))
	if errors.Is(err, os.ErrNotExist) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	var m manifest.Device
	return &m, json.Unmarshal(b, &m)
}

// DeviceRecord is what survives a Postgres loss: enough to keep every Mac
// signed in.
type DeviceRecord struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	TokenHash string `json:"token_hash"` // hex sha256 of the bearer token
	CreatedAt string `json:"created_at"`
	RevokedAt string `json:"revoked_at,omitempty"`
}

func (v *Vault) SaveDevice(d DeviceRecord) error {
	return v.writeJSON(filepath.Join(v.Root, "devices", d.ID+".json"), d, false)
}

func (v *Vault) Devices() ([]DeviceRecord, error) {
	entries, err := os.ReadDir(filepath.Join(v.Root, "devices"))
	if err != nil {
		return nil, err
	}
	var out []DeviceRecord
	for _, e := range entries {
		if !strings.HasSuffix(e.Name(), ".json") {
			continue
		}
		b, err := os.ReadFile(filepath.Join(v.Root, "devices", e.Name()))
		if err != nil {
			return nil, err
		}
		var d DeviceRecord
		if err := json.Unmarshal(b, &d); err != nil {
			return nil, fmt.Errorf("%s: %w", e.Name(), err)
		}
		out = append(out, d)
	}
	return out, nil
}

func (v *Vault) SaveBundle(b *manifest.Bundle) error {
	return v.writeJSON(filepath.Join(v.Root, "bundles", b.ID+".json"), b, true)
}

func (v *Vault) Bundle(id string) (*manifest.Bundle, error) {
	if !manifest.ValidBundleID(id) {
		return nil, ErrNotFound
	}
	b, err := os.ReadFile(filepath.Join(v.Root, "bundles", id+".json"))
	if errors.Is(err, os.ErrNotExist) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	var m manifest.Bundle
	return &m, json.Unmarshal(b, &m)
}

// uploadLock serializes chunk appends for one digest.
func (v *Vault) uploadLock(sha string) *sync.Mutex {
	v.uploadMu.Lock()
	defer v.uploadMu.Unlock()
	if v.uploads == nil {
		v.uploads = map[string]*sync.Mutex{}
	}
	m, ok := v.uploads[sha]
	if !ok {
		m = &sync.Mutex{}
		v.uploads[sha] = m
	}
	return m
}

func (v *Vault) partialPath(sha string) string {
	return filepath.Join(v.Root, "tmp", "upload-"+sha)
}

// UploadOffset reports how many bytes of a chunked upload have arrived.
func (v *Vault) UploadOffset(sha string) int64 {
	if st, err := os.Stat(v.partialPath(sha)); err == nil {
		return st.Size()
	}
	return 0
}

// AppendChunk adds one chunk of a resumable upload. Chunks must arrive in
// order: offset has to equal the bytes already received, otherwise
// ErrBadOffset is returned with the current offset so the client can resume.
// When the upload reaches total bytes it is verified and moved into place;
// done reports that.
func (v *Vault) AppendChunk(sha string, offset, total int64, r io.Reader, chunkLen, maxSize int64) (received int64, done bool, err error) {
	if !manifest.ValidSHA(sha) {
		return 0, false, fmt.Errorf("bad sha256 %q", sha)
	}
	if total <= 0 || total > maxSize {
		return 0, false, ErrTooLarge
	}
	lock := v.uploadLock(sha)
	lock.Lock()
	defer lock.Unlock()
	if v.HasBlob(sha) {
		_ = os.Remove(v.partialPath(sha))
		return total, true, nil
	}
	current := v.UploadOffset(sha)
	if offset != current {
		return current, false, ErrBadOffset
	}
	if offset == 0 {
		if err := v.ensureRoom(total); err != nil {
			return 0, false, err
		}
	}
	f, err := os.OpenFile(v.partialPath(sha), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return current, false, err
	}
	n, err := io.Copy(f, io.LimitReader(r, total-offset+1))
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	received = offset + n
	if err != nil || (chunkLen >= 0 && n != chunkLen) {
		// A torn chunk: cut back to the last good offset so a retry lines up.
		_ = os.Truncate(v.partialPath(sha), offset)
		if err == nil {
			err = io.ErrUnexpectedEOF
		}
		return offset, false, err
	}
	if received > total {
		_ = os.Remove(v.partialPath(sha))
		return 0, false, ErrTooLarge
	}
	if received < total {
		return received, false, nil
	}
	pf, err := os.Open(v.partialPath(sha))
	if err != nil {
		return received, false, err
	}
	h := sha256.New()
	_, err = io.Copy(h, pf)
	pf.Close()
	if err != nil {
		return received, false, err
	}
	if hex.EncodeToString(h.Sum(nil)) != sha {
		_ = os.Remove(v.partialPath(sha))
		return 0, false, ErrHashMismatch
	}
	dst := v.blobPath(sha)
	if err := os.MkdirAll(filepath.Dir(dst), 0o700); err != nil {
		return received, false, err
	}
	return received, true, os.Rename(v.partialPath(sha), dst)
}
