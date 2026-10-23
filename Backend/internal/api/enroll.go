package api

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"errors"
	"fmt"
	"net/http"
	"regexp"
	"strings"
	"time"

	"calla.notch/backend/internal/auth"
	"calla.notch/backend/internal/db"
	"calla.notch/backend/internal/vault"
)

var deviceIDPattern = regexp.MustCompile(`^dev_[0-9a-f]{16}$`)

// SyncDevices makes Postgres agree with the device records in the vault.
func SyncDevices(ctx context.Context, d *db.DB, v *vault.Vault) error {
	recs, err := v.Devices()
	if err != nil {
		return err
	}
	for _, r := range recs {
		created, _ := time.Parse(time.RFC3339, r.CreatedAt)
		dev := db.Device{ID: r.ID, Name: r.Name, TokenHash: r.TokenHash, CreatedAt: created}
		if t, err := time.Parse(time.RFC3339, r.RevokedAt); err == nil {
			dev.RevokedAt = &t
		}
		if err := d.UpsertDevice(ctx, dev); err != nil {
			return err
		}
	}
	return nil
}

// Enroll issues a device token. With id, or with reuse and an active device of
// that name, it rotates that device's token and keeps its identity.
func Enroll(ctx context.Context, d *db.DB, v *vault.Vault, name, id string, reuse bool) (vault.DeviceRecord, string, error) {
	tok, err := auth.NewToken()
	if err != nil {
		return vault.DeviceRecord{}, "", err
	}
	rec := vault.DeviceRecord{Name: name, CreatedAt: time.Now().UTC().Format(time.RFC3339)}
	if id == "" && reuse {
		if existing, err := d.DeviceByName(ctx, name); err == nil && existing.RevokedAt == nil {
			id = existing.ID
		}
	}
	if id != "" {
		existing, err := d.DeviceByName(ctx, id)
		if err != nil {
			return vault.DeviceRecord{}, "", fmt.Errorf("device %s: %w", id, err)
		}
		rec.ID, rec.CreatedAt = existing.ID, existing.CreatedAt.UTC().Format(time.RFC3339)
		if rec.Name == "" {
			rec.Name = existing.Name
		}
	} else if rec.ID, err = auth.NewDeviceID(); err != nil {
		return vault.DeviceRecord{}, "", err
	}
	rec.TokenHash = auth.Hash(tok)
	// Vault first: a token Postgres knows about but the vault does not
	// would stop working after a rebuild.
	if err := v.SaveDevice(rec); err != nil {
		return vault.DeviceRecord{}, "", err
	}
	if err := SyncDevices(ctx, d, v); err != nil {
		return vault.DeviceRecord{}, "", err
	}
	return rec, tok, nil
}

// enroll lets a Mac sign itself in over the public URL with the enrollment
// secret baked into its private package. Without a configured secret the
// route does not exist.
func (s *Server) enroll(w http.ResponseWriter, r *http.Request) {
	if s.EnrollSecret == "" {
		http.NotFound(w, r)
		return
	}
	given, _ := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	want, got := sha256.Sum256([]byte(s.EnrollSecret)), sha256.Sum256([]byte(given))
	if subtle.ConstantTimeCompare(want[:], got[:]) != 1 {
		fail(w, http.StatusUnauthorized, "wrong enrollment secret")
		return
	}
	var req struct {
		Name     string `json:"name"`
		DeviceID string `json:"device_id"`
	}
	if !readJSON(w, r, &req, 4<<10) {
		return
	}
	req.Name = strings.TrimSpace(req.Name)
	if req.DeviceID != "" && !deviceIDPattern.MatchString(req.DeviceID) {
		fail(w, http.StatusBadRequest, "bad device_id")
		return
	}
	if req.DeviceID == "" && (req.Name == "" || len(req.Name) > 128) {
		fail(w, http.StatusBadRequest, "name is required")
		return
	}
	rec, tok, err := Enroll(r.Context(), s.DB, s.Vault, req.Name, req.DeviceID, true)
	if errors.Is(err, db.ErrNotFound) {
		// A device id the server no longer knows: enroll fresh by name.
		if req.Name == "" {
			fail(w, http.StatusNotFound, "unknown device")
			return
		}
		rec, tok, err = Enroll(r.Context(), s.DB, s.Vault, req.Name, "", true)
	}
	if err != nil {
		internal(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{
		"device_id": rec.ID, "name": rec.Name, "token": tok, "url": s.PublicURL,
	})
}
