# Screen Quiz fixtures

Canonical, frozen inputs shared across Quiz capture, detection, worker, ensemble,
storage, and release-gate tests. Tests locate this directory from repository root
using their source-file path, so package-specific test runs use same artifacts.

`freecodecamp-arborescence-question-2.png` was supplied by user for automated
testing. Test-only use. It contains no selected answer and no personal account
data. Companion JSON owns expected OCR anchors, question kind, and answer.

Do not rewrite, crop, or recompress fixture. SHA-256 in manifest detects drift.
