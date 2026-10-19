import CryptoKit
import Darwin
import Foundation
import Security

public protocol BrandMigrationKeychain {
    func read(service: String, account: String) throws -> Data?
    func write(_ data: Data, service: String, account: String) throws
}

public struct SystemBrandMigrationKeychain: BrandMigrationKeychain {
    public init() {}
    public func read(service: String, account: String) throws -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw BrandMigration.Failure("Unlock Keychain and allow access to the existing app's credentials, then retry (\(status)).")
        }
        return data
    }
    public func write(_ data: Data, service: String, account: String) throws {
        var item: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        // Bind access to this Engine and its owning app. The Engine joins the
        // app's security session so Keychain can request approval when needed.
        var trusted: [SecTrustedApplication] = []
        var current: SecTrustedApplication?
        let trustStatus = SecTrustedApplicationCreateFromPath(nil, &current)
        guard trustStatus == errSecSuccess, let current else {
            throw BrandMigration.Failure("Could not prepare migrated credential access (\(trustStatus)).")
        }
        trusted.append(current)
        let appExecutable = CallaBrand.installedApp.appendingPathComponent("Contents/MacOS/callaNotch").path
        if FileManager.default.isExecutableFile(atPath: appExecutable) {
            var application: SecTrustedApplication?
            if SecTrustedApplicationCreateFromPath(appExecutable, &application) == errSecSuccess, let application {
                trusted.append(application)
            }
        }
        var access: SecAccess?
        let accessStatus = SecAccessCreate("calla.notch migrated credential" as CFString, trusted as CFArray, &access)
        guard accessStatus == errSecSuccess, let access else {
            throw BrandMigration.Failure("Could not preserve migrated credential access (\(accessStatus)).")
        }
        item[kSecAttrAccess as String] = access
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw BrandMigration.Failure("Could not preserve a Keychain credential (\(status)). Existing data has been kept; retry after unlocking Keychain.")
        }
    }
}

/// Runs in the unsandboxed Engine before either app initializes settings or stores.
/// Originals are the rollback copies: no legacy file or Keychain item is deleted.
public struct BrandMigration {
    public struct Failure: LocalizedError {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    private let home: URL
    private let keychain: any BrandMigrationKeychain
    private let fm = FileManager.default
    public init(home: URL = CallaBrand.userHome,
                keychain: any BrandMigrationKeychain = SystemBrandMigrationKeychain()) {
        self.home = home; self.keychain = keychain
    }
    private var oldSupport: URL { home.appendingPathComponent("Library/Application Support/" + LegacyBrand.supportName) }
    private var support: URL { CallaBrand.support(in: home) }
    private func container(_ identity: String) -> URL {
        home.appendingPathComponent("Library/Containers/" + identity + "/Data")
    }
    private var mappings: [(URL, URL)] {
        [(oldSupport, support),
         (container(LegacyBrand.bundleIdentifier).appendingPathComponent("Library/Application Support/" + LegacyBrand.supportName),
          container(CallaBrand.bundleIdentifier).appendingPathComponent("Library/Application Support/" + CallaBrand.name))]
    }

    /// Retire only our previous runtime jobs and setup symlink after a complete
    /// installed bundle and a successful migration exist. Originals stay in
    /// MigrationBackups, and unrelated command links are never replaced.
    public func finalizeInstalledIdentity() throws {
        let app = CallaBrand.installedApp
        let helper = app.appendingPathComponent("Contents/Helpers/" + CallaBrand.setupCommand)
        guard fm.fileExists(atPath: support.appendingPathComponent(".brand-migration-v1.plist").path),
              fm.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/callaNotch").path) else { return }
        let backups = support.appendingPathComponent("MigrationBackups/LaunchAgents")
        for (index, label) in LegacyBrand.runtimeLabels.enumerated() {
            let original = home.appendingPathComponent("Library/LaunchAgents/" + label + ".plist")
            if fm.fileExists(atPath: original.path) {
                let data = try Data(contentsOf: original)
                guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      plist["Label"] as? String == label else { continue }
                try privateDirectory(backups)
                let backup = backups.appendingPathComponent("runtime-\(index).plist")
                if try exists(backup), try Data(contentsOf: backup) != data { throw conflict(backup) }
                if try !exists(backup) { try data.write(to: backup, options: .atomic) }
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
                for command in ["disable", "bootout"] {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                    process.arguments = [command, "gui/\(getuid())/" + label]
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice
                    try process.run(); process.waitUntilExit()
                    // An unloaded job is normal; disabling also prevents a
                    // KeepAlive registration from restarting the old process.
                }
                try fm.removeItem(at: original)
            }
        }
        let directory = home.appendingPathComponent(".local/bin")
        let oldCLI = directory.appendingPathComponent(LegacyBrand.cli)
        let newCLI = directory.appendingPathComponent(CallaBrand.setupCommand)
        let expected = LegacyBrand.installedApp + "/Contents/Helpers/" + LegacyBrand.cli
        if fm.isExecutableFile(atPath: helper.path),
           (try? fm.destinationOfSymbolicLink(atPath: oldCLI.path)) == expected {
            if try exists(newCLI) {
                guard (try? fm.destinationOfSymbolicLink(atPath: newCLI.path)) == helper.path else {
                    throw Failure("An unrelated calla-notch command already exists. It has been preserved; resolve the command conflict before retrying.")
                }
            } else { try fm.createSymbolicLink(at: newCLI, withDestinationURL: helper) }
            try fm.removeItem(at: oldCLI)
        }
    }

    /// A binary plist carries preferences without losing Data, Date or bookmark values.
    public func run(includePreferences: Bool = true) throws -> Data {
        try privateDirectory(support)
        let descriptor = open(support.appendingPathComponent(".brand-migration.lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw Failure("Could not lock app data for migration. Check its permissions and retry.") }
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw Failure("Could not acquire the migration lock. Retry after closing other copies of the app.") }
        let receipt = support.appendingPathComponent(".brand-migration-v1.plist")
        if try exists(receipt) {
            let data = try Data(contentsOf: receipt)
            guard let value = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  value["version"] as? Int == 1 else { throw Failure("The migration receipt is invalid. Restore it from your backup before continuing.") }
            try finishSandboxImport()
            var response: [String: Any] = ["version": 1, "importedLegacyData": value["importedLegacyData"] as? Bool ?? false]
            let preferences = includePreferences ? try readPreferences() : [:]
            response["preferences"] = preferences
            if !preferences.isEmpty { response["importedLegacyData"] = true }
            return try PropertyListSerialization.data(fromPropertyList: response, format: .binary, options: 0)
        }
        let preferences = includePreferences ? try readPreferences() : [:]
        var operations = mappings
        // Only macOS creates managed app containers. A deployment CLI may run
        // before the new app's first launch, so stage its sandbox data until
        // the new process has caused the system to create its own container.
        if try !exists(container(CallaBrand.bundleIdentifier)) {
            operations[1].1 = support.appendingPathComponent("MigrationStaging/Sandbox")
        }
        // Preflight the whole tree before making any copies. On a retry, exact
        // copies from the interrupted run compare equal and are reused.
        for (source, destination) in operations { try preflight(source, destination) }
        try privateDirectory(support)
        for (source, destination) in operations { try copyTree(source, destination) }
        try migrateKey(suffix: ".quiz-history", account: "capture-master-v1",
                       local: "Calla/quiz/capture-master-v1.key", encryptedDirectory: "Calla/quiz")
        try migrateKey(suffix: ".code-history", account: "candidate-shadow-v1",
                       local: "Calla/code/candidate-shadow-v1.key", encryptedDirectory: "Calla/coding")
        try migrateKey(suffix: ".kdeconnect.identity", account: "tls-p12", local: nil, encryptedDirectory: nil)
        let imported = try mappings.contains { try exists($0.0) } || !preferences.isEmpty
        let result: [String: Any] = ["version": 1, "importedLegacyData": imported]
        let data = try PropertyListSerialization.data(fromPropertyList: result, format: .binary, options: 0)
        try data.write(to: receipt, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receipt.path)
        try finishSandboxImport()
        // Preferences may contain private values and bookmark capabilities.
        // Send them over XPC; never persist a duplicate in the global receipt.
        var response = result
        response["preferences"] = preferences
        return try PropertyListSerialization.data(fromPropertyList: response, format: .binary, options: 0)
    }

    private func finishSandboxImport() throws {
        let staged = support.appendingPathComponent("MigrationStaging/Sandbox")
        let complete = support.appendingPathComponent(".sandbox-migration-v1")
        guard try !exists(complete), try exists(staged), try exists(container(CallaBrand.bundleIdentifier)) else { return }
        let destination = mappings[1].1
        try preflight(staged, destination)
        try copyTree(staged, destination)
        try Data().write(to: complete, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: complete.path)
    }

    private func readPreferences() throws -> [String: Any] {
        var result: [String: Any] = [:]
        for base in [home, container(LegacyBrand.bundleIdentifier)] {
            let file = base.appendingPathComponent("Library/Preferences/" + LegacyBrand.bundleIdentifier + ".plist")
            guard try exists(file) else { continue }
            guard let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any] else {
                throw Failure("Could not read existing app preferences. The original preference file has been preserved.")
            }
            result.merge(value) { _, sandboxed in sandboxed }
        }
        if let value = result.removeValue(forKey: LegacyBrand.shelfPreference) { result["callaShelf"] = value }
        return remap(result) as? [String: Any] ?? result
    }

    /// Change only app-owned absolute paths, never transcripts, notes or bookmarks.
    private func remap(_ value: Any) -> Any {
        if let text = value as? String {
            for (source, destination) in mappings where text == source.path || text.hasPrefix(source.path + "/") {
                return destination.path + text.dropFirst(source.path.count)
            }
            return text
        }
        if let values = value as? [String: Any] { return values.mapValues(remap) }
        if let values = value as? [Any] { return values.map(remap) }
        return value
    }
    private func type(_ file: URL) throws -> FileAttributeType? {
        (try fm.attributesOfItem(atPath: file.path))[.type] as? FileAttributeType
    }
    private func exists(_ file: URL) throws -> Bool {
        var metadata = stat()
        if lstat(file.path, &metadata) == 0 { return true }
        let code = errno
        if code == ENOENT || code == ENOTDIR { return false }
        throw Failure("Could not inspect existing data at \(file.path) (\(code)). Allow access to the previous app's data and retry; migration has not treated inaccessible data as a fresh install.")
    }
    private func skip(_ file: URL, kind: FileAttributeType?) -> Bool {
        kind == .typeSocket || file.pathExtension == "sock" || file.pathExtension == "pid"
    }
    private func preflight(_ source: URL, _ destination: URL) throws {
        guard try exists(source) else { return }
        let kind = try type(source)
        guard !skip(source, kind: kind) else { return }
        if try exists(destination) {
            guard try type(destination) == kind else { throw conflict(destination) }
            if kind == .typeRegular {
                guard try digest(source) == digest(destination) else { throw conflict(destination) }
            } else if kind == .typeSymbolicLink {
                let expected = remap(try fm.destinationOfSymbolicLink(atPath: source.path)) as! String
                guard try fm.destinationOfSymbolicLink(atPath: destination.path) == expected else { throw conflict(destination) }
            }
        }
        if kind == .typeDirectory {
            for child in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                try preflight(child, destination.appendingPathComponent(child.lastPathComponent))
            }
        }
    }
    private func copyTree(_ source: URL, _ destination: URL) throws {
        guard try exists(source) else { return }
        let kind = try type(source)
        guard !skip(source, kind: kind) else { return }
        if kind == .typeDirectory {
            try privateDirectory(destination)
            for child in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                try copyTree(child, destination.appendingPathComponent(child.lastPathComponent))
            }
        } else if try !exists(destination) {
            try privateDirectory(destination.deletingLastPathComponent())
            if kind == .typeSymbolicLink {
                try fm.createSymbolicLink(atPath: destination.path,
                    withDestinationPath: remap(try fm.destinationOfSymbolicLink(atPath: source.path)) as! String)
            } else if kind == .typeRegular {
                // APFS clones keep multi-gigabyte model migration cheap. Stage
                // every file so an interruption never leaves a partial target.
                let temporary = destination.deletingLastPathComponent().appendingPathComponent(".migration-" + UUID().uuidString)
                defer { try? fm.removeItem(at: temporary) }
                if copyfile(source.path, temporary.path, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_CLONE)) != 0 {
                    try? fm.removeItem(at: temporary)
                    try fm.copyItem(at: source, to: temporary)
                }
                try fm.moveItem(at: temporary, to: destination)
            }
        }
    }
    private func privateDirectory(_ directory: URL) throws {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
    private func digest(_ file: URL) throws -> SHA256.Digest {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize()
    }
    private func conflict(_ path: URL) -> Failure {
        Failure("Migration found different existing data at \(path.path). Both copies have been preserved. Resolve the conflict or restore a backup, then retry.")
    }
    private func migrateKey(suffix: String, account: String, local: String?, encryptedDirectory: String?) throws {
        let oldService = LegacyBrand.bundleIdentifier + suffix
        let service = CallaBrand.bundleIdentifier + suffix
        let localURL = local.map { support.appendingPathComponent($0) }
        let originalLocalURL = local.map { oldSupport.appendingPathComponent($0) }
        let material: Data?
        if let originalLocalURL, try exists(originalLocalURL) {
            let data = try Data(contentsOf: originalLocalURL)
            guard data.count == 32 else { throw Failure("An existing history encryption key is invalid. Restore the original key before continuing.") }
            material = data
        } else {
            material = try keychain.read(service: oldService, account: account)
        }
        guard let material else {
            if let encryptedDirectory {
                let directory = oldSupport.appendingPathComponent(encryptedDirectory)
                let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: nil)
                while let file = enumerator?.nextObject() as? URL {
                    if ["aesgcm", "sealed"].contains(file.pathExtension) {
                        throw Failure("Existing encrypted history has no accessible key. Restore its key or unlock Keychain before retrying; no replacement key has been created.")
                    }
                }
            }
            return
        }
        if local != nil, material.count != 32 { throw Failure("The existing history Keychain key is invalid.") }
        if let localURL, try exists(localURL), try Data(contentsOf: localURL) != material {
            throw Failure("The destination history key differs. Both keys have been kept; resolve the conflict before continuing.")
        }
        if let existing = try keychain.read(service: service, account: account) {
            guard existing == material else { throw Failure("The destination Keychain credential differs. Both credentials have been kept; resolve the conflict before continuing.") }
        } else { try keychain.write(material, service: service, account: account) }
        if let localURL, try !exists(localURL) {
            try privateDirectory(localURL.deletingLastPathComponent())
            try material.write(to: localURL, options: .atomic)
        }
        if let localURL { try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: localURL.path) }
    }
}
