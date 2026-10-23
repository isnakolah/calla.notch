#!/usr/bin/env python3
"""Export the actual Swift demo timeline as browser data and captions."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--worktree', type=Path, default=ROOT.parent.parent / 'calla.notch-landing-demo')
args = parser.parse_args()
source = args.worktree / 'Demo/Core/DemoTimeline.swift'
main = '''
import Foundation
let turns: [[String: Any]] = DemoTimeline.turns.map { ["at": $0.at, "source": $0.source, "text": $0.text] }
let summaries: [[String: Any]] = DemoTimeline.summaries.map { ["at": $0.at, "standing": $0.standing, "points": $0.points] }
let data = try JSONSerialization.data(withJSONObject: ["scenario": "weekly-team-check-in", "duration": 45, "turns": turns, "summaries": summaries], options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(data)
'''
with tempfile.TemporaryDirectory(prefix='calla-timeline-') as temp:
    path = Path(temp)
    (path / 'main.swift').write_text(main)
    subprocess.run(['swiftc', str(source), str(path / 'main.swift'), '-o', str(path / 'timeline')], check=True)
    data = subprocess.check_output([str(path / 'timeline'), '--demo-weekly'])
timeline = json.loads(data)
output = ROOT / 'public/demo'
output.mkdir(parents=True, exist_ok=True)
(output / 'timeline.json').write_bytes(data + b'\n')
def stamp(t):
    return f'00:{int(t)//60:02d}:{int(t)%60:02d}.{int(t*1000)%1000:03d}'
captions = ['WEBVTT', '']
for i, turn in enumerate(timeline['turns']):
    end = timeline['turns'][i + 1]['at'] if i + 1 < len(timeline['turns']) else 42
    captions.extend([f'{stamp(turn["at"])} --> {stamp(end)}', ('You' if turn['source'] == 'me' else 'Maya') + ': ' + turn['text'], ''])
(output / 'weekly-check-in.vtt').write_text('\n'.join(captions))
print(f'Exported {len(timeline["turns"])} native turns, summaries and captions.')
