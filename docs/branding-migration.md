# Moving to calla.notch

The product is `calla.notch`, the bundle identity is `org.calla.notch`, the
executable and Xcode scheme are `callaNotch`, and the setup command is
`calla-notch`. The installed app is `/Applications/calla.notch.app`.

## First launch

Finish any active work and quit the previous app. On the first installed launch,
the unsandboxed Engine migrates app-managed data before SwiftUI constructs
settings consumers or starts runtime services. The installer copy on a DMG does
not perform migration.

When deployment runs before the new sandbox exists, sandbox files are staged
until macOS creates the container on first launch. The migration never creates
a managed container itself.

Global data goes to `~/Library/Application Support/calla.notch`. Sandboxed Shelf
data goes to the new app's corresponding sandbox. Preferences preserve bookmark
bytes and user values; current destination preferences take precedence. App-owned
absolute paths and symlinks are redirected, while external paths stay unchanged.

History keys and the KDE Connect identity are copied into the new Keychain
namespace. Existing local history keys are preserved byte-for-byte and remain
owner-readable only. The migration never creates substitute history keys.
macOS may ask you to unlock Keychain or authorize credential access.
The Engine joins the app's security session so these requests can use your
unlocked login Keychain and show native approval dialogs.
The app includes Apple's [other application data usage description](https://developer.apple.com/documentation/BundleResources/Information-Property-List/NSAppDataUsageDescription)
for accessing the previous sandbox. If macOS denies that access, startup stops
before copying data; approve the app-data prompt and choose Retry. The migration
does not treat a denied preference read as a fresh installation.

macOS privacy permissions and security-scoped access may need approval again.
The app asks about login registration for its new identity; private installation
also exposes the login setting through setup.

## Recovery and rollback

Original data and original Keychain entries are retained as rollback copies.
After migration, owned legacy launch-agent plists are backed up under
`MigrationBackups/LaunchAgents` and retired; an owned setup-command symlink is
retargeted to the new bundled command.
APFS file cloning avoids duplicating large models when supported. Files are
staged atomically, and a lock prevents concurrent migrations. Runtime PID files
and sockets are not imported.

If both locations contain different files or keys, migration stops, preserves
both, and reports the conflicting destination. Resolve the conflict or restore
the appropriate backup, then choose Retry. A locked Keychain, missing encryption
key, invalid preference file, or copy error also stops startup without opening
history stores. Never discard a history key to get past migration.

`.brand-migration-v1.plist` records successful migration in the global support
directory. Interrupted migrations resume from exact copies. Completed migrations
do not reimport stale originals over subsequent edits. The app separately records
successful preference import, so retrying startup cannot reset current settings.
Preference values travel over local XPC and are not duplicated in the global
migration receipt. Once import succeeds, startup no longer reads old preferences.

For rollback, quit calla.notch and reopen the previous installation against its
retained original data. Post-migration edits belong to calla.notch and are not
automatically copied back. Retire the old application and its login job only
after the new installation and history have been checked.

## Updates and references

The inherited public update feed and publishing workflows have been removed.
Private DMG updates remain available. An owned HTTPS feed and signing key must
be configured before Sparkle starts automatically.

Old identifiers exist only in the read-only compatibility table, immutable
provenance records, and artwork inventory. The branding verifier checks these
exceptions explicitly and rejects additional references in current source.
