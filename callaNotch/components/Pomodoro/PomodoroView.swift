//
//  PomodoroView.swift
//  callaNotch
//
//  The open-notch Pomodoro section.
//
//  Three columns: the countdown in its ring, the state, title and transport,
//  and a Today column behind a hairline. Idle and running are the same frame —
//  the ring empties, and the transport changes shape.
//
//  Two earlier mistakes, both visible in the deployed build: a chrome row that
//  spent a band of a 168pt surface naming the tab the reader had just clicked,
//  and a separate control rail below the card, which pushed the whole layout
//  past the notch's lower curve so the Start button was drawn outside the shape.
//  The transport row ends where the ring does, and there is no second band.
//

import AppKit
import Defaults
import SwiftUI

struct PomodoroView: View {
    @ObservedObject private var pomodoro = PomodoroManager.shared
    @Default(.pomodoroPresets) private var presets
    @Default(.pomodoroSelectedPresetID) private var selectedPresetID

    @FocusState private var titleFieldFocused: Bool

    /// Lengths offered beside the saved presets, so a one-off block does not
    /// need a row of its own on a surface that has no room for one.
    private let customLengths = [15, 45, 60, 90]

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ring
            timerColumn
                .frame(maxWidth: .infinity)
            todayColumn
                .frame(width: 84)
        }
        .padding(.top, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Vertical insets only: the notch's own horizontal inset already puts
        // the ring 18pt from the curve, and the middle column needs the width.
        .padding(.bottom, 10)
        .animation(.smooth(duration: 0.25), value: pomodoro.isActive)
    }

    // MARK: - Ring

    /// The countdown inside the phase's ring. Idle, the ring is an empty track
    /// around what pressing Start would buy.
    private var ring: some View {
        ZStack {
            Circle()
                .stroke(NotchInk.hairline, lineWidth: 6)
            if pomodoro.isActive {
                Circle()
                    .trim(from: 0, to: max(0.001, pomodoro.progress))
                    .stroke(ringTint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.smooth(duration: 0.25), value: pomodoro.progress)
            }
            VStack(spacing: 1) {
                Text(figureText)
                    .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                    .tracking(-0.3)
                    .foregroundStyle(figureTint)
                    .contentTransition(.numericText())
                    .animation(.smooth(duration: 0.25), value: pomodoro.remaining)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                NotchCaps(pomodoro.isActive ? "left" : "min")
            }
            .padding(.horizontal, 10)
        }
        .padding(3)
        .frame(width: 96, height: 96)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Timer

    private var timerColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                NotchCaps(stateLine, tint: stateTint)
                titleField
                if pomodoro.isActive {
                    blockIndicator
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 4)
            transport
        }
        .frame(height: 96)
    }

    /// One segment per block in the cycle: done, the current one, and what is left.
    private var blockIndicator: some View {
        let cycle = max(1, min(6, selectedPreset?.cyclesBeforeLongBreak ?? 4))
        let done = pomodoro.phase == .longBreak ? cycle : pomodoro.completedWorkBlocks % cycle
        let current = pomodoro.phase.isWork ? done : nil
        return HStack(spacing: 4) {
            ForEach(0..<cycle, id: \.self) { index in
                Capsule()
                    .fill(index < done ? NotchAccent.focus
                          : index == current ? NotchAccent.focus.opacity(0.45)
                          : Color.white.opacity(0.14))
                    .frame(width: 22, height: 4)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Block \(min(done + 1, cycle)) of \(cycle)")
    }

    /// The one field, in the same slot whether or not a block is running.
    private var titleField: some View {
        TextField("What are you working on?", text: $pomodoro.sessionTitle)
            .textFieldStyle(.plain)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(NotchInk.primary)
            .focused($titleFieldFocused)
            .lineLimit(1)
            // Stays in layout focused or not: a conditional layer here used to
            // change the intrinsic width and shove the figure sideways.
            .overlay {
                Color.clear
                    .contentShape(Rectangle())
                    .allowsHitTesting(!titleFieldFocused)
                    .onTapGesture {
                        NSApp.activate(ignoringOtherApps: true)
                        DispatchQueue.main.async { titleFieldFocused = true }
                    }
            }
            .onSubmit { titleFieldFocused = false }
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Running: a labelled Pause/Resume pill, then Skip, Reset and Stop.
    /// Idle: Start, the saved presets as segments, and the menu for the rest.
    @ViewBuilder private var transport: some View {
        if pomodoro.isActive {
            HStack(spacing: 6) {
                sunPill(pomodoro.isRunning ? "Pause" : "Resume",
                        symbol: pomodoro.isRunning ? "pause.fill" : "play.fill",
                        help: pomodoro.isRunning ? "Pause timer" : "Resume timer",
                        action: pomodoro.toggle)
                circleButton("forward.end.fill", help: "Skip phase", action: pomodoro.skip)
                circleButton("arrow.counterclockwise", help: "Reset phase", action: pomodoro.reset)
                circleButton("stop.fill", help: "Stop timer", action: pomodoro.stop)
                ViewThatFits(in: .horizontal) {
                    Text(edgeNote)
                        .font(NotchGlassType.caption)
                        .foregroundStyle(NotchInk.tertiary)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.leading, 4)
                    Color.clear.frame(width: 0, height: 0)
                }
            }
        } else {
            HStack(spacing: 6) {
                sunPill("Start focus", symbol: "play.fill", help: "Start focus") {
                    if let preset = selectedPreset { pomodoro.start(preset: preset) }
                }
                presetSegments
                presetMenu
            }
        }
    }

    private func sunPill(_ title: String, symbol: String, help: String,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .bold))
                Text(title)
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(NotchAccent.onAccent)
            .padding(.leading, 11)
            .padding(.trailing, 14)
            .frame(height: 32)
            .background(Capsule().fill(NotchAccent.focus))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(title)
    }

    private func circleButton(_ symbol: String, help: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.86))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.white.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    /// The saved presets by length. Picking one only selects it, exactly as the
    /// menu does while idle; Start is still the press that begins the block.
    private var presetSegments: some View {
        HStack(spacing: 2) {
            ForEach(presets.prefix(3)) { preset in
                let picked = preset.id == selectedPreset?.id
                Button {
                    selectedPresetID = preset.id
                } label: {
                    Text("\(preset.workMinutes)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(picked ? NotchAccent.focus : Color.white.opacity(0.75))
                        .padding(.horizontal, 8)
                        .frame(minWidth: 30)
                        .frame(height: 26)
                        .background(Capsule().fill(picked ? NotchAccent.focus.opacity(NotchAccent.strongFill) : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("\(preset.name) · \(preset.chipLabel)")
                .accessibilityLabel("\(preset.name), \(preset.workMinutes) minutes")
                .accessibilityAddTraits(picked ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.08)))
    }

    /// Saved presets and a few one-off lengths. Kept beside the segments for
    /// the presets past the first three and the lengths that start at once.
    private var presetMenu: some View {
        Menu {
            ForEach(presets) { preset in
                Button("\(preset.name) · \(preset.chipLabel)") {
                    selectedPresetID = preset.id
                    if pomodoro.isActive { pomodoro.start(preset: preset) }
                }
            }
            Divider()
            ForEach(customLengths, id: \.self) { minutes in
                Button("Just \(minutes) minutes") { pomodoro.startCustom(minutes: minutes) }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(NotchInk.secondary)
                .frame(width: 26, height: 30)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose a preset or a one-off length")
        .accessibilityLabel("More lengths")
    }

    // MARK: - Today

    private var todayColumn: some View {
        let blocks = pomodoro.todayCompletedWorkBlocks
        return VStack(alignment: .leading, spacing: 3) {
            NotchCaps("Today")
            Text("\(blocks)")
                .font(.system(size: 26, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(blocks > 0 ? NotchInk.primary : NotchInk.tertiary)
            Text(blocks > 0 ? "blocks\n\(focusTotalString(pomodoro.todayFocusTime)) focused" : "blocks yet")
                .font(NotchGlassType.caption)
                .foregroundStyle(NotchInk.tertiary)
                .lineSpacing(1)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 96)
        .padding(.leading, 14)
        .overlay(alignment: .leading) {
            Rectangle().fill(NotchInk.hairline).frame(width: 1)
        }
    }

    // MARK: - Copy

    private var selectedPreset: PomodoroPreset? {
        presets.first { $0.id == selectedPresetID } ?? presets.first
    }

    private var stateLine: String {
        guard pomodoro.isActive else { return "Ready" }
        let cycle = max(1, min(6, selectedPreset?.cyclesBeforeLongBreak ?? 4))
        let block = "block \(pomodoro.completedWorkBlocks % cycle + 1) of \(cycle)"
        if pomodoro.runState == .paused { return "Paused · \(block)" }
        guard pomodoro.phase.isWork else { return pomodoro.phase.title }
        return "\(pomodoro.phase.title) · \(block)"
    }

    private var stateTint: Color {
        pomodoro.isRunning ? pomodoro.phase.tint : NotchInk.tertiary
    }

    private var ringTint: Color {
        if isFinalStretch { return NotchAccent.stop }
        return pomodoro.isRunning ? pomodoro.phase.tint : pomodoro.phase.tint.opacity(0.4)
    }

    /// The caption under the bar: when this phase gives out.
    private var edgeNote: String {
        guard pomodoro.isActive else {
            guard let preset = selectedPreset else { return "" }
            return "\(preset.workMinutes)m focus, then \(preset.shortBreakMinutes)m break"
        }
        let ends = Date().addingTimeInterval(pomodoro.remaining)
        let next = pomodoro.phase.isWork ? "Break" : "Focus"
        return "\(next) at \(ends.formatted(date: .omitted, time: .shortened))"
    }

    /// Running counts down; idle shows the minutes pressing Start would buy.
    private var figureText: String {
        guard pomodoro.isActive else {
            return "\(selectedPreset?.workMinutes ?? 25)"
        }
        return notchClockString(pomodoro.remaining)
    }

    private var figureTint: Color {
        guard pomodoro.isActive else { return NotchInk.tertiary }
        return isFinalStretch ? NotchAccent.stop : NotchInk.primary
    }

    private var isFinalStretch: Bool {
        pomodoro.isRunning && pomodoro.remaining <= 60
    }
}
