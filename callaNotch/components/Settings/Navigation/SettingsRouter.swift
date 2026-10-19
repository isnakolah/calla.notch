//
//  SettingsRouter.swift
//  callaNotch
//

import SwiftUI

/// Who owns where the window is.
///
/// An `ObservableObject` rather than `@State` in a view, because
/// `SettingsWindowController` has to reach it: a deep link is one assignment
/// here, not a rebuilt content view that throws away a half-typed prompt.
@MainActor
final class SettingsRouter: ObservableObject {
    @Published var route: SettingsRoute
    /// The ⌘K palette.
    @Published var isSearching = false

    init(_ route: SettingsRoute = .init(.home)) {
        self.route = route
    }

    /// Bound straight into `NavigationStack(path:)`.
    var path: Binding<[SettingsPage]> {
        Binding(get: { self.route.path }, set: { self.route.path = $0 })
    }

    /// Choosing a row in the sidebar always lands on the top of that page.
    func select(_ section: SettingsSection) {
        route = .init(section)
    }

    func go(_ route: SettingsRoute) { self.route = route }
    func go(page: SettingsPage) { route = .init(page: page) }
    func go(legacyIdentifier: String) { route = .init(legacyIdentifier: legacyIdentifier) }

    func push(_ page: SettingsPage) {
        switch page {
        case .copilotKnowledgeDetail: route.path.append(page)
        default: go(page: page)
        }
    }

    func pop() { _ = route.path.popLast() }
    func popToRoot() { route.path.removeAll() }

    /// Called by the page once it has scrolled to, or selected, what was asked
    /// for, so returning to the page later does not repeat it.
    func consumeFocus() { route.focus = nil }
}

// MARK: - Reaching it

private struct SettingsRouterKey: EnvironmentKey {
    /// Optional: a view rendered outside the Settings window — a `#Preview`,
    /// the first-run window — genuinely has no router.
    static let defaultValue: SettingsRouter? = nil
}

extension EnvironmentValues {
    var settingsRouter: SettingsRouter? {
        get { self[SettingsRouterKey.self] }
        set { self[SettingsRouterKey.self] = newValue }
    }
}
