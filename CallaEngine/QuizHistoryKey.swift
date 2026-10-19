import CryptoKit
import Foundation
import Security

/// Device-only key lineage dedicated to Quiz. Delete All rotates this key only;
/// Call and Tutor keys remain untouched.
enum QuizHistoryKey {
    static let service = "org.calla.notch.quiz-history"
    static let account = "capture-master-v1"

    /// XPC services cannot reliably satisfy legacy Keychain UI policy on local
    /// self-signed builds. Keep captures encrypted even when that happens: the
    /// exact same 256-bit key is mirrored into this owner-only directory. Once
    /// present, every process uses this copy first so ciphertext never flips
    /// between two key lineages as Keychain availability changes.
    private static var localKeyURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("calla.notch/Calla/quiz", isDirectory: true)
            .appendingPathComponent("capture-master-v1.key")
    }

    enum Failure: Error, LocalizedError {
        case keychain(OSStatus), bootstrap(Int32), localKey(String), invalidStoredKey
        var errorDescription: String? {
            switch self {
            case .keychain(let status): "Quiz history Keychain error \(status)"
            case .bootstrap(let status): "Quiz history key preparation failed with status \(status)"
            case .localKey(let reason): "Quiz history encryption key error: \(reason)"
            case .invalidStoredKey: "Quiz history Keychain key is invalid"
            }
        }
    }

    static func loadOrCreate(allowBootstrap: Bool = true) throws -> SymmetricKey {
        if let local = try loadLocalKey() { return SymmetricKey(data: local) }

        do {
            let material = try loadOrCreateKeychainMaterial(allowBootstrap: allowBootstrap)
            try persistLocalKey(material)
            return SymmetricKey(data: material)
        } catch {
            // Encryption is mandatory; Keychain is not. A local random key in
            // a mode-0700 directory and mode-0600 file keeps screenshots
            // encrypted at rest without asking an XPC service to show UI.
            let material = try createLocalKey()
            return SymmetricKey(data: material)
        }
    }

    private static func loadOrCreateKeychainMaterial(allowBootstrap: Bool) throws -> Data {
        let query = baseQuery.merging([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]) { _, new in new }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess {
            guard let data = result as? Data, data.count == 32 else { throw Failure.invalidStoredKey }
            return data
        }
        guard status == errSecItemNotFound else { throw Failure.keychain(status) }
        do {
            return try createKeychainMaterial()
        } catch Failure.keychain(let keychainStatus)
            where allowBootstrap && keychainStatus == errSecInteractionNotAllowed {
            try prepareOutsideXPC()
            guard let local = try loadLocalKey() else { throw Failure.bootstrap(-1) }
            return local
        }
    }

    static func rotate() throws -> SymmetricKey {
        // Delete All must work even when Keychain is the unavailable component.
        // Local key is authoritative once created, so removing it guarantees a
        // new encryption lineage. Keychain cleanup remains best effort.
        _ = SecItemDelete(baseQuery as CFDictionary)
        if FileManager.default.fileExists(atPath: localKeyURL.path) {
            do { try FileManager.default.removeItem(at: localKeyURL) }
            catch { throw Failure.localKey(error.localizedDescription) }
        }
        return try loadOrCreate()
    }

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func createKeychainMaterial() throws -> Data {
        var material = Data(count: 32)
        let random = material.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
        }
        guard random == errSecSuccess else { throw Failure.keychain(random) }
        var add = baseQuery
        add[kSecValueData as String] = material
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        // Local builds use persistent self-signed identity, without Apple Team
        // access-group entitlement. Default legacy-Keychain ACL construction
        // attempts unavailable UI from XPC. Bind item explicitly to current
        // signed Engine instead: device-only key remains non-exporting and
        // Engine can reopen it without any prompt.
        var trustedApplication: SecTrustedApplication?
        let trustedStatus = SecTrustedApplicationCreateFromPath(nil, &trustedApplication)
        guard trustedStatus == errSecSuccess, let trustedApplication else {
            throw Failure.keychain(trustedStatus)
        }
        var access: SecAccess?
        let accessStatus = SecAccessCreate(
            "Calla Quiz capture key" as CFString,
            [trustedApplication] as CFArray,
            &access)
        guard accessStatus == errSecSuccess, let access else {
            throw Failure.keychain(accessStatus)
        }
        add[kSecAttrAccess as String] = access
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecSuccess { return material }
        if status == errSecDuplicateItem {
            return try loadOrCreateKeychainMaterial(allowBootstrap: false)
        }
        throw Failure.keychain(status)
    }

    private static func loadLocalKey() throws -> Data? {
        guard FileManager.default.fileExists(atPath: localKeyURL.path) else { return nil }
        do {
            let material = try Data(contentsOf: localKeyURL, options: .mappedIfSafe)
            guard material.count == 32 else { throw Failure.invalidStoredKey }
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                  ofItemAtPath: localKeyURL.path)
            return material
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.localKey(error.localizedDescription)
        }
    }

    private static func createLocalKey() throws -> Data {
        var material = Data(count: 32)
        let random = material.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
        }
        guard random == errSecSuccess else { throw Failure.keychain(random) }
        try persistLocalKey(material)
        return try loadLocalKey() ?? material
    }

    private static func persistLocalKey(_ material: Data) throws {
        guard material.count == 32 else { throw Failure.invalidStoredKey }
        let manager = FileManager.default
        let directory = localKeyURL.deletingLastPathComponent()
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            if manager.fileExists(atPath: localKeyURL.path) {
                guard try loadLocalKey() != nil else { throw Failure.invalidStoredKey }
                return
            }
            let temporary = directory.appendingPathComponent(".capture-key-\(UUID().uuidString).tmp")
            do {
                try material.write(to: temporary, options: .withoutOverwriting)
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
                try manager.moveItem(at: temporary, to: localKeyURL)
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: localKeyURL.path)
            } catch {
                try? manager.removeItem(at: temporary)
                if manager.fileExists(atPath: localKeyURL.path), try loadLocalKey() != nil { return }
                throw error
            }
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.localKey(error.localizedDescription)
        }
    }

    /// XPC service cannot present legacy Keychain ACL UI. Same signed Engine
    /// executable, launched as short-lived ordinary process, can create exact
    /// ACL without UI; XPC instance then reopens item under same requirement.
    private static func prepareOutsideXPC() throws {
        guard let executable = Bundle.main.executableURL else { throw Failure.bootstrap(-1) }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--prepare-quiz-key"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw Failure.bootstrap(process.terminationStatus)
        }
    }
}
