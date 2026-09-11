//
//  IceConfiguration.swift
//  boringNotch
//
//  Derived from Ice at 11edd39115f3f43a83ae114b5348df6a0e1741cf.
//  Copyright (c) Jordan Baird. SPDX-License-Identifier: GPL-3.0-or-later.
//  Boring owns this adapted implementation; see Ice/NOTICE.md.
//

import Foundation

/// Stable section names. Stored identities never use a display name alone.
enum IceSection: String, CaseIterable, Codable, Identifiable {
    case visible
    case hidden
    case alwaysHidden

    var id: String { rawValue }
    var title: String {
        switch self {
        case .visible: "Visible"
        case .hidden: "Hidden"
        case .alwaysHidden: "Always Hidden"
        }
    }
}

enum IceRehideStrategy: String, CaseIterable, Codable, Identifiable {
    case smart
    case timed
    case focusedApp

    var id: String { rawValue }
}

enum IceHotkeyAction: String, CaseIterable, Codable, Identifiable {
    case toggleHidden
    case toggleAlwaysHidden
    case search

    var id: String { rawValue }
    var title: String {
        switch self {
        case .toggleHidden: "Toggle hidden items"
        case .toggleAlwaysHidden: "Toggle always-hidden items"
        case .search: "Search menu bar items"
        }
    }
}

struct IceHotkey: Codable, Equatable {
    var keyCode: UInt16?
    var modifiers: UInt

    static let none = IceHotkey(keyCode: nil, modifiers: 0)
}

/// Window ID changes when an extra restarts. Namespace/title/PID gives a useful
/// persisted intent without pretending a window number is durable.
struct IceItemIdentity: Codable, Hashable, Identifiable {
    let namespace: String
    let title: String
    let ownerPID: Int32?

    var id: String {
        let pid = ownerPID.map { String($0) } ?? ""
        return "\(namespace)|\(title)|\(pid)"
    }
}

struct IceMenuBarItem: Codable, Hashable, Identifiable {
    let identity: IceItemIdentity
    let windowID: UInt32
    let displayName: String
    let frameX: Double
    let frameY: Double
    let frameWidth: Double
    let frameHeight: Double

    var id: String { identity.id }
}

enum IceItemClassifier {
    static func ordered(_ items: [IceMenuBarItem]) -> [IceMenuBarItem] {
        items.sorted { ($0.frameX, $0.identity.id) < ($1.frameX, $1.identity.id) }
    }

    static func sectioned(_ items: [IceMenuBarItem], configuration: IceConfiguration) -> [IceSection: [IceMenuBarItem]] {
        Dictionary(grouping: ordered(items), by: { configuration.section(for: $0.identity) })
    }
}

struct IceSectionStateMachine: Equatable {
    private(set) var shown: IceSection?

    mutating func reveal(_ section: IceSection, configuration: IceConfiguration) {
        guard section != .alwaysHidden || configuration.enableAlwaysHidden else { return }
        shown = section
    }

    mutating func rehide() { shown = nil }

    func shouldRehide(configuration: IceConfiguration) -> Bool {
        guard let shown else { return false }
        return configuration.autoRehide && shown != .alwaysHidden && configuration.rehideStrategy != .focusedApp
    }
}

enum IceStartupGate {
    static func state(enabled: Bool, accessibilityGranted: Bool, standaloneIceRunning: Bool, itemCount: Int) -> IceRuntimeState {
        guard enabled else { return .stopped }
        guard accessibilityGranted else { return .waitingForAccessibility }
        guard !standaloneIceRunning else { return .waitingForStandaloneIce }
        return .running(itemCount: itemCount)
    }
}

struct IceConfiguration: Codable, Equatable {
    static let currentVersion = 2

    var version: Int = currentVersion
    var enabled = true
    var showControlItem = true
    var showOnClick = true
    var showOnHover = false
    var hoverDelay = 0.2
    var showOnScroll = true
    var autoRehide = true
    var rehideStrategy: IceRehideStrategy = .smart
    var rehideInterval = 15.0
    var spacingOffset = 0.0
    var enableAlwaysHidden = false
    var canToggleAlwaysHidden = true
    /// Divider icons are controls, not decoration. New and upgraded Boring
    /// installs show them so users have a visible place to arrange extras.
    var showSectionDividers = true
    var showAllSectionsOnDrag = true
    var hideApplicationMenus = true
    var appearanceEnabled = false
    var appearanceOpacity = 0.0
    var appearanceDark = true
    var assignments: [String: IceSection] = [:]
    var hotkeys: [IceHotkeyAction: IceHotkey] = Dictionary(
        uniqueKeysWithValues: IceHotkeyAction.allCases.map { ($0, .none) })

    mutating func sanitize() {
        // Version 1 used an invisible oversized spacer as both divider and
        // hider. Upgrade it to visible divider controls. Imports created at
        // version 2 retain a standalone Ice choice of hidden dividers.
        if version < 2 { showSectionDividers = true }
        version = Self.currentVersion
        hoverDelay = min(max(hoverDelay, 0), 3)
        rehideInterval = min(max(rehideInterval, 1), 300)
        spacingOffset = min(max(spacingOffset, -8), 16)
        appearanceOpacity = min(max(appearanceOpacity, 0), 1)
        hotkeys = hotkeys.filter { IceHotkeyAction.allCases.contains($0.key) }
    }

    func section(for item: IceItemIdentity) -> IceSection {
        assignments[item.id] ?? .visible
    }
}

enum IceRuntimeState: Equatable {
    case stopped
    case waitingForAccessibility
    case waitingForStandaloneIce
    case running(itemCount: Int)
    case showing(IceSection)
    case failed(String)

    var summary: String {
        switch self {
        case .stopped: "Stopped"
        case .waitingForAccessibility: "Needs Accessibility access"
        case .waitingForStandaloneIce: "Waiting for standalone Ice to quit"
        case let .running(itemCount): "Running · \(itemCount) items"
        case let .showing(section): "Showing \(section.title.lowercased()) items"
        case let .failed(message): message
        }
    }
}

protocol IceDefaultsStore {
    func data(forKey key: String) -> Data?
    func set(_ value: Any?, forKey key: String)
    func object(forKey key: String) -> Any?
    func persistentDomain(forName name: String) -> [String: Any]?
}

extension UserDefaults: IceDefaultsStore { }

enum IceConfigurationStore {
    static let configurationKey = "com.theboringteam.boringnotch.ice.configuration.v1"
    static let migrationKey = "com.theboringteam.boringnotch.ice.migration.v1"

    static func load(from defaults: IceDefaultsStore = UserDefaults.standard) -> IceConfiguration {
        guard let data = defaults.data(forKey: configurationKey),
              var configuration = try? JSONDecoder().decode(IceConfiguration.self, from: data) else {
            return IceConfiguration()
        }
        configuration.sanitize()
        return configuration
    }

    static func save(_ input: IceConfiguration, to defaults: IceDefaultsStore = UserDefaults.standard) {
        var configuration = input
        configuration.sanitize()
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        defaults.set(data, forKey: configurationKey)
    }
}

/// One-way, read-only import from standalone Ice. Never writes its domain.
enum IceMigration {
    static let standaloneDomain = "com.jordanbaird.Ice"

    @discardableResult
    static func migrateIfNeeded(defaults: IceDefaultsStore = UserDefaults.standard) -> Bool {
        guard defaults.object(forKey: IceConfigurationStore.migrationKey) == nil else { return false }
        guard defaults.data(forKey: IceConfigurationStore.configurationKey) == nil else {
            defaults.set("skipped-existing-boring-configuration", forKey: IceConfigurationStore.migrationKey)
            return false
        }
        guard let source = defaults.persistentDomain(forName: standaloneDomain) else {
            defaults.set("no-standalone-configuration", forKey: IceConfigurationStore.migrationKey)
            return false
        }

        var configuration = IceConfiguration()
        if let value = source["ShowIceIcon"] as? Bool { configuration.showControlItem = value }
        if let value = source["ShowOnClick"] as? Bool { configuration.showOnClick = value }
        if let value = source["ShowOnHover"] as? Bool { configuration.showOnHover = value }
        if let value = source["ShowOnScroll"] as? Bool { configuration.showOnScroll = value }
        if let value = source["AutoRehide"] as? Bool { configuration.autoRehide = value }
        if let value = source["RehideInterval"] as? Double { configuration.rehideInterval = value }
        if let value = source["ItemSpacingOffset"] as? Double { configuration.spacingOffset = value }
        if let value = source["EnableAlwaysHiddenSection"] as? Bool { configuration.enableAlwaysHidden = value }
        if let value = source["CanToggleAlwaysHiddenSection"] as? Bool { configuration.canToggleAlwaysHidden = value }
        if let value = source["ShowSectionDividers"] as? Bool { configuration.showSectionDividers = value }
        if let value = source["ShowAllSectionsOnUserDrag"] as? Bool { configuration.showAllSectionsOnDrag = value }
        if let value = source["HideApplicationMenus"] as? Bool { configuration.hideApplicationMenus = value }
        if let raw = source["RehideStrategy"] as? String,
           let strategy = IceRehideStrategy(rawValue: raw) { configuration.rehideStrategy = strategy }
        if let value = source["ShowOnHoverDelay"] as? Double { configuration.hoverDelay = value }
        configuration.sanitize()
        IceConfigurationStore.save(configuration, to: defaults)
        // Commit only after Boring configuration encodes and stores successfully.
        defaults.set("imported-\(Self.standaloneDomain)", forKey: IceConfigurationStore.migrationKey)
        return true
    }
}
