package index

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"calla.notch/backend/internal/db"
	"calla.notch/backend/internal/vault"
)

// Worker drains the jobs table. Several workers (or several server
// processes) can run at once; SKIP LOCKED keeps them apart.
type Worker struct {
	DB       *db.DB
	Vault    *vault.Vault
	Embedder Embedder
	Wake     <-chan struct{}
}

func (w *Worker) Run(ctx context.Context) {
	tick := time.NewTicker(30 * time.Second)
	defer tick.Stop()
	for ctx.Err() == nil {
		ran, err := w.RunOne(ctx)
		if err != nil {
			slog.Warn("job loop", "err", err)
		}
		if ran {
			continue
		}
		select {
		case <-ctx.Done():
		case <-w.Wake:
		case <-tick.C:
		}
	}
}

// RunOne claims and runs one job. It reports whether a job was found.
func (w *Worker) RunOne(ctx context.Context) (bool, error) {
	job, err := w.DB.ClaimJob(ctx)
	if err != nil || job == nil {
		return false, err
	}
	start := time.Now()
	err = w.run(ctx, job)
	if err != nil {
		slog.Warn("job failed", "id", job.ID, "kind", job.Kind, "call", job.CallID, "attempt", job.Attempts, "err", err)
		return true, w.DB.FailJob(ctx, job.ID, job.Attempts, err)
	}
	slog.Info("job done", "id", job.ID, "kind", job.Kind, "call", job.CallID, "version", job.Version, "took", time.Since(start).Round(time.Millisecond))
	return true, w.DB.FinishJob(ctx, job.ID)
}

func (w *Worker) run(ctx context.Context, job *db.Job) error {
	switch job.Kind {
	case "index":
		return IndexCall(ctx, w.DB, w.Vault, w.Embedder, job.CallID, job.Version)
	default:
		return fmt.Errorf("unknown job kind %q", job.Kind)
	}
}

// IndexCall rebuilds one call's derived rows from a manifest version
// (0 = newest).
func IndexCall(ctx context.Context, d *db.DB, v *vault.Vault, e Embedder, callID string, version int) error {
	m, err := v.CallManifest(callID, version)
	if err != nil {
		return err
	}
	ix, err := Build(ctx, v, m, e)
	if err != nil {
		return err
	}
	return d.ReplaceCallIndex(ctx, callID, m.Version, ix)
}
