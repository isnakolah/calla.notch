//
//  SettingsSidebar.swift
//  callaNotch
//

import SwiftUI

/// Sixteen pages in three headed groups, with search at the top.
///
/// Flat on purpose: every page is one click from here, and nothing in the
/// sidebar is a doorway to a second list. A dot on a row means something on
/// that page needs the reader, and it is the only colour the sidebar spends
/// apart from the selection.
struct SettingsSidebar: View {
    @ObservedObject var router: SettingsRouter
    @ObservedObject private var attention = SettingsAttention.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                searchButton
                    .padding(.bottom, 6)
                ForEach(SettingsGroup.allCases) { group in
                    if let title = group.title {
                        Text(title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 10)
                            .padding(.top, 12)
                            .padding(.bottom, 4)
                    }
                    ForEach(group.sections) { section in
                        SidebarRow(section: section,
                                   selected: router.route.section == section,
                                   needsAttention: attention.sections.contains(section)) {
                            router.select(section)
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 12)
        }
        .scrollContentBackground(.hidden)
        .background(NotchSurface.sidebar)
        .task { await attention.refresh() }
    }

    private var searchButton: some View {
        Button { router.isSearching = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                Text("Search")
                Spacer(minLength: 0)
                Text("⌘K")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Color.primary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("k", modifiers: .command)
        .help("Search settings")
    }
}

private struct SidebarRow: View {
    let section: SettingsSection
    let selected: Bool
    let needsAttention: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: section.symbol)
                    .font(.system(size: 13))
                    .frame(width: 18)
                    .foregroundStyle(selected ? AnyShapeStyle(NotchTint.active) : AnyShapeStyle(.secondary))
                Text(section.title)
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.primary.opacity(0.85)))
                Spacer(minLength: 0)
                if needsAttention {
                    Circle()
                        .fill(NotchTint.attention)
                        .frame(width: 7, height: 7)
                        .accessibilityLabel(Text("Needs attention"))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? NotchTint.active.opacity(0.24)
                                   : Color.primary.opacity(hovering ? 0.05 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(NotchMotion.settle, value: hovering)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
