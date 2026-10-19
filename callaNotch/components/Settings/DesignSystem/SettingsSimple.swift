//
//  SettingsSimple.swift
//  callaNotch
//
//  The pieces every page is built from: a captioned card of ruled rows, a
//  row, a switch, and the notch strip the pages draw their preview on.
//

import Defaults
import SwiftUI

/// A filled, rounded square with a white glyph — how Home's feature tiles and
/// the search palette tell destinations apart before a word is read.
struct SettingsIconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                    .fill(color)
            )
            .accessibilityHidden(true)
    }
}

/// A group: caption above, rows on one card, ruled between them.
struct SettingsList<Content: View>: View {
    var title: String?
    var detail: String?
    var tint: Color?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, detail: String? = nil, tint: Color? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if title != nil || detail != nil {
                SettingsCaption(title: title, detail: detail)
            }
            VStack(spacing: 0) {
                _VariadicView.Tree(RuledLayout()) { content }
            }
            .padding(.horizontal, 14)
            .settingsCardSurface(tint: tint)
        }
    }

    private struct RuledLayout: _VariadicView_MultiViewRoot {
        func body(children: _VariadicView.Children) -> some View {
            let last = children.last?.id
            ForEach(children) { child in
                child
                if child.id != last {
                    Rectangle().fill(NotchSurface.hairline).frame(height: 1)
                }
            }
        }
    }
}

/// A row inside a `SettingsList`: label, explanation, control.
struct SettingsListRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var control: Control

    init(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(NotchType.rowTitle)
                if let detail {
                    Text(detail)
                        .font(NotchType.rowDetail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control
        }
        .padding(.vertical, 8)
        .frame(minHeight: SettingsMetrics.rowHeight)
    }
}

/// The switch every row uses, labelled for VoiceOver by the row it sits in.
struct SettingsSwitch: View {
    let label: String
    @Binding var isOn: Bool

    init(_ label: String, isOn: Binding<Bool>) {
        self.label = label
        self._isOn = isOn
    }

    var body: some View {
        Toggle("", isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .accessibilityLabel(Text(label))
    }
}

/// A row that is just a name and a switch.
struct SettingsToggleRow: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    init(_ title: String, detail: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        self._isOn = isOn
    }

    var body: some View {
        SettingsListRow(title, detail: detail) {
            SettingsSwitch(title, isOn: $isOn)
        }
    }
}

/// The settings almost nobody changes, folded under one line.
///
/// Remembered per page, so opening it once keeps it open for the reader who
/// does change these.
struct SettingsAdvancedFold<Content: View>: View {
    let id: String
    var title: String
    /// Anchors inside the fold. Search or a deep link naming one opens it, so
    /// the page can scroll to something that would otherwise be folded away.
    var opensFor: [String]
    @ViewBuilder var content: Content
    @AppStorage private var expanded: Bool
    @Environment(\.settingsRouter) private var router

    init(_ id: String, title: String = "More options", opensFor: [String] = [],
         @ViewBuilder content: () -> Content) {
        self.id = id
        self.title = title
        self.opensFor = opensFor
        self.content = content()
        _expanded = AppStorage(wrappedValue: false, "settings.advanced.\(id)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(NotchMotion.settle) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                    Rectangle()
                        .fill(NotchSurface.hairline)
                        .frame(height: 1)
                        .padding(.leading, 4)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(expanded ? "Hide \(title)" : "Show \(title)"))

            if expanded {
                VStack(alignment: .leading, spacing: SettingsMetrics.groupGap) { content }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onAppear { openIfAsked(router?.route.focus) }
        .onChange(of: router?.route.focus) { _, focus in openIfAsked(focus) }
    }

    private func openIfAsked(_ focus: String?) {
        guard let focus, opensFor.contains(focus), !expanded else { return }
        expanded = true
    }
}

// MARK: - The notch strip

/// A slice of desktop with a menu bar and the notch hanging from it — the
/// preview at the top of Home, Appearance and Music.
///
/// Every page in this window configures one physical surface, so the pages
/// that change what it looks like draw it, and redraw it as you change them.
struct NotchStage<Notch: View>: View {
    var height: CGFloat = 118
    var caption: String?
    @ViewBuilder var notch: Notch

    var body: some View {
        ZStack(alignment: .top) {
            Rectangle().fill(Color(red: 0.15, green: 0.20, blue: 0.24))
            HStack {
                Text("Finder").fontWeight(.semibold)
                Spacer()
                Text(Date.now, format: .dateTime.weekday(.abbreviated).hour().minute())
            }
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, 14)
            .frame(height: 26)
            .background(Color.black.opacity(0.28))

            notch

            if let caption {
                VStack {
                    Spacer()
                    Text(caption)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.72))
                        .padding(.bottom, 14)
                        .contentTransition(.opacity)
                }
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: NotchRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: NotchRadius.card, style: .continuous)
                .strokeBorder(NotchSurface.hairline, lineWidth: 1)
        )
        .animation(NotchMotion.open, value: caption)
        .accessibilityElement(children: .combine)
    }
}

/// The black slab itself, at a given size, with whatever it holds.
struct NotchSlab<Content: View>: View {
    var width: CGFloat
    var height: CGFloat
    var bottomRadius: CGFloat = 12
    var shadow = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(width: width, height: height)
            .background(
                UnevenRoundedRectangle(bottomLeadingRadius: bottomRadius, bottomTrailingRadius: bottomRadius,
                                       style: .continuous)
                    .fill(NotchSurface.sunken)
                    .shadow(color: .black.opacity(shadow ? 0.55 : 0), radius: 15, y: 10)
            )
            .animation(NotchMotion.open, value: width)
            .animation(NotchMotion.open, value: height)
    }
}

/// The music live activity as the closed notch draws it: artwork either side
/// of the cut-out, a level meter on the other.
struct NotchMusicActivity: View {
    var tint: Color
    var showsArtwork = true

    var body: some View {
        HStack {
            if showsArtwork {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(red: 0.76, green: 0.38, blue: 0.23))
                    .frame(width: 20, height: 20)
                Spacer()
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach([6.0, 12, 9, 14, 7], id: \.self) { bar in
                        Capsule().fill(tint).frame(width: 2, height: bar)
                    }
                }
                .frame(height: 14, alignment: .bottom)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
    }
}
