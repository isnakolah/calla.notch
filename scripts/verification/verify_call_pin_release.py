#!/usr/bin/env python3
"""Exercise production Call presentation transitions without capture or app UI."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'callaNotch/components/Calla/CopilotLiveSession.swift').read_text()

def block(marker):
    start = source.index(marker)
    brace = source.index('{', start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

methods = '\n'.join(block(name) for name in [
    'func prepareForSessionStart()', 'func releaseEndedCall()', 'var pinsNotchOpen: Bool',
    'private func apply(starting: Bool)', 'private func apply(running: Bool)',
    'private func apply(ending: Bool)', 'func clearStartupFailure()', 'private func pin()'])
program = r'''
import Foundation
extension Notification.Name { static let copilotLiveDidChange = Notification.Name("copilotLiveDidChange") }
enum Flag { case callaCopilotEnabled }
enum Defaults { static subscript(_ flag: Flag) -> Bool { true } }
final class CallaEngineClient {
    static let shared = CallaEngineClient()
    struct Copilot { var lastResult: String? }
    struct Status { var copilot = Copilot() }
    var status = Status()
}
final class Session {
    enum Layout { case full, compact }
    enum Cursor { case latest }
    var layout = Layout.full
    var quizAnswerCursor = Cursor.latest
    var quizOutcome: Int?
    var pinned = false, endedByReader = false, dismissedByReader = false
    var isLive = false, isCoding = false, starting = false, ending = false
    var startupFailed = false, signInActive = false
    var startupFailure: String?, lastStartupStage: String?
    var callEndReleases = 0, reveals = 0
    private func reveal() { reveals += 1 }
''' + methods + r'''
    func check(endingFirst: Bool) {
        apply(starting: true)
        apply(running: true)
        precondition(pinsNotchOpen)
        let priorReveals = reveals
        releaseEndedCall()
        precondition(!pinsNotchOpen && callEndReleases == 1)
        if endingFirst {
            apply(ending: true); precondition(!pinsNotchOpen)
            apply(running: false); precondition(!pinsNotchOpen)
        } else {
            apply(running: false); precondition(!pinsNotchOpen)
            apply(ending: true); precondition(!pinsNotchOpen)
        }
        apply(running: true) // stale, in-flight capture status
        precondition(!pinsNotchOpen)
        apply(ending: false)
        apply(starting: false)
        apply(starting: true) // stale host startup status after End
        precondition(!pinsNotchOpen && !startupFailed && reveals == priorReveals)
        prepareForSessionStart()
        apply(starting: true)
        precondition(pinsNotchOpen && !endedByReader)
        apply(running: true)
        precondition(isLive && pinsNotchOpen)
    }
}
Session().check(endingFirst: true)
Session().check(endingFirst: false)
print("PASS: End releases presentation; both shutdown orders and late capture cannot re-pin; next explicit Start works")
'''
with tempfile.TemporaryDirectory(prefix='call-pin-release-') as scratch:
    swift = Path(scratch) / 'probe.swift'
    swift.write_text(program)
    subprocess.run(['swift', str(swift)], check=True)
