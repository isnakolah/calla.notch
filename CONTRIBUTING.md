# Contributing to calla.notch

Use [this repository](https://github.com/isnakolah/calla.notch) for issues and
pull requests. Keep changes focused and describe the behavior being changed.

```sh
git clone https://github.com/isnakolah/calla.notch.git
cd calla.notch
open callaNotch.xcodeproj
```

Run the relevant package tests and an app build. Changes to Tutor must also pass
`make -C Tutor test`. Include screenshots for visible changes and distinguish
build verification from installed runtime verification.

Translations live in `callaNotch/Localizable.xcstrings` and are reviewed through
pull requests. The product name is always `calla.notch`. No external translation
service is configured for this fork.

Product artwork belongs in `Branding/`; update its manifest whenever an asset
changes. Run `python3 scripts/verification/verify_branding.py` before handoff.
Keep original author and third-party credits intact.
