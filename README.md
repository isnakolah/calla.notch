# calla.notch

A macOS notch companion with media controls, calendar, file Shelf, focus timers,
and Calla assistance for calls, screen questions, and live coding.

This repository is a customized GPL-licensed fork. Original authorship and asset
credits are recorded in [source provenance](docs/provenance/README.md).

## Build and run

Open `callaNotch.xcodeproj` and select the `callaNotch` scheme. Local app builds
use the persistent **Calla Local Signing** identity. The private distribution
requires Apple Silicon and macOS 15 or later.

```sh
xcodebuild -project callaNotch.xcodeproj -scheme callaNotch -configuration Debug build
scripts/deploy.sh
```

Private packaging and installation are described in
[the installation guide](docs/private-installation.md). There is no configured
public update feed, Homebrew tap, or public download package. Existing private
packages update through **Setup, Repair & Updates…**.

## Branding and existing installations

All product icons and logos are collected in [Branding](Branding/README.md),
including their source inventory and replacement instructions. The existing
artwork is retained while replacement artwork is prepared.

The first installed launch imports settings and data from the previous app
without deleting the originals. See [migration and recovery](docs/branding-migration.md).
macOS permissions and login registration belong to the new app identity.

## Verify

```sh
python3 scripts/verification/verify_branding.py
swift test
swift test --package-path CallaContracts
swift test --package-path Distribution
swift test --package-path Intelligence
swift test --package-path CallaCallHost
make -C Tutor test
```

Report issues and contribute through [isnakolah/calla.notch](https://github.com/isnakolah/calla.notch).
See [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md), and [LICENSE](LICENSE).
