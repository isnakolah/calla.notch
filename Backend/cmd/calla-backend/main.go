// Command calla-backend is the call archive behind calla.notch: the HTTP
// server, its job worker, and the operator commands that run beside it.
//
// Configuration comes from the environment:
//
//	CALLA_DATABASE_URL  postgres connection string (required)
//	CALLA_DATA_DIR      vault root (default /data)
//	CALLA_LISTEN        listen address (default 127.0.0.1:18795)
//	CALLA_PUBLIC_URL    URL the Macs use (default https://calla-api.nomonlab.com)
//	CALLA_ENROLL_SECRET lets a Mac enroll itself over POST /v1/enroll with
//	                    this secret, baked into its private package (optional)
//	CALLA_EMBED_URL     text-embeddings-inference base URL (optional)
//	CALLA_MAX_BLOB      largest single upload in bytes (default 8 GiB)
//	CALLA_MIN_FREE      refuse uploads below this much free disk (default 5 GiB)
//	CALLA_VAULT_REQUIRE_MARKER=1  refuse to run unless the vault carries its
//	                    marker file (set in compose: the vault is on the NAS)
package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"log/slog"
	"mime"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"syscall"
	"text/tabwriter"
	"time"

	"calla.notch/backend/internal/api"
	"calla.notch/backend/internal/db"
	"calla.notch/backend/internal/inbox"
	"calla.notch/backend/internal/index"
	"calla.notch/backend/internal/manifest"
	"calla.notch/backend/internal/vault"
)

const usage = `usage: calla-backend <command> [flags]

  serve                         run the API and the index worker
  migrate                       apply database migrations
  enroll --device NAME [--id DEVICE_ID] [--reuse] [--json]
                                issue a device token (--id, or --reuse with an active
                                device of that name: rotate its token, keep its identity)
  revoke DEVICE                 revoke a device by id or name
  devices                       list enrolled devices
  push KIND --device DEVICE (--payload JSON|@FILE | --title T [--body B])
                                queue an inbox message for a Mac
  inbox [--device DEVICE]       show recent inbox messages and their acks
  bundle --id ID --dir DIR [--device DEVICE] [--description TEXT] [--push context|components]
                                store a directory as a bundle a Mac can pull
  reindex [--call CALL_ID] [--wait]
                                rebuild Postgres from the vault
  status                        counts, queue depth and free disk
  init-vault                    mark a brand-new, empty vault directory as the vault
`

func main() {
	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo})))
	if len(os.Args) < 2 {
		fmt.Fprint(os.Stderr, usage)
		os.Exit(2)
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	cmd, args := os.Args[1], os.Args[2:]
	var err error
	switch cmd {
	case "serve":
		err = serve(ctx)
	case "migrate":
		err = withEnv(ctx, func(e *env) error { return nil })
	case "enroll":
		err = enroll(ctx, args)
	case "revoke":
		err = revoke(ctx, args)
	case "devices":
		err = devices(ctx)
	case "push":
		err = push(ctx, args)
	case "inbox":
		err = showInbox(ctx, args)
	case "bundle":
		err = bundle(ctx, args)
	case "reindex":
		err = reindex(ctx, args)
	case "status":
		err = status(ctx)
	case "init-vault":
		err = vault.Init(getenv("CALLA_DATA_DIR", "/data"))
	case "-h", "--help", "help":
		fmt.Print(usage)
	default:
		fmt.Fprint(os.Stderr, usage)
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

type env struct {
	DB    *db.DB
	Vault *vault.Vault
}

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func publicURL() string { return getenv("CALLA_PUBLIC_URL", "https://calla-api.nomonlab.com") }

func getbytes(k string, def int64) int64 {
	if v, err := strconv.ParseInt(os.Getenv(k), 10, 64); err == nil && v >= 0 {
		return v
	}
	return def
}

// withEnv opens the vault and database and runs migrations, so every command
// works against a fresh install.
func withEnv(ctx context.Context, fn func(*env) error) error {
	url := os.Getenv("CALLA_DATABASE_URL")
	if url == "" {
		return errors.New("CALLA_DATABASE_URL is not set")
	}
	root := getenv("CALLA_DATA_DIR", "/data")
	if os.Getenv("CALLA_VAULT_REQUIRE_MARKER") == "1" {
		if err := vault.CheckMarker(root); err != nil {
			return err
		}
	}
	v, err := vault.Open(root, uint64(getbytes("CALLA_MIN_FREE", 5<<30)))
	if err != nil {
		return err
	}
	d, err := db.Open(ctx, url)
	if err != nil {
		return err
	}
	defer d.Close()
	if err := d.Migrate(ctx); err != nil {
		return err
	}
	// Devices live in the vault too; make sure Postgres agrees before anything
	// authenticates against it.
	if err := api.SyncDevices(ctx, d, v); err != nil {
		return err
	}
	return fn(&env{DB: d, Vault: v})
}

func embedder() index.Embedder {
	if u := os.Getenv("CALLA_EMBED_URL"); u != "" {
		return index.NewTEI(u)
	}
	return nil
}

func serve(ctx context.Context) error {
	return withEnv(ctx, func(e *env) error {
		broker := inbox.NewBroker()
		go broker.Listen(ctx, e.DB.Pool)
		emb := embedder()
		worker := &index.Worker{DB: e.DB, Vault: e.Vault, Embedder: emb, Wake: broker.Jobs()}
		go worker.Run(ctx)

		srv := &http.Server{
			Addr: getenv("CALLA_LISTEN", "127.0.0.1:18795"),
			Handler: (&api.Server{
				DB: e.DB, Vault: e.Vault, Embedder: emb, Broker: broker,
				MaxBlob: getbytes("CALLA_MAX_BLOB", 8<<30), Heartbeat: 25 * time.Second,
				EnrollSecret: os.Getenv("CALLA_ENROLL_SECRET"), PublicURL: publicURL(),
			}).Handler(),
			ReadHeaderTimeout: 15 * time.Second,
			IdleTimeout:       120 * time.Second,
		}
		go func() {
			<-ctx.Done()
			shut, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			_ = srv.Shutdown(shut)
		}()
		slog.Info("calla-backend listening", "addr", srv.Addr, "data", e.Vault.Root, "embeddings", emb != nil)
		if err := srv.ListenAndServe(); !errors.Is(err, http.ErrServerClosed) {
			return err
		}
		return nil
	})
}

func enroll(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("enroll", flag.ExitOnError)
	name := fs.String("device", "", "device name, e.g. the Mac's computer name")
	id := fs.String("id", "", "existing device id whose token to rotate")
	reuse := fs.Bool("reuse", false, "rotate the token of an active device with this name instead of adding another")
	asJSON := fs.Bool("json", false, "print JSON")
	_ = fs.Parse(args)
	if *name == "" && *id == "" {
		return errors.New("enroll needs --device NAME or --id DEVICE_ID")
	}
	return withEnv(ctx, func(e *env) error {
		rec, tok, err := api.Enroll(ctx, e.DB, e.Vault, *name, *id, *reuse)
		if err != nil {
			return err
		}
		out := map[string]string{
			"device_id": rec.ID, "name": rec.Name, "token": tok,
			"url": publicURL(),
		}
		if *asJSON {
			return json.NewEncoder(os.Stdout).Encode(out)
		}
		fmt.Printf("device  %s (%s)\nurl     %s\ntoken   %s\n\nThe token is shown once. Store it in the Mac's Keychain.\n", rec.ID, rec.Name, out["url"], tok)
		return nil
	})
}

func revoke(ctx context.Context, args []string) error {
	if len(args) != 1 {
		return errors.New("revoke needs exactly one device id or name")
	}
	return withEnv(ctx, func(e *env) error {
		dev, err := e.DB.DeviceByName(ctx, args[0])
		if err != nil {
			return fmt.Errorf("device %s: %w", args[0], err)
		}
		recs, err := e.Vault.Devices()
		if err != nil {
			return err
		}
		for _, r := range recs {
			if r.ID == dev.ID {
				r.RevokedAt = time.Now().UTC().Format(time.RFC3339)
				if err := e.Vault.SaveDevice(r); err != nil {
					return err
				}
			}
		}
		if err := api.SyncDevices(ctx, e.DB, e.Vault); err != nil {
			return err
		}
		fmt.Printf("revoked %s (%s)\n", dev.ID, dev.Name)
		return nil
	})
}

func devices(ctx context.Context) error {
	return withEnv(ctx, func(e *env) error {
		list, err := e.DB.Devices(ctx)
		if err != nil {
			return err
		}
		tw := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
		fmt.Fprintln(tw, "ID\tNAME\tCREATED\tLAST SEEN\tSTATE")
		for _, d := range list {
			seen, state := "never", "active"
			if d.LastSeen != nil {
				seen = d.LastSeen.Local().Format("2006-01-02 15:04")
			}
			if d.RevokedAt != nil {
				state = "revoked"
			}
			fmt.Fprintf(tw, "%s\t%s\t%s\t%s\t%s\n", d.ID, d.Name, d.CreatedAt.Local().Format("2006-01-02"), seen, state)
		}
		return tw.Flush()
	})
}

func push(ctx context.Context, args []string) error {
	if len(args) < 1 {
		return errors.New("push needs a kind: " + kindList())
	}
	kind := args[0]
	fs := flag.NewFlagSet("push", flag.ExitOnError)
	dev := fs.String("device", "", "device id or name")
	payload := fs.String("payload", "", "JSON payload, or @file")
	title := fs.String("title", "", "notify: title")
	body := fs.String("body", "", "notify: body")
	_ = fs.Parse(args[1:])
	if *dev == "" {
		return errors.New("push needs --device")
	}
	raw := []byte(*payload)
	if len(raw) > 0 && raw[0] == '@' {
		b, err := os.ReadFile(string(raw[1:]))
		if err != nil {
			return err
		}
		raw = b
	}
	if len(raw) == 0 && kind == "notify" {
		raw, _ = json.Marshal(map[string]string{"title": *title, "body": *body})
	}
	if err := inbox.Validate(kind, raw); err != nil {
		return err
	}
	return withEnv(ctx, func(e *env) error {
		d, err := e.DB.DeviceByName(ctx, *dev)
		if err != nil {
			return fmt.Errorf("device %s: %w", *dev, err)
		}
		id, err := e.DB.Push(ctx, d.ID, kind, raw)
		if err != nil {
			return err
		}
		fmt.Printf("queued #%d %s for %s (%s)\n", id, kind, d.ID, d.Name)
		return nil
	})
}

func kindList() string {
	out := ""
	for k := range inbox.Kinds {
		out += k + " "
	}
	return out
}

func showInbox(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("inbox", flag.ExitOnError)
	dev := fs.String("device", "", "device id or name")
	_ = fs.Parse(args)
	return withEnv(ctx, func(e *env) error {
		id := ""
		if *dev != "" {
			d, err := e.DB.DeviceByName(ctx, *dev)
			if err != nil {
				return err
			}
			id = d.ID
		}
		msgs, err := e.DB.Messages(ctx, id, 50)
		if err != nil {
			return err
		}
		tw := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
		fmt.Fprintln(tw, "ID\tDEVICE\tKIND\tCREATED\tDELIVERED\tRESULT")
		for _, m := range msgs {
			delivered, result := "-", "-"
			if m.DeliveredAt != nil {
				delivered = m.DeliveredAt.Local().Format("01-02 15:04:05")
			}
			if len(m.Result) > 0 {
				result = string(m.Result)
			}
			fmt.Fprintf(tw, "%d\t%s\t%s\t%s\t%s\t%s\n", m.ID, m.DeviceID, m.Kind, m.CreatedAt.Local().Format("01-02 15:04:05"), delivered, result)
		}
		return tw.Flush()
	})
}

func bundle(ctx context.Context, args []string) error {
	fset := flag.NewFlagSet("bundle", flag.ExitOnError)
	id := fset.String("id", "", "bundle id (lowercase, dashes)")
	dir := fset.String("dir", "", "directory to package")
	dev := fset.String("device", "", "restrict to one device (default: any)")
	desc := fset.String("description", "", "what the bundle is for")
	pushTo := fset.String("push", "", "also queue pull_bundle with this dest (context|components)")
	_ = fset.Parse(args)
	if !manifest.ValidBundleID(*id) || *dir == "" {
		return errors.New("bundle needs --id (lowercase letters, digits, dashes) and --dir")
	}
	return withEnv(ctx, func(e *env) error {
		b := &manifest.Bundle{Format: manifest.Format, ID: *id, Description: *desc}
		if *dev != "" {
			d, err := e.DB.DeviceByName(ctx, *dev)
			if err != nil {
				return err
			}
			b.DeviceID = d.ID
		}
		err := filepath.WalkDir(*dir, func(p string, de fs.DirEntry, err error) error {
			if err != nil || de.IsDir() {
				return err
			}
			if !de.Type().IsRegular() {
				return nil
			}
			rel, _ := filepath.Rel(*dir, p)
			rel = filepath.ToSlash(rel)
			if _, err := manifest.CleanPath(rel); err != nil {
				return err
			}
			sha, size, err := putFile(e.Vault, p)
			if err != nil {
				return fmt.Errorf("%s: %w", rel, err)
			}
			b.Files = append(b.Files, manifest.File{Path: rel, SHA256: sha, Size: size, Type: mime.TypeByExtension(filepath.Ext(p))})
			return nil
		})
		if err != nil {
			return err
		}
		if len(b.Files) == 0 {
			return errors.New("directory has no files")
		}
		now := time.Now().UTC()
		b.CreatedAt = &now
		if err := e.Vault.SaveBundle(b); err != nil {
			return fmt.Errorf("save bundle (ids are immutable; pick a new one): %w", err)
		}
		fmt.Printf("bundle %s: %d files\n", b.ID, len(b.Files))
		if *pushTo != "" {
			if b.DeviceID == "" {
				return errors.New("--push needs --device")
			}
			raw, _ := json.Marshal(map[string]string{"bundle_id": b.ID, "dest": *pushTo})
			if err := inbox.Validate("pull_bundle", raw); err != nil {
				return err
			}
			mid, err := e.DB.Push(ctx, b.DeviceID, "pull_bundle", raw)
			if err != nil {
				return err
			}
			fmt.Printf("queued #%d pull_bundle\n", mid)
		}
		return nil
	})
}

func putFile(v *vault.Vault, p string) (string, int64, error) {
	f, err := os.Open(p)
	if err != nil {
		return "", 0, err
	}
	h := sha256.New()
	size, err := io.Copy(h, f)
	f.Close()
	if err != nil {
		return "", 0, err
	}
	sha := hex.EncodeToString(h.Sum(nil))
	if v.HasBlob(sha) {
		return sha, size, nil
	}
	f, err = os.Open(p)
	if err != nil {
		return "", 0, err
	}
	defer f.Close()
	_, err = v.PutBlob(sha, f, size, size)
	return sha, size, err
}

// reindex rebuilds every derived table from the vault: devices, call and
// manifest history, device snapshots, then queues an index job per call.
func reindex(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("reindex", flag.ExitOnError)
	only := fs.String("call", "", "reindex one call only")
	wait := fs.Bool("wait", false, "run the index jobs here and wait for them")
	_ = fs.Parse(args)
	return withEnv(ctx, func(e *env) error {
		ids := []string{*only}
		if *only == "" {
			if err := e.DB.ResetIndex(ctx); err != nil {
				return err
			}
			if err := api.SyncDevices(ctx, e.DB, e.Vault); err != nil {
				return err
			}
			var err error
			if ids, err = e.Vault.CallIDs(); err != nil {
				return err
			}
			if err := reindexDeviceSnapshots(ctx, e); err != nil {
				return err
			}
		}
		for _, id := range ids {
			versions, err := e.Vault.CallVersions(id)
			if err != nil {
				return err
			}
			if len(versions) == 0 {
				return fmt.Errorf("%s: no manifests in the vault", id)
			}
			for _, v := range versions {
				m, err := e.Vault.CallManifest(id, v)
				if err != nil {
					return fmt.Errorf("%s v%d: %w", id, v, err)
				}
				if err := recordVersion(ctx, e, m, v == versions[len(versions)-1]); err != nil {
					return fmt.Errorf("%s v%d: %w", id, v, err)
				}
			}
		}
		fmt.Printf("queued %d calls for indexing\n", len(ids))
		if !*wait {
			return nil
		}
		w := &index.Worker{DB: e.DB, Vault: e.Vault, Embedder: embedder()}
		for n := 0; ; n++ {
			ran, err := w.RunOne(ctx)
			if err != nil {
				return err
			}
			if !ran {
				fmt.Printf("ran %d jobs\n", n)
				return nil
			}
		}
	})
}

func recordVersion(ctx context.Context, e *env, m *manifest.Call, latest bool) error {
	tx, err := e.DB.Pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if err := db.LockCall(ctx, tx, m.CallID); err != nil {
		return err
	}
	if err := db.RecordCallVersion(ctx, tx, m, m.ContentSHA()); err != nil {
		return err
	}
	for _, f := range m.Files {
		if _, err := tx.Exec(ctx, `INSERT INTO blobs(sha256, size) VALUES ($1,$2) ON CONFLICT DO NOTHING`, f.SHA256, f.Size); err != nil {
			return err
		}
	}
	if latest {
		if err := db.EnqueueTx(ctx, tx, "index", m.CallID, m.Version); err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
}

func reindexDeviceSnapshots(ctx context.Context, e *env) error {
	root := filepath.Join(e.Vault.Root, "manifests", "devices")
	entries, err := os.ReadDir(root)
	if err != nil {
		return err
	}
	for _, d := range entries {
		for v := 1; ; v++ {
			m, err := e.Vault.DeviceManifest(d.Name(), v)
			if errors.Is(err, vault.ErrNotFound) {
				break
			}
			if err != nil {
				return err
			}
			if err := e.DB.RecordDeviceSnapshot(ctx, m, m.ContentSHA()); err != nil {
				return err
			}
		}
	}
	return nil
}

func status(ctx context.Context) error {
	return withEnv(ctx, func(e *env) error {
		var calls, indexed, turns, chunks, embedded, pending, failing int
		var blobs, bytes int64
		q := e.DB.Pool.QueryRow(ctx, `SELECT
			(SELECT count(*) FROM calls), (SELECT count(*) FROM calls WHERE indexed_version = current_version),
			(SELECT count(*) FROM turns), (SELECT count(*) FROM chunks), (SELECT count(*) FROM chunks WHERE embedding IS NOT NULL),
			(SELECT count(*) FROM jobs WHERE done_at IS NULL), (SELECT count(*) FROM jobs WHERE done_at IS NULL AND last_error IS NOT NULL),
			(SELECT count(*) FROM blobs), (SELECT COALESCE(sum(size),0) FROM blobs)`)
		if err := q.Scan(&calls, &indexed, &turns, &chunks, &embedded, &pending, &failing, &blobs, &bytes); err != nil {
			return err
		}
		free, _ := e.Vault.FreeBytes()
		fmt.Printf("calls     %d (%d indexed)\nturns     %d\nchunks    %d (%d embedded)\njobs      %d pending, %d retrying\nblobs     %d, %.2f GB\nfree disk %.2f GB\n",
			calls, indexed, turns, chunks, embedded, pending, failing, blobs, float64(bytes)/1e9, float64(free)/1e9)
		if failing > 0 {
			var last string
			_ = e.DB.Pool.QueryRow(ctx, `SELECT call_id || ': ' || last_error FROM jobs WHERE done_at IS NULL AND last_error IS NOT NULL ORDER BY id DESC LIMIT 1`).Scan(&last)
			fmt.Printf("last error %s\n", last)
		}
		return nil
	})
}
