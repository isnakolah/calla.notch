import CryptoKit
import Foundation
import Security

/// A device-local key lineage used only by retained Live Coding interviews.
/// It is deliberately separate from Call, Quiz and Tutor history keys.
enum CodeHistoryKey {
    private static let service = "org.calla.notch.code-history"
    private static let account = "candidate-shadow-v1"

    private static var localURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("calla.notch/Calla/code", isDirectory: true)
            .appendingPathComponent("candidate-shadow-v1.key")
    }

    static func loadOrCreate() throws -> SymmetricKey {
        if let data = try? Data(contentsOf: localURL), data.count == 32 {
            return SymmetricKey(data: data)
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var value: CFTypeRef?
        var material: Data
        if SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
           let stored = value as? Data, stored.count == 32 {
            material = stored
        } else {
            material = Data(count: 32)
            let status = material.withUnsafeMutableBytes {
                SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
            }
            guard status == errSecSuccess else { throw CocoaError(.fileWriteUnknown) }
            let add: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecValueData as String: material,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            ]
            _ = SecItemAdd(add as CFDictionary, nil)
        }
        try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try material.write(to: localURL, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: localURL.path)
        return SymmetricKey(data: material)
    }
}
