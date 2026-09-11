import Foundation
import XCTest
@testable import IceConfiguration

final class IceConfigurationTests: XCTestCase {
    func testConfigurationClampsUnsafeValues() {
        var configuration = IceConfiguration()
        configuration.hoverDelay = 99
        configuration.rehideInterval = -2
        configuration.spacingOffset = 99
        configuration.appearanceOpacity = -1
        configuration.sanitize()

        XCTAssertEqual(configuration.hoverDelay, 3)
        XCTAssertEqual(configuration.rehideInterval, 1)
        XCTAssertEqual(configuration.spacingOffset, 16)
        XCTAssertEqual(configuration.appearanceOpacity, 0)
    }

    func testVersionOneConfigurationUpgradesToVisibleDividerDots() {
        var configuration = IceConfiguration()
        configuration.version = 1
        configuration.showSectionDividers = false
        configuration.sanitize()

        XCTAssertEqual(configuration.version, IceConfiguration.currentVersion)
        XCTAssertTrue(configuration.showSectionDividers)
    }

    func testSectionDefaultsVisibleAndPersistsIdentityAssignment() {
        let item = IceItemIdentity(namespace: "com.example.extra", title: "Extra", ownerPID: 42)
        var configuration = IceConfiguration()
        XCTAssertEqual(configuration.section(for: item), .visible)
        configuration.assignments[item.id] = .alwaysHidden
        XCTAssertEqual(configuration.section(for: item), .alwaysHidden)
    }

    func testClassifierKeepsMenuBarOrderAndSectionAssignments() {
        let first = item("one", x: 40)
        let second = item("two", x: 8)
        var configuration = IceConfiguration()
        configuration.assignments[first.identity.id] = .hidden

        XCTAssertEqual(IceItemClassifier.ordered([first, second]).map(\.displayName), ["two", "one"])
        XCTAssertEqual(IceItemClassifier.sectioned([first, second], configuration: configuration)[.hidden], [first])
        XCTAssertEqual(IceItemClassifier.sectioned([first, second], configuration: configuration)[.visible], [second])
    }

    func testRevealAndRehideState() {
        var configuration = IceConfiguration()
        configuration.rehideStrategy = .timed
        var state = IceSectionStateMachine()
        state.reveal(.hidden, configuration: configuration)
        XCTAssertEqual(state.shown, .hidden)
        XCTAssertTrue(state.shouldRehide(configuration: configuration))
        state.rehide()
        XCTAssertNil(state.shown)

        state.reveal(.alwaysHidden, configuration: configuration)
        XCTAssertNil(state.shown)
        configuration.enableAlwaysHidden = true
        state.reveal(.alwaysHidden, configuration: configuration)
        XCTAssertEqual(state.shown, .alwaysHidden)
        XCTAssertFalse(state.shouldRehide(configuration: configuration))
    }

    func testStartupGateBlocksWithoutAccessibilityAndStandaloneIce() {
        XCTAssertEqual(IceStartupGate.state(enabled: true, accessibilityGranted: false, standaloneIceRunning: false, itemCount: 1), .waitingForAccessibility)
        XCTAssertEqual(IceStartupGate.state(enabled: true, accessibilityGranted: true, standaloneIceRunning: true, itemCount: 1), .waitingForStandaloneIce)
        XCTAssertEqual(IceStartupGate.state(enabled: false, accessibilityGranted: true, standaloneIceRunning: false, itemCount: 1), .stopped)
    }

    func testHotkeyRetainsKeyCodeAndModifiers() {
        let hotkey = IceHotkey(keyCode: 12, modifiers: 1 << 20)
        XCTAssertEqual(hotkey.keyCode, 12)
        XCTAssertEqual(hotkey.modifiers, 1 << 20)
    }

    func testMigrationImportsKnownValuesWithoutWritingSourceDomain() {
        let store = MemoryDefaults(domains: [IceMigration.standaloneDomain: [
            "ShowOnHover": true,
            "RehideInterval": 42.0,
            "EnableAlwaysHiddenSection": true,
            "RehideStrategy": "timed"
        ]])

        XCTAssertTrue(IceMigration.migrateIfNeeded(defaults: store))
        let configuration = IceConfigurationStore.load(from: store)
        XCTAssertTrue(configuration.showOnHover)
        XCTAssertEqual(configuration.rehideInterval, 42)
        XCTAssertTrue(configuration.enableAlwaysHidden)
        XCTAssertEqual(configuration.rehideStrategy, .timed)
        XCTAssertEqual(store.writes.filter { $0.key.hasPrefix(IceMigration.standaloneDomain) }.count, 0)
    }

    func testMigrationPreservesExistingBoringConfiguration() {
        let store = MemoryDefaults(domains: [IceMigration.standaloneDomain: ["ShowOnHover": true]])
        var existing = IceConfiguration()
        existing.showOnHover = false
        IceConfigurationStore.save(existing, to: store)

        XCTAssertFalse(IceMigration.migrateIfNeeded(defaults: store))
        XCTAssertFalse(IceConfigurationStore.load(from: store).showOnHover)
    }
}

private func item(_ name: String, x: Double) -> IceMenuBarItem {
    let identity = IceItemIdentity(namespace: "com.example.\(name)", title: name, ownerPID: 1)
    return IceMenuBarItem(identity: identity, windowID: 1, displayName: name,
                           frameX: x, frameY: 0, frameWidth: 10, frameHeight: 10)
}

private final class MemoryDefaults: IceDefaultsStore {
    var values: [String: Any] = [:]
    let domains: [String: [String: Any]]
    private(set) var writes: [(key: String, value: Any?)] = []

    init(domains: [String: [String: Any]]) { self.domains = domains }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func set(_ value: Any?, forKey key: String) { values[key] = value; writes.append((key, value)) }
    func object(forKey key: String) -> Any? { values[key] }
    func persistentDomain(forName name: String) -> [String: Any]? { domains[name] }
}
