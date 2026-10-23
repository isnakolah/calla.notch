// Package inbox carries server-to-Mac messages. Kinds are a fixed allowlist
// that calla.notch knows how to apply (CallaEngine/CallaBackendInbox.swift);
// nothing sent here is ever executed as code on the Mac.
package inbox

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"calla.notch/backend/internal/manifest"
)

// Kinds and the payload fields each one requires.
var Kinds = map[string][]string{
	"notify":          {"title"},
	"replace_turns":   {"call_id", "revision", "turns"},
	"update_speakers": {"call_id", "speakers"},
	"upsert_recap":    {"call_id", "markdown"},
	"upsert_context":  {"key", "scope", "markdown"},
	"pull_bundle":     {"bundle_id", "dest"},
}

const maxPayload = 4 << 20

// Validate checks a payload before it is queued, so a malformed message never
// reaches a Mac.
func Validate(kind string, payload json.RawMessage) error {
	required, ok := Kinds[kind]
	if !ok {
		return fmt.Errorf("unknown inbox kind %q", kind)
	}
	if len(payload) > maxPayload {
		return fmt.Errorf("payload too large")
	}
	var obj map[string]json.RawMessage
	if err := json.Unmarshal(payload, &obj); err != nil {
		return fmt.Errorf("payload must be a JSON object: %w", err)
	}
	for _, f := range required {
		if _, ok := obj[f]; !ok {
			return fmt.Errorf("%s needs %q", kind, f)
		}
	}
	if raw, ok := obj["call_id"]; ok {
		var id string
		if json.Unmarshal(raw, &id) != nil || !manifest.ValidCallID(id) {
			return fmt.Errorf("bad call_id")
		}
	}
	if kind == "pull_bundle" {
		var p struct {
			BundleID string `json:"bundle_id"`
			Dest     string `json:"dest"`
		}
		_ = json.Unmarshal(payload, &p)
		if !manifest.ValidBundleID(p.BundleID) {
			return fmt.Errorf("bad bundle_id")
		}
		if p.Dest != "context" && p.Dest != "components" {
			return fmt.Errorf("dest must be context or components")
		}
	}
	return nil
}

// Broker fans Postgres notifications out to in-process subscribers: one
// channel for inbox messages (keyed by device), one for the job queue.
type Broker struct {
	mu   sync.Mutex
	subs map[string]map[chan struct{}]struct{}
	jobs chan struct{}
}

func NewBroker() *Broker {
	return &Broker{subs: map[string]map[chan struct{}]struct{}{}, jobs: make(chan struct{}, 1)}
}

func (b *Broker) Subscribe(deviceID string) (<-chan struct{}, func()) {
	ch := make(chan struct{}, 1)
	b.mu.Lock()
	if b.subs[deviceID] == nil {
		b.subs[deviceID] = map[chan struct{}]struct{}{}
	}
	b.subs[deviceID][ch] = struct{}{}
	b.mu.Unlock()
	return ch, func() {
		b.mu.Lock()
		delete(b.subs[deviceID], ch)
		if len(b.subs[deviceID]) == 0 {
			delete(b.subs, deviceID)
		}
		b.mu.Unlock()
	}
}

func (b *Broker) Jobs() <-chan struct{} { return b.jobs }

func (b *Broker) wake(deviceID string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	for ch := range b.subs[deviceID] {
		select {
		case ch <- struct{}{}:
		default:
		}
	}
}

func (b *Broker) wakeAll() {
	b.mu.Lock()
	defer b.mu.Unlock()
	for _, set := range b.subs {
		for ch := range set {
			select {
			case ch <- struct{}{}:
			default:
			}
		}
	}
}

// Listen holds one connection on LISTEN until ctx ends, reconnecting on error.
// After a reconnect every subscriber is woken, since a notification may have
// been missed; they re-read from their cursor, so this is harmless.
func (b *Broker) Listen(ctx context.Context, pool *pgxpool.Pool) {
	for ctx.Err() == nil {
		if err := b.listenOnce(ctx, pool); err != nil && ctx.Err() == nil {
			slog.Warn("inbox listener", "err", err)
			time.Sleep(2 * time.Second)
		}
		b.wakeAll()
		select {
		case b.jobs <- struct{}{}:
		default:
		}
	}
}

func (b *Broker) listenOnce(ctx context.Context, pool *pgxpool.Pool) error {
	conn, err := pool.Acquire(ctx)
	if err != nil {
		return err
	}
	defer conn.Release()
	for _, ch := range []string{"calla_inbox", "calla_jobs"} {
		if _, err := conn.Exec(ctx, "LISTEN "+ch); err != nil {
			return err
		}
	}
	for {
		n, err := conn.Conn().WaitForNotification(ctx)
		if err != nil {
			return err
		}
		switch n.Channel {
		case "calla_inbox":
			b.wake(n.Payload)
		case "calla_jobs":
			select {
			case b.jobs <- struct{}{}:
			default:
			}
		}
	}
}
