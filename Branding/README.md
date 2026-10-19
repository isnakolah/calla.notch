# calla.notch artwork

This is the single home for product icons and logos. The current artwork has
been collected, not redesigned. Open [contact-sheet.png](contact-sheet.png) to
review it and [manifest.json](manifest.json) for every source, hash, usage, and
replacement status.

- `Assets.xcassets/AppIcon.appiconset`: all ten macOS icon slots, compiled into
  the app's `AppIcon.icns` by Xcode.
- `Assets.xcassets/AppLogo.imageset`: the onboarding logo.
- `Assets.xcassets/AppLogoSmall.imageset`: an unused smaller logo retained for
  future use.
- `Archive/`: the retired team wordmark, unused welcome audio, and remote README
  artwork. Archive files are excluded from the app target.

No standalone favicon source exists in this repository. Generic interface
symbols and third-party application logos remain in the app's ordinary asset
catalog; they are not product branding.

## Replace artwork

1. Replace the active files here, retaining asset names and filenames so
   application code and Xcode references need no further changes.
2. Supply each AppIcon slot at `size × scale` pixels; the largest is 1024×1024.
   Keep PNG alpha and the logo's existing universal idiom.
3. Update file hashes, dimensions, status, and credits in the manifest; regenerate
   the contact sheet using `python3 scripts/verification/branding_contact_sheet.py`.
4. Run `python3 scripts/verification/verify_branding.py`, build the app, and check
   its Finder/Dock icon and onboarding logo.

Original paths are preserved solely as inventory records. Attribution is in
[source provenance](../docs/provenance/README.md).
