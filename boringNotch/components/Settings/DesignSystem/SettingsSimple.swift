//
//  SettingsSimple.swift
//  boringNotch
//
//  The few pieces the four-page Settings window is built from.
//

import SwiftUI

/// A filled, rounded square with a white glyph — the way System Settings marks
/// its rows, so each one is found by colour before it is read.
struct SettingsIconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 26

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .fill(color.gradient)
            )
            .accessibilityHidden(true)
    }
}

/// A list of rows on one card, ruled between them and inset past the icons.
struct SettingsList<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .semibold))
                    .kerning(0.6)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            VStack(spacing: 0) {
                _VariadicView.Tree(RuledLayout()) { content }
            }
            .padding(.horizontal, 12)
            .background(NotchSurface.raised,
                        in: RoundedRectangle(cornerRadius: NotchRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: NotchRadius.card, style: .continuous)
                    .strokeBorder(NotchSurface.hairline, lineWidth: 1)
            )
        }
    }

    private struct RuledLayout: _VariadicView_MultiViewRoot {
        func body(children: _VariadicView.Children) -> some View {
            let last = children.last?.id
            ForEach(children) { child in
                child
                if child.id != last {
                    Divider().opacity(0.5).padding(.leading, 38)
                }
            }
        }
    }
}

/// One feature: its tile, its name and what it does, a switch when it can be
/// turned off, and a chevron to everything else about it. The row is the
/// button; the switch works without opening the page.
struct SettingsFeatureRow: View {
    let page: SettingsPage
    var isOn: Binding<Bool>?
    /// What the page currently says, when that is worth reading from here.
    var status: String?
    var statusTint: Color?

    @Environment(\.settingsRouter) private var router
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Button {
                router?.push(page)
            } label: {
                HStack(spacing: 12) {
                    SettingsIconTile(symbol: page.symbol, color: page.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(page.title).font(.system(size: 13, weight: .medium))
                        if let detail = page.detail {
                            Text(detail)
                                .font(NotchType.rowDetail)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 8)
                    if let status {
                        Text(status)
                            .font(.system(size: 11.5))
                            .foregroundStyle(statusTint ?? .secondary)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let isOn {
                Toggle("", isOn: isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .accessibilityLabel(Text(page.title))
            }

            Button {
                router?.push(page)
            } label: {
                Image(systemName: "chevron.forward")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(hovering ? .secondary : .tertiary)
                    .frame(width: 14, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Open \(String(localized: page.title))"))
        }
        .padding(.vertical, 9)
        .onHover { hovering = $0 }
        .animation(NotchMotion.settle, value: hovering)
    }
}

/// A plain setting inside a `SettingsList`: label, explanation, control.
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
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium))
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
        .padding(.vertical, 9)
        .padding(.leading, 0)
    }
}

/// The settings almost nobody changes, folded away under one line.
///
/// Remembered per pane, so opening it once means it stays open for the reader
/// who does change these.
struct SettingsAdvancedFold<Content: View>: View {
    let id: String
    @ViewBuilder var content: Content
    @AppStorage private var expanded: Bool

    init(_ id: String, @ViewBuilder content: () -> Content) {
        self.id = id
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
                    Text("Advanced")
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
            .accessibilityLabel(Text(expanded ? "Hide advanced settings" : "Show advanced settings"))

            if expanded {
                VStack(alignment: .leading, spacing: 14) { content }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.top, 6)
    }
}
