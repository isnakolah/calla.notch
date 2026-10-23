// Package auth issues and checks per-Mac device tokens.
//
// A token is shown exactly once, at enrollment, and goes straight into that
// Mac's Keychain. The server keeps only its SHA-256, in Postgres and in the
// vault, so a database dump never contains a usable credential.
package auth

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"net/http"
	"strings"
)

const tokenPrefix = "cbk_"

func NewToken() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return tokenPrefix + base64.RawURLEncoding.EncodeToString(b), nil
}

func NewDeviceID() (string, error) {
	b := make([]byte, 8)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return "dev_" + hex.EncodeToString(b), nil
}

func Hash(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

// Bearer extracts a well-formed token from the request, or "".
func Bearer(r *http.Request) string {
	h := r.Header.Get("Authorization")
	tok, ok := strings.CutPrefix(h, "Bearer ")
	if !ok || !strings.HasPrefix(tok, tokenPrefix) || len(tok) > 128 {
		return ""
	}
	return tok
}

type Device struct {
	ID   string
	Name string
}

type ctxKey struct{}

func WithDevice(ctx context.Context, d Device) context.Context {
	return context.WithValue(ctx, ctxKey{}, d)
}

func DeviceFrom(ctx context.Context) (Device, bool) {
	d, ok := ctx.Value(ctxKey{}).(Device)
	return d, ok
}
