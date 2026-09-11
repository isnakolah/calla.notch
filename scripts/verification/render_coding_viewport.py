#!/usr/bin/env python3
"""Render the production Code reader offscreen; no call, screen or project capture.

The frame uses synthetic controls. This is component layout evidence, not an
installed call/recovery test. Outputs are PNGs in the requested directory.
"""
from pathlib import Path
import argparse
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, default=Path('/tmp/coding-viewport-render'))
parser.add_argument('--fixture', type=Path, default=Path(__file__).with_name('coding_viewport_fixture.swift'))
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
source = (root / 'boringNotch/components/Calla/CallaCopilotTabView.swift').read_text()
components = source[source.index('// MARK: - Live coding reading surface'):source.index('struct WavePreparationControls:')]
quiz = (root / 'boringNotch/components/Calla/CallaQuizPresentation.swift').read_text()
tokens = quiz[quiz.index('    enum CodeTokenRole:'):quiz.index('    // MARK: - Answer history')]
fixture = args.fixture.read_text()
with tempfile.TemporaryDirectory(prefix='coding-layout-') as scratch:
    swift = Path(scratch) / 'render.swift'
    swift.write_text('import SwiftUI\nimport AppKit\nextension Notification.Name { static let callaCodingScroll = Notification.Name("callaCodingScroll") }\nenum CallaQuizPresentation {\n' + tokens + '}\n' + components + fixture)
    binary = Path(scratch) / 'render'
    subprocess.run(['swiftc', str(swift), '-o', str(binary)], check=True)
    subprocess.run([str(binary), str(args.output.resolve())], check=True)
