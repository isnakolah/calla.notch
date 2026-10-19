//
//  PomodoroNotchBadge.swift
//  callaNotch
//
//  Closed-notch surface for a running session: phase icon wrapped in a
//  draining progress ring on the left of the physical notch, clock countdown
//  on the right. Takes over the slot the CLAUDE/CODEX usage badges
//  occupy, and hands it back the moment the session ends.
//

import SwiftUI

struct PomodoroNotchBadge: View {
    let notchWidth: CGFloat
    let height: CGFloat
    /// Called on hover — opens the notch on the Pomodoro tab, mirroring the
    /// usage badges' behaviour.
    var onBadgeHover: (() -> Void)? = nil

    @ObservedObject private var pomodoro = PomodoroManager.shared

    /// The last minute of a block turns the whole badge coral.
    private var isFinalStretch: Bool {
        pomodoro.isRunning && pomodoro.remaining <= 60
    }

    private var tint: Color {
        if pomodoro.runState == .paused { return NotchInk.tertiary }
        return isFinalStretch ? NotchAccent.stop : pomodoro.phase.tint
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left: what is running — the phase ring and its clock.
            HStack(spacing: 7) {
                ring
                Text(notchClockString(pomodoro.remaining))
                    .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(tint)
                    .contentTransition(.numericText())
                    .animation(.smooth(duration: 0.25), value: pomodoro.remaining)
                    .fixedSize()
            }
            .frame(width: NotchWing.width, alignment: .leading)

            Rectangle()
                .fill(.black)
                .frame(width: notchWidth)

            // Right: how it is going — one segment per block in the cycle.
            blocks
                .frame(width: NotchWing.width, alignment: .trailing)
        }
        .fixedSize()
        .frame(height: height, alignment: .center)
        .animation(.smooth(duration: 0.2), value: pomodoro.runState)
        .onHover { hovering in
            if hovering { onBadgeHover?() }
        }
        // The closed notch is where this spends its life, and a ring plus a
        // clock read out as nothing at all.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityReadout)
    }

    private var accessibilityReadout: String {
        let phase = pomodoro.runState == .paused ? "Paused" : pomodoro.phase.title
        return "\(phase), \(notchClockString(pomodoro.remaining)) remaining"
    }

    private var ring: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.18), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(0.001, pomodoro.progress))
                .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 13, height: 13)
        .padding(1.5)
    }

    private var blocks: some View {
        let cycle = max(1, min(6, pomodoro.selectedPreset.cyclesBeforeLongBreak))
        let done = pomodoro.phase == .longBreak ? cycle : pomodoro.completedWorkBlocks % cycle
        let current = pomodoro.phase.isWork ? done : nil
        return HStack(spacing: 3) {
            ForEach(0..<cycle, id: \.self) { index in
                Capsule()
                    .fill(index < done ? tint
                          : index == current ? tint.opacity(isFinalStretch ? 0.85 : 0.5)
                          : Color.white.opacity(0.18))
                    .frame(width: 10, height: 5)
            }
        }
    }
}
