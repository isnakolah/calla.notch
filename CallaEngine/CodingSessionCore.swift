import CallaContracts
import CryptoKit
import Foundation

enum CodingSessionCoreFailure: LocalizedError, Equatable {
    case sourceUnavailable
    case pathEscape(String)
    case commandDenied(String)
    case copyFailed(String)

    var errorDescription: String? {
        switch self {
        case .sourceUnavailable: "The selected folder is no longer available."
        case .pathEscape(let path): "The path escapes the shadow project: \(path)"
        case .commandDenied(let reason): "The command is not allowed: \(reason)"
        case .copyFailed(let path): "Could not mirror \(path)."
        }
    }
}

struct CodingSnapshotManifest: Codable, Equatable {
    struct Entry: Codable, Equatable, Comparable {
        var path: String
        var kind: String
        var size: Int64
        var digest: String
        static func < (lhs: Entry, rhs: Entry) -> Bool { lhs.path < rhs.path }
    }
    var revision: String
    var entries: [Entry]
    var withheld: [String]
    var externalSymlinks: [String]
    var totalBytes: Int64
}

enum CodingShadowProject {
    enum ReconcileOutcome: Equatable { case current, retainedExperiments, equivalent, conflict }
    private static let excludedDirectories: Set<String> = [
        ".git", ".hg", ".svn", ".build", "build", "DerivedData", "node_modules",
        ".gradle", ".idea", ".pytest_cache", ".mypy_cache", ".ruff_cache", "__pycache__",
        ".venv", "venv", "dist", ".next", ".turbo", "Pods"
    ]
    private static let privateExtensions: Set<String> = ["pem", "key", "p12", "pfx", "mobileprovision"]

    static func inspect(source: URL, fileManager: FileManager = .default) throws -> CodingSnapshotManifest {
        let root = source.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CodingSessionCoreFailure.sourceUnavailable
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(
            at: root, includingPropertiesForKeys: keys,
            options: [], errorHandler: { _, _ in true }) else {
            throw CodingSessionCoreFailure.sourceUnavailable
        }
        var entries: [CodingSnapshotManifest.Entry] = []
        var withheld: [String] = []
        var external: [String] = []
        var total: Int64 = 0

        for case let item as URL in enumerator {
            let relative = relativePath(item, root: root)
            let values = try item.resourceValues(forKeys: Set(keys))
            let attributes = try? fileManager.attributesOfItem(atPath: item.path)
            let isSymbolicLink = attributes?[.type] as? FileAttributeType == .typeSymbolicLink
            if shouldExclude(relative: relative, isDirectory: values.isDirectory == true) {
                withheld.append(relative)
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if isSymbolicLink || values.isSymbolicLink == true {
                let target = (try? fileManager.destinationOfSymbolicLink(atPath: item.path)) ?? ""
                let destination = target.hasPrefix("/")
                    ? URL(fileURLWithPath: target).standardizedFileURL
                    : item.deletingLastPathComponent().appendingPathComponent(target).standardizedFileURL
                guard isInside(destination, root: root) else {
                    external.append(relative); withheld.append(relative); continue
                }
                // Revision identity is independent of the private copy's absolute root.
                let logicalTarget = relativePath(destination, root: root)
                entries.append(.init(path: relative, kind: "symlink", size: 0, digest: digest(Data(logicalTarget.utf8))))
                continue
            }
            if values.isDirectory == true {
                entries.append(.init(path: relative, kind: "directory", size: 0, digest: ""))
            } else if values.isRegularFile == true, let data = fileManager.contents(atPath: item.path) {
                let size = Int64(data.count); total += size
                entries.append(.init(path: relative, kind: "file", size: size, digest: digest(data)))
            }
        }
        entries.sort(); withheld.sort(); external.sort()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let revisionData = try encoder.encode(entries)
        return CodingSnapshotManifest(revision: digest(revisionData), entries: entries,
                                      withheld: withheld, externalSymlinks: external, totalBytes: total)
    }

    @discardableResult
    static func prepare(source: URL, mirror: URL, work: URL,
                        fileManager: FileManager = .default) throws -> CodingSnapshotManifest {
        let manifest = try inspect(source: source, fileManager: fileManager)
        for destination in [mirror, work] {
            if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            try copy(manifest: manifest, source: source, destination: destination, fileManager: fileManager)
        }
        return manifest
    }

    static func copy(manifest: CodingSnapshotManifest, source: URL, destination: URL,
                     fileManager: FileManager = .default) throws {
        let sourceRoot = source.resolvingSymlinksInPath().standardizedFileURL
        let destinationRoot = destination.standardizedFileURL
        for entry in manifest.entries {
            try LiveCodingValidation.validate(relativePath: entry.path)
            let from = sourceRoot.appendingPathComponent(entry.path)
            let to = destinationRoot.appendingPathComponent(entry.path)
            guard isInside(to, root: destinationRoot) else { throw CodingSessionCoreFailure.pathEscape(entry.path) }
            switch entry.kind {
            case "directory":
                try fileManager.createDirectory(at: to, withIntermediateDirectories: true)
            case "symlink":
                var target = try fileManager.destinationOfSymbolicLink(atPath: from.path)
                if target.hasPrefix("/"), CodingShadowProject.isInside(
                    URL(fileURLWithPath: target).resolvingSymlinksInPath(), root: sourceRoot) {
                    let sourceTarget = URL(fileURLWithPath: target).standardizedFileURL
                    let mapped = destinationRoot.appendingPathComponent(relativePath(sourceTarget, root: sourceRoot))
                    target = mapped.path
                }
                try fileManager.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.createSymbolicLink(atPath: to.path, withDestinationPath: target)
            default:
                try fileManager.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                do { try fileManager.copyItem(at: from, to: to) }
                catch { throw CodingSessionCoreFailure.copyFailed(entry.path) }
            }
        }
    }

    /// Three-way saved-state reconciliation: old mirror is the base, work is
    /// the agent side, and a freshly copied source is the candidate side.
    /// Compatible text hunks are merged; any unresolved path resets the entire
    /// experiment so a late result can never target a mixed revision.
    static func reconcile(source: URL, mirror: URL, work: URL,
                          fileManager: FileManager = .default)
        throws -> (manifest: CodingSnapshotManifest, outcome: ReconcileOutcome) {
        let temporary = mirror.deletingLastPathComponent()
            .appendingPathComponent(".incoming-\(UUID().uuidString)", isDirectory: true)
        let incomingMirror = temporary.appendingPathComponent("mirror")
        let incomingWork = temporary.appendingPathComponent("work")
        defer { try? fileManager.removeItem(at: temporary) }
        let incoming = try prepare(source: source, mirror: incomingMirror, work: incomingWork,
                                   fileManager: fileManager)
        let old = try inspect(source: mirror, fileManager: fileManager)
        let agent = try inspect(source: work, fileManager: fileManager)
        let oldMap = Dictionary(uniqueKeysWithValues: old.entries.map { ($0.path, $0) })
        let agentMap = Dictionary(uniqueKeysWithValues: agent.entries.map { ($0.path, $0) })
        let newMap = Dictionary(uniqueKeysWithValues: incoming.entries.map { ($0.path, $0) })
        let paths = Set(oldMap.keys).union(agentMap.keys).union(newMap.keys).sorted()
        var retained = false; var equivalent = false; var conflicted = false
        for path in paths where agentMap[path] != oldMap[path] {
            if agentMap[path] == newMap[path] { equivalent = true; continue }
            if newMap[path] == oldMap[path] {
                try replace(path: path, from: work, in: incomingWork, entry: agentMap[path],
                            fileManager: fileManager)
                retained = true; continue
            }
            if oldMap[path]?.kind == "file", agentMap[path]?.kind == "file",
               newMap[path]?.kind == "file",
               try mergeText(path: path, agent: work, base: mirror, candidate: incomingMirror,
                             destination: incomingWork, fileManager: fileManager) {
                retained = true
            } else { conflicted = true; break }
        }
        try replaceDirectory(mirror, with: incomingMirror, fileManager: fileManager)
        if conflicted {
            try replaceDirectory(work, with: incomingWork, fileManager: fileManager)
            return (incoming, .conflict)
        }
        try replaceDirectory(work, with: incomingWork, fileManager: fileManager)
        return (incoming, retained ? .retainedExperiments : (equivalent ? .equivalent : .current))
    }

    private static func replace(path: String, from sourceRoot: URL, in destinationRoot: URL,
                                entry: CodingSnapshotManifest.Entry?, fileManager: FileManager) throws {
        let source = sourceRoot.appendingPathComponent(path)
        let destination = destinationRoot.appendingPathComponent(path)
        if fileManager.fileExists(atPath: destination.path)
            || (try? fileManager.destinationOfSymbolicLink(atPath: destination.path)) != nil {
            try fileManager.removeItem(at: destination)
        }
        guard entry != nil else { return }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: source, to: destination)
    }

    private static func mergeText(path: String, agent: URL, base: URL, candidate: URL,
                                  destination: URL, fileManager: FileManager) throws -> Bool {
        let ours = agent.appendingPathComponent(path), ancestor = base.appendingPathComponent(path)
        let theirs = candidate.appendingPathComponent(path)
        guard [ours, ancestor, theirs].allSatisfy({
            (try? String(contentsOf: $0, encoding: .utf8)) != nil
        }) else { return false }
        let mergedURL = fileManager.temporaryDirectory.appendingPathComponent("coding-merge-\(UUID().uuidString)")
        fileManager.createFile(atPath: mergedURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: mergedURL)
        defer { try? output.close(); try? fileManager.removeItem(at: mergedURL) }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["merge-file", "-p", ours.path, ancestor.path, theirs.path]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { return false }
        let target = destination.appendingPathComponent(path)
        try output.synchronize(); try Data(contentsOf: mergedURL).write(to: target, options: .atomic)
        return true
    }

    private static func replaceDirectory(_ destination: URL, with source: URL,
                                         fileManager: FileManager) throws {
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        try fileManager.moveItem(at: source, to: destination)
    }

    static func detectedLanguages(_ manifest: CodingSnapshotManifest) -> [String] {
        let names: [String: String] = [
            "swift": "Swift", "py": "Python", "js": "JavaScript", "ts": "TypeScript",
            "tsx": "TypeScript", "jsx": "JavaScript", "go": "Go", "rs": "Rust",
            "java": "Java", "kt": "Kotlin", "rb": "Ruby", "php": "PHP", "cs": "C#",
            "cpp": "C++", "cc": "C++", "c": "C", "h": "C/C++"
        ]
        return Array(Set(manifest.entries.compactMap { entry in
            names[URL(fileURLWithPath: entry.path).pathExtension.lowercased()]
        })).sorted()
    }

    /// A first check worth offering, from what the tree contains.
    ///
    /// Matched at the root *and* one level down. A repository whose Python
    /// project lives in `python/` — this interview's does — matched nothing at
    /// all, so the session opened with no check to run and the model had to
    /// invent one.
    static func suggestedCommands(_ manifest: CodingSnapshotManifest) -> [CodingRunPlan] {
        let paths = Set(manifest.entries.map(\.path))
        /// The directory holding `name`, as a `relativeCWD`, or nil.
        func directory(holding name: String) -> String? {
            if paths.contains(name) { return "." }
            return paths.first { $0.hasSuffix("/" + name) && $0.dropLast(name.count + 1).allSatisfy { $0 != "/" } }
                .map { String($0.dropLast(name.count + 1)) }
        }
        var commands: [CodingRunPlan] = []
        if paths.contains("Package.swift") { commands.append(.init(displayedCommand: "swift test", expectedEvidence: "All Swift tests pass")) }
        // One Makefile target, not three. `make test` was assumed before, and
        // this repository's Makefile does not define it — `check` is the gate.
        // The manifest only carries paths, so the name cannot be verified here;
        // the order is most-likely-first and the run reports the truth.
        if paths.contains("Makefile") {
            commands.append(.init(displayedCommand: "make check",
                                  expectedEvidence: "make check passes"))
        }
        for marker in ["pytest.ini", "requirements-dev.txt", "pyproject.toml"] {
            guard let cwd = directory(holding: marker) else { continue }
            commands.append(.init(relativeCWD: cwd, displayedCommand: "python3 -m pytest -q",
                                  expectedEvidence: "All Python tests pass"))
            break
        }
        if paths.contains("pyproject.toml") { commands.append(.init(displayedCommand: "python -m pytest", expectedEvidence: "All Python tests pass")) }
        if paths.contains("package.json") { commands.append(.init(displayedCommand: "npm test", expectedEvidence: "JavaScript tests pass")) }
        if paths.contains("go.mod") { commands.append(.init(displayedCommand: "go test ./...", expectedEvidence: "All Go tests pass")) }
        if paths.contains("Cargo.toml") { commands.append(.init(displayedCommand: "cargo test", expectedEvidence: "All Rust tests pass")) }
        return Array(commands.prefix(8))
    }

    static func isInside(_ candidate: URL, root: URL) -> Bool {
        let base = root.standardizedFileURL.path.hasSuffix("/") ? root.standardizedFileURL.path : root.standardizedFileURL.path + "/"
        let path = candidate.standardizedFileURL.path
        return path == root.standardizedFileURL.path || path.hasPrefix(base)
    }

    private static func relativePath(_ url: URL, root: URL) -> String {
        String(url.standardizedFileURL.path.dropFirst(root.path.count + 1))
    }

    private static func shouldExclude(relative: String, isDirectory: Bool) -> Bool {
        let components = relative.split(separator: "/").map(String.init)
        if components.contains(where: excludedDirectories.contains) { return true }
        let name = components.last ?? relative
        if name == ".DS_Store" { return true }
        if name == ".env" || (name.hasPrefix(".env.") && !name.hasSuffix(".example")) { return true }
        if privateExtensions.contains(URL(fileURLWithPath: name).pathExtension.lowercased()) { return true }
        return false
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum CodingCommandPolicy {
    static func validate(command: String, relativeCWD: String, work: URL) throws -> URL {
        try LiveCodingValidation.validate(relativePath: relativeCWD)
        let lowered = command.lowercased()
        let denied = ["sudo ", "osascript", "open -a", "security ", "/usr/bin/security", "ssh-add"]
        if let token = denied.first(where: lowered.contains) {
            throw CodingSessionCoreFailure.commandDenied(token.trimmingCharacters(in: .whitespaces))
        }
        let cwd = work.appendingPathComponent(relativeCWD).standardizedFileURL
        guard CodingShadowProject.isInside(cwd, root: work.standardizedFileURL),
              CodingShadowProject.isInside(cwd.resolvingSymlinksInPath(), root: work.resolvingSymlinksInPath()) else {
            throw CodingSessionCoreFailure.pathEscape(relativeCWD)
        }
        return cwd
    }
}

enum CodingCueDecision: Equatable { case run, cancel, steer, illuminateRun, ignore }

enum CodingCueClassifier {
    static func classify(text: String, speaker: CodingSpeaker, confidence: Double,
                         hasPendingRun: Bool, runActive: Bool) -> CodingCueDecision {
        let normalized = text.lowercased().replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard speaker == .me else { return .steer }
        let words = normalized.split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
        let fillers: Set<String> = ["so", "okay", "ok", "right", "now", "please", "yeah"]
        let opening = words.drop { fillers.contains($0) }.joined(separator: " ")
        func starts(_ phrase: String) -> Bool { opening == phrase || opening.hasPrefix(phrase + " ") }
        let cancel = ["stop that", "cancel the run", "stop the test", "stop it"]
        if runActive, cancel.contains(where: starts) { return confidence >= 0.72 ? .cancel : .ignore }
        let negated = ["don't run", "do not run", "not run", "won't run", "shouldn't run"]
        if negated.contains(where: normalized.contains) { return .steer }
        let run = ["let me run", "let's run", "lets run", "let's test", "lets test", "i'll compile", "run the", "test that"]
        if hasPendingRun, run.contains(where: starts) {
            return confidence >= 0.82 ? .run : .illuminateRun
        }
        return normalized.isEmpty ? .ignore : .steer
    }
}

/// Resolves the app's folder bookmark inside the engine.
///
/// The app is sandboxed and mints an app-scoped **security-scoped** bookmark;
/// the engine that has to resolve it is not sandboxed
/// (`CallaEngine.entitlements` sets `app-sandbox` to false). Passing
/// `.withSecurityScope` from a non-sandboxed process does not merely lose the
/// scope — it fails outright:
///
///     The file couldn't be opened because it isn't in the correct format.
///
/// which `registerFolder` turned into a nil preflight and the notch reported as
/// "The project folder could not be prepared". The same bookmark resolves
/// cleanly with no options, and the resulting URL is readable, because an
/// unsandboxed process never needed the scope in the first place.
///
/// Security scope is still attempted first so this keeps working if the engine
/// is ever sandboxed — which is the only configuration where the option is both
/// meaningful and required.
enum CodingFolderBookmark {
    static func resolve(_ bookmark: Data) throws -> (url: URL, stale: Bool) {
        var stale = false
        if let scoped = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) {
            return (scoped, stale)
        }
        stale = false
        let plain = try URL(resolvingBookmarkData: bookmark, options: [],
                            relativeTo: nil, bookmarkDataIsStale: &stale)
        return (plain, stale)
    }
}
