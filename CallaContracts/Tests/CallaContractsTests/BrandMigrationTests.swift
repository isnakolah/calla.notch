import CryptoKit
import Foundation
import XCTest
@testable import CallaContracts

final class BrandMigrationTests: XCTestCase {
    private final class Keychain: BrandMigrationKeychain {
        var values: [String: Data] = [:]
        var denied = false
        func read(service: String, account: String) throws -> Data? {
            if denied { throw BrandMigration.Failure("Keychain is locked") }
            return values[service + "/" + account]
        }
        func write(_ data: Data, service: String, account: String) throws { values[service + "/" + account] = data }
    }
    private var home: URL!
    private var keychain: Keychain!
    private var old: URL { home.appendingPathComponent("Library/Application Support/" + LegacyBrand.supportName) }
    private var new: URL { CallaBrand.support(in: home) }
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        keychain = Keychain()
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: home) }
    private func write(_ data: Data, to path: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: path)
    }
    private func migrate() throws -> [String: Any] {
        let data = try BrandMigration(home: home, keychain: keychain).run()
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }
    func testFreshInstallDoesNotInventKeys() throws {
        XCTAssertEqual(try migrate()["importedLegacyData"] as? Bool, false)
        XCTAssertTrue(keychain.values.isEmpty)
    }
    func testCopiesEncryptedHistoryAndExactKeyWithoutChangingOriginals() throws {
        let material = Data(repeating: 42, count: 32)
        let plaintext = Data("retained history".utf8)
        let sealed = try XCTUnwrap(AES.GCM.seal(plaintext, using: SymmetricKey(data: material)).combined)
        try write(material, to: old.appendingPathComponent("Calla/quiz/capture-master-v1.key"))
        try write(sealed, to: old.appendingPathComponent("Calla/quiz/capture.aesgcm"))
        _ = try migrate()
        let copied = try Data(contentsOf: new.appendingPathComponent("Calla/quiz/capture.aesgcm"))
        let key = try Data(contentsOf: new.appendingPathComponent("Calla/quiz/capture-master-v1.key"))
        XCTAssertEqual(try AES.GCM.open(AES.GCM.SealedBox(combined: copied), using: SymmetricKey(data: key)), plaintext)
        XCTAssertEqual(try Data(contentsOf: old.appendingPathComponent("Calla/quiz/capture.aesgcm")), sealed)
        XCTAssertEqual(keychain.values[CallaBrand.bundleIdentifier + ".quiz-history/capture-master-v1"], material)
        let attributes = try FileManager.default.attributesOfItem(atPath: new.appendingPathComponent("Calla/quiz/capture-master-v1.key").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testMissingKeyStopsWithoutCreatingReceiptOrReplacementKey() throws {
        try write(Data("encrypted".utf8), to: old.appendingPathComponent("Calla/quiz/capture.aesgcm"))
        XCTAssertThrowsError(try migrate())
        XCTAssertFalse(FileManager.default.fileExists(atPath: new.appendingPathComponent(".brand-migration-v1.plist").path))
        XCTAssertTrue(keychain.values.isEmpty)
    }
    func testDestinationKeyCannotMaskMissingOriginalKey() throws {
        try write(Data("encrypted".utf8), to: old.appendingPathComponent("Calla/coding/archives/manifest.sealed"))
        try write(Data(repeating: 8, count: 32), to: new.appendingPathComponent("Calla/code/candidate-shadow-v1.key"))
        XCTAssertThrowsError(try migrate())
    }
    func testConflictsPreserveBothCopiesAndPreflightBeforeCopying() throws {
        try write(Data("original".utf8), to: old.appendingPathComponent("history.sqlite"))
        try write(Data("current".utf8), to: new.appendingPathComponent("history.sqlite"))
        try write(Data("pending".utf8), to: old.appendingPathComponent("pending.txt"))
        XCTAssertThrowsError(try migrate())
        XCTAssertEqual(try Data(contentsOf: new.appendingPathComponent("history.sqlite")), Data("current".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: new.appendingPathComponent("pending.txt").path))
    }
    func testInterruptedCopyResumesAndCompletedMigrationDoesNotReimport() throws {
        try write(Data("same".utf8), to: old.appendingPathComponent("a.txt"))
        try write(Data("same".utf8), to: new.appendingPathComponent("a.txt"))
        try write(Data("remaining".utf8), to: old.appendingPathComponent("b.txt"))
        _ = try migrate()
        try write(Data("new edits".utf8), to: new.appendingPathComponent("a.txt"))
        _ = try migrate()
        XCTAssertEqual(try Data(contentsOf: new.appendingPathComponent("a.txt")), Data("new edits".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: new.appendingPathComponent("b.txt").path))
    }
    func testLockedKeychainStopsAndRetryResumesSafely() throws {
        try write(Data("keep".utf8), to: old.appendingPathComponent("history.txt"))
        keychain.denied = true
        XCTAssertThrowsError(try migrate())
        keychain.denied = false
        _ = try migrate()
        XCTAssertEqual(try Data(contentsOf: new.appendingPathComponent("history.txt")), Data("keep".utf8))
    }
    func testKeychainOnlyHistoryKeyIsMirroredWithoutRotation() throws {
        let key = Data(repeating: 7, count: 32)
        keychain.values[LegacyBrand.bundleIdentifier + ".code-history/candidate-shadow-v1"] = key
        try write(Data("encrypted".utf8), to: old.appendingPathComponent("Calla/coding/archives/manifest.sealed"))
        _ = try migrate()
        XCTAssertEqual(try Data(contentsOf: new.appendingPathComponent("Calla/code/candidate-shadow-v1.key")), key)
    }
    func testDestinationCredentialConflictDoesNotOverwriteEitherKey() throws {
        keychain.values[LegacyBrand.bundleIdentifier + ".kdeconnect.identity/tls-p12"] = Data([1])
        keychain.values[CallaBrand.bundleIdentifier + ".kdeconnect.identity/tls-p12"] = Data([2])
        XCTAssertThrowsError(try migrate())
        XCTAssertEqual(keychain.values[CallaBrand.bundleIdentifier + ".kdeconnect.identity/tls-p12"], Data([2]))
    }
    func testPreferencesPreserveBookmarkBytesAndOnlyRemapOwnedPathPrefixes() throws {
        let bookmark = Data([0, 1, 2])
        let file = home.appendingPathComponent("Library/Containers/" + LegacyBrand.bundleIdentifier + "/Data/Library/Preferences/" + LegacyBrand.bundleIdentifier + ".plist")
        let prefs: [String: Any] = [LegacyBrand.shelfPreference: false, "bookmark": bookmark,
            "component": old.appendingPathComponent("Components/agy").path,
            "note": "My existing note"]
        try write(PropertyListSerialization.data(fromPropertyList: prefs, format: .binary, options: 0), to: file)
        let result = try XCTUnwrap(migrate()["preferences"] as? [String: Any])
        XCTAssertEqual(result["callaShelf"] as? Bool, false)
        XCTAssertEqual(result["bookmark"] as? Data, bookmark)
        XCTAssertEqual(result["component"] as? String, new.appendingPathComponent("Components/agy").path)
        XCTAssertEqual(result["note"] as? String, "My existing note")
    }
    func testPreferenceSnapshotIsNotStoredInGlobalReceipt() throws {
        let file = home.appendingPathComponent("Library/Preferences/" + LegacyBrand.bundleIdentifier + ".plist")
        try write(PropertyListSerialization.data(fromPropertyList: ["privateValue": "local-only"], format: .binary, options: 0), to: file)
        let response = try migrate()
        XCTAssertEqual((response["preferences"] as? [String: Any])?["privateValue"] as? String, "local-only")
        let data = try Data(contentsOf: new.appendingPathComponent(".brand-migration-v1.plist"))
        let receipt = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertNil(receipt["preferences"])
        // Once the app has imported settings, it no longer needs permission
        // to read the old preference container on every subsequent launch.
        try write(Data("unreadable preferences".utf8), to: file)
        XCTAssertNoThrow(try BrandMigration(home: home, keychain: keychain).run(includePreferences: false))
    }
    func testSandboxDataUsesNewSandboxLocation() throws {
        let container = home.appendingPathComponent("Library/Containers/" + CallaBrand.bundleIdentifier + "/Data")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let source = home.appendingPathComponent("Library/Containers/" + LegacyBrand.bundleIdentifier + "/Data/Library/Application Support/" + LegacyBrand.supportName + "/Shelf/items.json")
        try write(Data("[]".utf8), to: source)
        _ = try migrate()
        let destination = home.appendingPathComponent("Library/Containers/" + CallaBrand.bundleIdentifier + "/Data/Library/Application Support/calla.notch/Shelf/items.json")
        XCTAssertEqual(try Data(contentsOf: destination), Data("[]".utf8))
    }
    func testCLIMigrationWaitsForSystemCreatedSandboxAndDoesNotReimportLater() throws {
        let source = home.appendingPathComponent("Library/Containers/" + LegacyBrand.bundleIdentifier + "/Data/Library/Application Support/" + LegacyBrand.supportName + "/Shelf/items.json")
        try write(Data("[]".utf8), to: source)
        _ = try migrate()
        let container = home.appendingPathComponent("Library/Containers/" + CallaBrand.bundleIdentifier + "/Data")
        XCTAssertFalse(FileManager.default.fileExists(atPath: container.path))
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        _ = try migrate()
        let destination = container.appendingPathComponent("Library/Application Support/calla.notch/Shelf/items.json")
        XCTAssertEqual(try Data(contentsOf: destination), Data("[]".utf8))
        try write(Data("[1]".utf8), to: destination)
        _ = try migrate()
        XCTAssertEqual(try Data(contentsOf: destination), Data("[1]".utf8))
    }
    func testOwnedAbsoluteSymlinkRemapsAndExternalLinkIsPreserved() throws {
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: old.appendingPathComponent("owned").path, withDestinationPath: old.appendingPathComponent("Components/agy").path)
        try FileManager.default.createSymbolicLink(atPath: old.appendingPathComponent("external").path, withDestinationPath: "/external/user-data")
        _ = try migrate()
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: new.appendingPathComponent("owned").path), new.appendingPathComponent("Components/agy").path)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: new.appendingPathComponent("external").path), "/external/user-data")
    }
}
