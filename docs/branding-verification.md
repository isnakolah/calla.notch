# calla.notch rename verification

The goal was to rename the entire current app, its source structure, owned
repository and checkout folders, preserve existing data, and make artwork easy
to replace from one location.

## Delivered

- Checkout: `/Users/isnakolah/dev/calla.notch`.
- Linked checkout: `/Users/isnakolah/dev/calla.notch-calla-migration`; pending
  work and its historical branch contents are preserved.
- Repository and origin: [isnakolah/calla.notch](https://github.com/isnakolah/calla.notch).
- Installed app: `/Applications/calla.notch.app`, identity `org.calla.notch`.
- Private installer: `build/private/calla.notch-private-arm64-2.7.3-292.dmg`.
- Artwork: [inventory and replacement guide](../Branding/README.md), sixteen
  inventoried files including archived originals and the remote README logo.

Source changes are staged locally. No source commit, push or public release was
created. Git history, source attribution and original data remain intact.

## Passed checks

- Branding scan across current tracked and nonignored source: no unaccounted
  legacy references; exact compatibility and provenance exceptions are hashed.
- All app-icon dimensions, asset hashes, catalog references, JSON, plists, shared
  scheme, shell syntax and GitHub workflow YAML checks.
- Root Engine, Contracts, Distribution, Intelligence and Call host package suites,
  plus Tutor's full `make test` through its project environment. Existing
  environment-dependent skips remain skips.
- Fourteen migration tests, including retained-history decryption, absent keys,
  conflicting destinations, interrupted runs, sandbox staging, bookmark bytes,
  symlinks and keeping preference snapshots out of the global receipt.
- Release build with signed capture runtime; Debug compile validation. The final
  Debug pass used `CALLA_COMPILE_ONLY=1`; the Release package carries the runtime.
- Private package and installed-bundle checks: nested signatures, required files,
  forty-nine arm64 Mach-O files, macOS 15 minimum compatibility and portable
  runtime linkage.
- Xcode's required Metal toolchain was restored after the active installation
  reported it missing. Final builds passed with Xcode 27.1.

Package checksum and machine-readable evidence are alongside the DMG, including
`verification-292.json`. Build 292 passed a fresh Release build, the fourteen
migration tests, the branding audit and packaged/installed bundle checks. Its
Engine joins the caller's security session, as required for login Keychain
access; the package verifier now enforces this setting. Signing requirements for
the app and both XPC services match the preceding installed build.

## Runtime boundary

On 2026-10-16, the user granted Full Disk Access after macOS blocked the previous
sandbox's preferences. Retrying exposed a separate Keychain session configuration
issue, corrected in build 292. The installed app then completed migration and
opened normally. The success receipt records version 1 and imported legacy data,
with mode 0600. Both local history keys match their originals byte-for-byte;
all 7,103 retained encrypted history files match the originals and decrypted
successfully in memory. No plaintext or key material was exported.

Native UI checks confirmed the running notch and General, Privacy & Permissions,
Notch, Calls and About settings. The settings window, repository link and About
product name display calla.notch. This is not a complete interactive walkthrough
of every feature. Microphone, screen capture, security-scoped folders and login
registration may still need approval for the new identity. No recording, live AI
session or Gateway deployment was performed. Original data, credentials and the
previous app remain available for rollback.

See [migration and recovery](branding-migration.md) for the startup behavior and
rollback procedure. A separate fresh-Mac installation test remains outstanding.
