//
//  SettingsView.swift
//  callaNotch
//
//  Created by Richard Kunkli on 07/08/2024.
//

import Defaults
import Sparkle
import SwiftUI

/// The Settings window: a flat sidebar of pages, the page, and the ⌘K palette
/// over both.
struct SettingsView: View {
    @StateObject private var router: SettingsRouter

    /// Read so the tree re-renders when the accent changes. `Color.effectiveAccent`
    /// reads `Defaults` imperatively, so SwiftUI has no dependency on it without
    /// these two.
    @Default(.useCustomAccentColor) private var useCustomAccentColor
    @Default(.customAccentColorData) private var customAccentColorData

    let updaterController: SPUStandardUpdaterController?

    init(initialTab: String = "Home", updaterController: SPUStandardUpdaterController? = nil) {
        _router = StateObject(wrappedValue: SettingsRouter(.init(legacyIdentifier: initialTab)))
        self.updaterController = updaterController
    }

    /// The window controller keeps one of these and drives deep links through it.
    init(router: SettingsRouter, updaterController: SPUStandardUpdaterController? = nil) {
        _router = StateObject(wrappedValue: router)
        self.updaterController = updaterController
    }

    var body: some View {
        NavigationSplitView {
            SettingsSidebar(router: router)
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(min: 220, ideal: 228, max: 260)
        } detail: {
            NavigationStack(path: router.path) {
                router.route.section.page
                    .navigationDestination(for: SettingsPage.self) { page in
                        page.view.navigationBarBackButtonHidden(true)
                    }
            }
            // A page change replaces the stack rather than animating a pop
            // through records the reader never chose.
            .id(router.route.section)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            // Keeps SwiftUI from installing a title in a window that hides one.
            ToolbarItem(placement: .principal) {
                Text("").frame(width: 0, height: 0).accessibilityHidden(true)
            }
        }
        .overlay {
            if router.isSearching {
                SettingsSearchPalette(router: router)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: router.isSearching)
        .frame(minWidth: 900, minHeight: 600)
        .background(NotchSurface.base)
        .tint(.effectiveAccent)
        .environment(\.settingsRouter, router)
        .environment(\.sparkleUpdater, updaterController ?? SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil))
    }
}

// MARK: - ⌘K

/// Search that reaches single settings. Typing narrows; ↑↓ choose; ↩ opens the
/// page scrolled to that setting's group and lights it up; esc closes.
struct SettingsSearchPalette: View {
    @ObservedObject var router: SettingsRouter
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    private var matches: [SettingsSearchIndex.Match] {
        Array(SettingsSearchIndex.search(query).prefix(9))
    }
    private var settings: [SettingsSearchIndex.Match] { matches.filter { $0.kind == .setting } }
    private var pages: [SettingsSearchIndex.Match] { matches.filter { $0.kind == .page } }
    /// Settings first, then pages — the order they are drawn in.
    private var ordered: [SettingsSearchIndex.Match] { settings + pages }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { close() }
                .accessibilityHidden(true)

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                    TextField("Search settings", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 18))
                        .focused($focused)
                        .onSubmit { open(selection) }
                }
                .padding(.horizontal, 18)
                .frame(height: 56)

                Rectangle().fill(NotchSurface.hairline).frame(height: 1)

                if !ordered.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            if !settings.isEmpty {
                                heading("Settings")
                                ForEach(Array(settings.enumerated()), id: \.element.id) { index, match in
                                    row(match, index: index)
                                }
                            }
                            if !pages.isEmpty {
                                heading("Pages")
                                ForEach(Array(pages.enumerated()), id: \.element.id) { index, match in
                                    row(match, index: settings.count + index)
                                }
                            }
                        }
                        .padding(.bottom, 8)
                    }
                    .frame(maxHeight: 380)
                } else if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("Nothing matches “\(query)”.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                } else {
                    Text("Type a setting, a feature, or a word like “peek” or “whisper”.")
                        .font(NotchType.rowDetail)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 22)
                }

                Rectangle().fill(NotchSurface.hairline).frame(height: 1)
                HStack(spacing: 18) {
                    hint("↑ ↓", "choose")
                    hint("↩", "open and highlight")
                    hint("esc", "close")
                    Spacer()
                }
                .padding(.horizontal, 18)
                .frame(height: 36)
            }
            .frame(width: 600)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 30, y: 20)
            .padding(.top, 92)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Search settings"))
        }
        .onAppear { focused = true }
        .onChange(of: query) { selection = 0 }
        .onKeyPress(.downArrow) {
            selection = min(selection + 1, max(ordered.count - 1, 0)); return .handled
        }
        .onKeyPress(.upArrow) {
            selection = max(selection - 1, 0); return .handled
        }
        .onKeyPress(.escape) { close(); return .handled }
        .onExitCommand { close() }
    }

    private func heading(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }

    private func row(_ match: SettingsSearchIndex.Match, index: Int) -> some View {
        let chosen = index == selection
        return Button { open(index) } label: {
            HStack(spacing: 12) {
                SettingsIconTile(symbol: match.section.filledSymbol, color: match.section.tint, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(match.title).font(.system(size: 13))
                    Text(match.context)
                        .font(NotchType.rowDetail)
                        .foregroundStyle(chosen ? AnyShapeStyle(.white.opacity(0.82)) : AnyShapeStyle(.secondary))
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(chosen ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(chosen ? NotchTint.active : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .onHover { if $0 { selection = index } }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 11))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
            Text(label)
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }

    private func open(_ index: Int) {
        guard ordered.indices.contains(index) else { return }
        router.go(ordered[index].route)
        close()
    }

    private func close() {
        router.isSearching = false
    }
}
