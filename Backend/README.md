# calla-backend

The call archive behind calla.notch. Each Mac does the listening, transcribing,
re-transcribing and speaker labelling. When a call is finished, the Mac sends all
of it here: the audio as lossless FLAC, the live and re-transcribed transcripts,
speakers and voiceprints, screenshots and their OCR text, notes, the recap,
events, suggestions, and every store row the call owns. This server keeps it
all, indexes it for search, and can send changes back to the Macs.

- **Public URL:** `https://calla-api.nomonlab.com`. It is published with cf-dns on the
  `calla-control` tunnel. The name has one label only: Cloudflare's free certificate
  covers `*.nomonlab.com` but not `*.calla.nomonlab.com`.
- **Runs on:** nomonhomelab, in `/srv/app/calla-backend`, as docker compose:
  - `backend` on `127.0.0.1:18795`
  - `db`, a pgvector Postgres
  - `embed`, `bge-small-en-v1.5` on CPU
- **Mac side:** `CallaEngine/CallaBackend*.swift` and
  `Intelligence/Sources/IntelligenceStore/StoreBackup.swift`.

## What is the source of truth

The vault is on the NAS at `/mnt/nas/data/calla`
(`192.168.100.34:/volume1/data`, NFS 4.1 hard mount, about 2.8 TB free). Docker
mounts it as `/data`. Postgres stays in its Docker volume, which is on the
NAS's iSCSI disk; Postgres never goes on NFS.

```
/mnt/nas/data/calla/                  <- back this up (NAS snapshots)
  .calla-vault                         marker: the backend will not start without it
  blobs/sha256/ab/cd/<sha>             every file, content-addressed
  manifests/calls/<call_id>/<n>.json   every committed version of every call
  manifests/devices/<id>/<n>.json      device snapshots (voiceprints, knowledge, settings)
  devices/<id>.json                    enrolled Macs (token hashes only)
  bundles/<id>.json                    containers made for Macs to pull
```

If the NAS is not mounted, the backend refuses to start instead of writing to
the local disk: the marker would be missing. `calla-backend init-vault` is only
for a brand-new, empty vault.

Postgres holds nothing that cannot be rebuilt from this directory. The only
exception is the inbox, which is transient. If the database is lost:
`calla-backend reindex --wait`.

## How a Mac signs in

Macs enroll over the public URL; Tailscale is not involved.
1. `deploy.sh` generates `CALLA_ENROLL_SECRET` in the server's `.env` and copies it
   to `~/.config/calla/enroll-secret` on the deploying Mac.
2. `scripts/package-private.sh` bakes that secret and the URL into each private DMG,
   as `Contents/Resources/PrivateSetup/archive-enrollment.json`. A development build
   reads the same JSON from `.../Calla/backend/enrollment.json` instead.
3. On first start the engine calls `POST /v1/enroll` with the secret and gets its own
   device token back. It keeps the token in
   `~/Library/Application Support/calla.notch/Calla/backend/credential.json` (0600).
4. That file survives reinstalling the app. If it is lost, enrollment by the same
   Mac name gives the Mac back its existing device identity.

The Keychain is deliberately not used. Each local build re-signs the engine, and a
Keychain item then blocks on an access prompt.

Anyone holding a private DMG can enroll a device, so keep the DMGs private. To
rotate: change `CALLA_ENROLL_SECRET`, restart, and rebuild the DMG. Existing device
tokens keep working. `calla-backend enroll` on the server still issues tokens by
hand, and `calla-backend revoke` removes a device.

## Restoring a Mac

- **Automatic:** a Mac whose store has no calls restores itself on first start.
- **Manual:** Settings › Copilot › After a call › Call archive › Restore. This
  never overwrites: existing files are kept, and store rows are inserted with
  `INSERT OR IGNORE`.

What a restore does:
- Downloads every call's raw files, decoding FLAC back to WAV.
- Imports the store rows.
- Restores knowledge and voiceprints from the device snapshot.
- Regenerates the call folders in `~/Documents/Calls`.
- Saves the app's preferences to `Calla/backend/restored/` without applying them.

## Operating it

`calla-backend` (symlinked into `~/.local/bin`) runs commands inside the container:

```sh
calla-backend status                     # counts, queue, free disk
calla-backend devices                    # enrolled Macs, last seen
calla-backend revoke <device id|name>
calla-backend enroll --device NAME       # by hand, prints a token once
calla-backend reindex [--call ID] [--wait]

# Talk back to a Mac (a fixed allowlist; nothing runs as code on the Mac)
calla-backend push notify          --device <d> --title T [--body B]
calla-backend push replace_turns   --device <d> --payload '{"call_id":"…","revision":1,"turns":[…]}'
calla-backend push update_speakers --device <d> --payload '{"call_id":"…","speakers":[{"speaker_id":"S1","name":"Ann"},{"speaker_id":"S2","merge_into":"S1"}]}'
calla-backend push upsert_recap    --device <d> --payload '{"call_id":"…","markdown":"…"}'
calla-backend push upsert_context  --device <d> --payload '{"key":"k","scope":"always|persona:<p>|series:<id>|event:<id>","markdown":"…"}'
calla-backend bundle --id my-pack --dir ./pack --device <d> --push context
calla-backend inbox [--device <d>]       # what was sent, and each Mac's ack
```

When the Mac changes rows because of a push, it re-sends the call. The archive
therefore always matches the Mac.

## Deploying

From the repo, on the Mac:

```sh
Backend/deploy/deploy.sh            # rsync, build, restart, health check
Backend/deploy/deploy.sh --expose   # first time: also publish with cf-dns
```

Secrets live in `/srv/app/calla-backend/deploy/.env`. The deploy script creates
that file from `.env.example`, with a random Postgres password.

## Tests

```sh
cd Backend && go test ./...          # unit tests; API tests skip without a database
# full suite, on the server:
docker run -d --rm --name t -p 127.0.0.1:55432:5432 -e POSTGRES_PASSWORD=t pgvector/pgvector:pg17
CALLA_TEST_DATABASE_URL=postgres://postgres:t@127.0.0.1:55432/postgres go test ./...
```

## API

Every route except `/healthz` needs `Authorization: Bearer <device token>`.

| Route | |
|---|---|
| `POST /v1/blobs/check` | `{"sha256":[…]}` → `{"missing":[…]}` |
| `PUT /v1/blobs/{sha}` | whole blob, hash-verified |
| `PUT /v1/blobs/{sha}?offset=N&total=T` | resumable chunk; 409 returns the server's offset |
| `GET /v1/blobs/{sha}` | download with Range support; `?offset` reports upload progress |
| `POST /v1/calls/{id}/commit` | call manifest; idempotent, versioned |
| `GET /v1/calls[?all=1]`, `/v1/calls/{id}`, `/v1/calls/{id}/manifest`, `/v1/calls/{id}/turns?revision=` | read back |
| `GET /v1/search?q=` | full text plus vectors, fused by reciprocal rank |
| `POST /v1/device/snapshot` | device-wide manifest |
| `GET /v1/restore[?from=dev][&device=dev]` | everything a fresh install needs |
| `GET /v1/inbox/stream` | SSE, heartbeat every 25 s; `GET /v1/inbox?after=` to poll |
| `POST /v1/inbox/{id}/ack` | `{"ok":bool,"error":"…"}` |
| `GET /v1/bundles/{id}` | bundle manifest |
