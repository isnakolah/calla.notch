import CallaContracts
import CryptoKit
import Foundation

/// Encrypts every retained shadow file separately, then encrypts the index that
/// contains paths, symlink targets, cards, ledger and folder capability.  The
/// archive directory therefore exposes only opaque blob names and a session ID.
struct CodingSessionVault {
    struct Record: Codable {
        var configuration: CodingSessionConfiguration
        var snapshot: CodingSessionSnapshot
        var events: [CodingEvent]
        var preflight: CodingFolderPreflight
        var bookmark: Data
        var startedAt: Date
        var endedAt: Date
        var entries: [Entry]
    }

    struct Entry: Codable {
        enum Kind: String, Codable { case file, directory, symlink }
        var relativePath: String
        var kind: Kind
        var blob: String? = nil
        var symlinkTarget: String? = nil
    }

    let keyProvider: @Sendable () throws -> SymmetricKey
    let root: URL
    let fileManager: FileManager

    init(keyProvider: @escaping @Sendable () throws -> SymmetricKey = { try CodeHistoryKey.loadOrCreate() },
         root: URL, fileManager: FileManager = .default) {
        self.keyProvider = keyProvider
        self.root = root; self.fileManager = fileManager
    }

    func seal(active: URL, configuration: CodingSessionConfiguration,
              snapshot: CodingSessionSnapshot, events: [CodingEvent],
              preflight: CodingFolderPreflight, bookmark: Data,
              startedAt: Date) throws {
        let key = try keyProvider()
        let archiveRoot = root.appendingPathComponent("archives", isDirectory: true)
        let temporary = archiveRoot.appendingPathComponent(".\(configuration.sessionID).tmp", isDirectory: true)
        let destination = archiveRoot.appendingPathComponent(configuration.sessionID, isDirectory: true)
        if fileManager.fileExists(atPath: temporary.path) { try fileManager.removeItem(at: temporary) }
        try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        var entries: [Entry] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        let enumerator = fileManager.enumerator(at: active, includingPropertiesForKeys: keys,
                                                options: [], errorHandler: { _, _ in false })
        while let url = enumerator?.nextObject() as? URL {
            let relative = String(url.path.dropFirst(active.path.count + 1))
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                entries.append(.init(relativePath: relative, kind: .symlink,
                                     symlinkTarget: try fileManager.destinationOfSymbolicLink(atPath: url.path)))
            } else if values.isDirectory == true {
                entries.append(.init(relativePath: relative, kind: .directory))
            } else if values.isRegularFile == true {
                let blob = UUID().uuidString.lowercased() + ".sealed"
                let plaintext = try Data(contentsOf: url, options: .mappedIfSafe)
                let sealed = try AES.GCM.seal(plaintext, using: key)
                guard let combined = sealed.combined else { throw CocoaError(.fileWriteUnknown) }
                try combined.write(to: temporary.appendingPathComponent(blob), options: [.atomic])
                entries.append(.init(relativePath: relative, kind: .file, blob: blob))
            }
        }
        let record = Record(configuration: configuration, snapshot: snapshot, events: events,
                            preflight: preflight, bookmark: bookmark, startedAt: startedAt,
                            endedAt: Date(), entries: entries)
        let encoded = try JSONEncoder().encode(record)
        guard let combined = try AES.GCM.seal(encoded, using: key).combined else {
            throw CocoaError(.fileWriteUnknown)
        }
        try combined.write(to: temporary.appendingPathComponent("manifest.sealed"), options: [.atomic])
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        try fileManager.moveItem(at: temporary, to: destination)
        // Workers receive read-only context snapshots. After the encrypted
        // archive is committed and workers have stopped, thaw owned directories
        // so removal does not leave a plaintext session behind.
        if let contents = fileManager.enumerator(at: active, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            for case let url as URL in contents {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values.isDirectory == true, values.isSymbolicLink != true {
                    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
                }
            }
        }
        try fileManager.removeItem(at: active)
    }

    func records() -> [Record] {
        let archiveRoot = root.appendingPathComponent("archives", isDirectory: true)
        guard let directories = try? fileManager.contentsOfDirectory(at: archiveRoot,
                                                                      includingPropertiesForKeys: nil) else { return [] }
        return directories.compactMap { try? record(at: $0) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    func record(sessionID: String) throws -> Record {
        try record(at: root.appendingPathComponent("archives/\(sessionID)", isDirectory: true))
    }

    func restore(_ record: Record, to active: URL) throws {
        let archive = root.appendingPathComponent("archives/\(record.configuration.sessionID)", isDirectory: true)
        let key = try keyProvider()
        try fileManager.createDirectory(at: active, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        for entry in record.entries where entry.kind == .directory {
            try fileManager.createDirectory(at: active.appendingPathComponent(entry.relativePath),
                                            withIntermediateDirectories: true)
        }
        for entry in record.entries where entry.kind == .file {
            guard let blob = entry.blob else { continue }
            let sealed = try AES.GCM.SealedBox(combined: Data(contentsOf: archive.appendingPathComponent(blob)))
            let plaintext = try AES.GCM.open(sealed, using: key)
            let destination = active.appendingPathComponent(entry.relativePath)
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try plaintext.write(to: destination, options: [.atomic])
        }
        for entry in record.entries where entry.kind == .symlink {
            guard let target = entry.symlinkTarget else { continue }
            let destination = active.appendingPathComponent(entry.relativePath)
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.createSymbolicLink(atPath: destination.path, withDestinationPath: target)
        }
    }

    func delete(sessionID: String) throws {
        let archive = root.appendingPathComponent("archives/\(sessionID)", isDirectory: true)
        if fileManager.fileExists(atPath: archive.path) { try fileManager.removeItem(at: archive) }
    }

    private func record(at archive: URL) throws -> Record {
        let key = try keyProvider()
        let data = try Data(contentsOf: archive.appendingPathComponent("manifest.sealed"))
        let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key)
        return try JSONDecoder().decode(Record.self, from: plaintext)
    }
}
