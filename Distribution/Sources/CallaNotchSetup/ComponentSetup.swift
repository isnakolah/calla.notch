import Darwin
import DistributionCore
import Foundation

/// Installs the tools and models into the one Components folder, using
/// whatever is already in place before downloading anything.
///
/// For each component the order is:
///  1. already in Components (verified);
///  2. a `calla.notch Components` folder carried from another Mac;
///  3. the copy bundled in this package (tools only);
///  4. a matching copy elsewhere on this Mac (another install of the same
///     version, or a model with the pinned checksum);
///  5. a download, with progress.
enum ComponentSetup {
    static func report(_ status: TransferStatus) {
        SetupInterface.transfer(status)
    }

    // MARK: Where to look

    /// `calla.notch Components` folders: beside the setup app (the disk
    /// image), in Downloads and on the Desktop, and at the top of any mounted
    /// drive.
    static var carryFolders: [URL] {
        var roots: [URL] = []
        if let app = enclosingApp() { roots.append(app.deletingLastPathComponent()) }
        roots += [Layout.home.appendingPathComponent("Downloads"), Layout.home.appendingPathComponent("Desktop")]
        if let volumes = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: "/Volumes"), includingPropertiesForKeys: nil) {
            roots += volumes
        }
        var seen = Set<String>()
        return roots.map { $0.appendingPathComponent(ComponentLayout.carryName) }
            .filter { fm.fileExists(atPath: $0.path) && seen.insert($0.resolvingSymlinksInPath().path).inserted }
    }

    // MARK: Older locations

    /// Moves what older builds installed into Components and leaves links
    /// behind, so a second copy is never downloaded and the engine and call
    /// host keep finding everything where they look.
    static func migrateLegacy() throws {
        try Layout.privateDirectory(ComponentLayout.root)
        try adopt(legacy: ComponentLayout.legacyAgy, into: ComponentLayout.tool("agy"))
        try adopt(legacy: ComponentLayout.legacyModels, into: ComponentLayout.models)
        let oldDownloads = Layout.setup.appendingPathComponent("downloads")
        if fm.fileExists(atPath: oldDownloads.path) { try? fm.removeItem(at: oldDownloads) }
    }

    private static func adopt(legacy: URL, into destination: URL) throws {
        if let link = try? fm.destinationOfSymbolicLink(atPath: legacy.path),
           URL(fileURLWithPath: link, relativeTo: legacy.deletingLastPathComponent()).standardizedFileURL.path
            == destination.standardizedFileURL.path { return }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: legacy.path, isDirectory: &isDirectory), isDirectory.boolValue {
            SetupInterface.activity("Moving files from an earlier install into Components…")
            for item in try fm.contentsOfDirectory(atPath: legacy.path) {
                let target = destination.appendingPathComponent(item)
                if fm.fileExists(atPath: target.path) || (try? fm.destinationOfSymbolicLink(atPath: target.path)) != nil { continue }
                // Same volume: a rename, instant whatever the size.
                try fm.moveItem(at: legacy.appendingPathComponent(item), to: target)
            }
            try fm.removeItem(at: legacy)
        } else if (try? fm.destinationOfSymbolicLink(atPath: legacy.path)) != nil {
            try fm.removeItem(at: legacy)
        }
        try fm.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: legacy, withDestinationURL: destination)
    }

    // MARK: Tools

    static func version(of binary: URL) -> String? {
        guard fm.isExecutableFile(atPath: binary.path) else { return nil }
        removexattr(binary.path, "com.apple.quarantine", XATTR_NOFOLLOW)
        return try? Commands.run(binary.path, ["--version"], timeout: 30, check: false)
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The binary inside a tool folder laid out the Components way.
    private static func binary(_ name: String, in folder: URL) -> URL {
        name == "agy" ? folder.appendingPathComponent("agy") : folder.appendingPathComponent("bin/\(name)")
    }

    private static func matches(_ binary: URL, _ dependency: ReleaseManifest.Dependency) -> Bool {
        version(of: binary)?.contains(dependency.version) == true
    }

    /// Installs `agy`, `codex` or `claude` at the package's pinned version.
    static func installTool(_ name: String, _ dependency: ReleaseManifest.Dependency, package: URL) throws {
        let title = ["agy": "AGY", "codex": "Codex", "claude": "Claude"][name] ?? name
        let folder = ComponentLayout.tool(name).appendingPathComponent(dependency.version)
        try Layout.privateDirectory(ComponentLayout.tool(name))

        // `codex update` / `claude update` may have moved past the package's
        // pin. A repair must not quietly downgrade it.
        if let active = activeVersion(name), isNewer(active, than: dependency.version),
           version(of: binary(name, in: ComponentLayout.tool(name).appendingPathComponent(active)))?.contains(active) == true {
            SetupInterface.activity("Keeping \(title) \(active), newer than this package's \(dependency.version).")
            return
        }
        if matches(binary(name, in: folder), dependency) {
            SetupInterface.activity("\(title) \(dependency.version) is already installed.")
            return try activate(name, dependency.version)
        }
        for carry in carryFolders {
            let candidate = carry.appendingPathComponent("\(name)/\(dependency.version)")
            guard matches(binary(name, in: candidate), dependency) else { continue }
            SetupInterface.activity("Found \(title) \(dependency.version) in \(display(carry)). Copying it…")
            try Transfer.copy(candidate, to: folder, name: title, report: report)
            return try finishTool(name, title, dependency)
        }
        // The package ships every tool, so this is the usual path: a copy, not a download.
        for app in Set([package, Layout.app].map { $0.resolvingSymlinksInPath() }) {
            let provider = app.appendingPathComponent("Contents/Resources/Tangit/Providers/\(name)")
            let bundled = provider.appendingPathComponent("bin/\(name)")
            guard matches(bundled, dependency) else { continue }
            SetupInterface.activity("Installing \(title) \(dependency.version) from this package — no download needed…")
            if name == "agy" {
                try fm.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Transfer.copy(bundled, to: folder.appendingPathComponent("agy"), name: title, report: report)
            } else {
                try Transfer.copy(provider, to: folder, name: title, report: report)
            }
            return try finishTool(name, title, dependency)
        }
        // The same version installed some other way. Codex is a package of
        // several files, so only the single-binary tools are adopted.
        if name != "codex" {
            for path in externalCandidates(name) where matches(path, dependency) {
                SetupInterface.activity("Found \(title) \(dependency.version) at \(display(path)). Using it…")
                try fm.createDirectory(at: binary(name, in: folder).deletingLastPathComponent(), withIntermediateDirectories: true)
                try Transfer.copy(path, to: binary(name, in: folder), name: title, report: report)
                return try finishTool(name, title, dependency)
            }
        }
        SetupInterface.activity("Downloading \(title) \(dependency.version)…")
        let archive = try fetch(dependency, name: name, title: title)
        let stage = ComponentLayout.downloads.appendingPathComponent(".stage-\(name)-" + UUID().uuidString)
        try Layout.privateDirectory(stage)
        defer { try? fm.removeItem(at: stage) }
        switch name {
        case "codex":
            SetupInterface.activity("Unpacking Codex…")
            try Commands.run("/usr/bin/tar", ["-xzf", archive.path, "-C", stage.path], timeout: 600)
        case "claude":
            try fm.createDirectory(at: stage.appendingPathComponent("bin"), withIntermediateDirectories: true)
            try fm.copyItem(at: archive, to: stage.appendingPathComponent("bin/claude"))
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stage.appendingPathComponent("bin/claude").path)
        default:
            SetupInterface.activity("Unpacking AGY…")
            try Commands.run("/usr/bin/tar", ["-xzf", archive.path, "-C", stage.path, "antigravity"], timeout: 600)
            try fm.moveItem(at: stage.appendingPathComponent("antigravity"), to: stage.appendingPathComponent("agy"))
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stage.appendingPathComponent("agy").path)
        }
        if fm.fileExists(atPath: folder.path) { try fm.removeItem(at: folder) }
        try fm.moveItem(at: stage, to: folder)
        try? fm.removeItem(at: archive)
        try finishTool(name, title, dependency)
    }

    private static func finishTool(_ name: String, _ title: String, _ dependency: ReleaseManifest.Dependency) throws {
        let folder = ComponentLayout.tool(name).appendingPathComponent(dependency.version)
        clearQuarantine(folder)
        guard matches(binary(name, in: folder), dependency) else {
            try? fm.removeItem(at: folder)
            throw SetupFailure("\(title) did not report version \(dependency.version) after installing. Retry this step.")
        }
        try activate(name, dependency.version)
        SetupInterface.activity("\(title) \(dependency.version) is installed in Components.")
    }

    // MARK: Updating past the package's pin

    /// Codex finds its own updater by where it is installed, and a copy
    /// shared by every Tangit profile is in none of the places it knows.
    /// Claude's updater installs a second copy that Tangit never runs. So
    /// `update` comes here: the latest official release, checksum-verified,
    /// into Components, where every profile picks it up.
    static func updateTool(_ name: String) throws {
        let title = ["codex": "Codex", "claude": "Claude"][name] ?? name
        SetupInterface.activity("Checking for the latest \(title)…")
        let latest = try latestRelease(name)
        if let active = activeVersion(name), !isNewer(latest.version, than: active) {
            print("\(title) \(active) is the latest version.")
            return
        }
        try installTool(name, latest, package: Layout.app)
        print("\(title) is now \(latest.version). Tangit profiles use it from their next session.")
    }

    static func latestRelease(_ name: String) throws -> ReleaseManifest.Dependency {
        switch name {
        case "codex":
            let release = try json("https://api.github.com/repos/openai/codex/releases/latest")
            guard let tag = release["tag_name"] as? String, tag.hasPrefix("rust-v"),
                  let asset = (release["assets"] as? [[String: Any]])?
                    .first(where: { $0["name"] as? String == "codex-package-aarch64-apple-darwin.tar.gz" }),
                  let url = (asset["browser_download_url"] as? String).flatMap(URL.init(string:)),
                  let digest = asset["digest"] as? String, digest.hasPrefix("sha256:")
            else { throw SetupFailure("GitHub did not describe the latest Codex release. Try again later.") }
            return .init(version: String(tag.dropFirst("rust-v".count)), url: url,
                         algorithm: "sha256", checksum: String(digest.dropFirst("sha256:".count)))
        case "claude":
            let base = "https://downloads.claude.ai/claude-code-releases/"
            let version = String(decoding: try get(base + "latest"), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let manifest = try json(base + version + "/manifest.json")
            guard let platform = (manifest["platforms"] as? [String: Any])?["darwin-arm64"] as? [String: Any],
                  let checksum = platform["checksum"] as? String,
                  let url = URL(string: base + version + "/darwin-arm64/claude")
            else { throw SetupFailure("Anthropic did not describe the latest Claude release. Try again later.") }
            return .init(version: version, url: url, algorithm: "sha256", checksum: checksum)
        default:
            throw SetupFailure("Only codex and claude update this way. AGY updates with each calla.notch package.")
        }
    }

    /// The version `current` points at, when it is a version folder.
    static func activeVersion(_ name: String) -> String? {
        let link = ComponentLayout.tool(name).appendingPathComponent("current").path
        guard let target = try? fm.destinationOfSymbolicLink(atPath: link),
              target.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil else { return nil }
        return target
    }

    static func isNewer(_ version: String, than other: String) -> Bool {
        version.compare(other, options: .numeric) == .orderedDescending
    }

    private static func json(_ url: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: get(url)) as? [String: Any] else {
            throw SetupFailure("Unexpected reply from \(URL(string: url)?.host ?? url).")
        }
        return object
    }

    private static func get(_ url: String) throws -> Data {
        var request = URLRequest(url: URL(string: url)!, timeoutInterval: 30)
        request.setValue("calla.notch-setup", forHTTPHeaderField: "User-Agent")
        let done = DispatchSemaphore(value: 0)
        var result: Result<Data, Error> = .failure(SetupFailure("No reply from \(request.url?.host ?? url). Check the internet connection."))
        URLSession(configuration: .ephemeral).dataTask(with: request) { data, response, error in
            if let data, (response as? HTTPURLResponse)?.statusCode == 200 { result = .success(data) }
            else if let error { result = .failure(error) }
            done.signal()
        }.resume()
        done.wait()
        return try result.get()
    }

    /// Points `current` at a version atomically; a rename replaces a link in
    /// one step, so nothing ever sees the tool missing.
    private static func activate(_ name: String, _ version: String) throws {
        let root = ComponentLayout.tool(name)
        let next = root.appendingPathComponent(".current-" + UUID().uuidString)
        try fm.createSymbolicLink(atPath: next.path, withDestinationPath: version)
        guard rename(next.path, root.appendingPathComponent("current").path) == 0 else {
            try? fm.removeItem(at: next)
            throw SetupFailure("Could not activate \(name); the previous version is unchanged.")
        }
    }

    private static func externalCandidates(_ name: String) -> [URL] {
        let paths = ["~/.local/bin/\(name)", "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
            + (name == "claude" ? ["~/.claude/local/claude"] : [])
        return paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).resolvingSymlinksInPath() }
            .filter { url in
                guard fm.isExecutableFile(atPath: url.path) else { return false }
                // Skip the little launch scripts setup itself writes.
                let head = (try? FileHandle(forReadingFrom: url)).flatMap { try? $0.read(upToCount: 256) } ?? Data()
                return !TangitSetup.isOwnLauncher(head)
                    && !url.path.hasPrefix(ComponentLayout.root.path)
            }
    }

    /// Downloads a pinned dependency into Components/downloads, resuming a
    /// partial download, and checks it before use.
    static func fetch(_ dependency: ReleaseManifest.Dependency, name: String, title: String) throws -> URL {
        try dependency.validate()
        try Layout.privateDirectory(ComponentLayout.downloads)
        let destination = ComponentLayout.downloads.appendingPathComponent("\(name)-\(dependency.version)")
        func valid(_ url: URL) -> Bool {
            (try? Transfer.digest(url, algorithm: dependency.algorithm, name: title, report: report)) == dependency.checksum.lowercased()
        }
        if fm.fileExists(atPath: destination.path) {
            if valid(destination) { return destination }
            try fm.removeItem(at: destination)
        }
        try Transfer.download(dependency.url, to: destination, expectedSize: nil, name: title, report: report)
        guard valid(destination) else {
            try? fm.removeItem(at: destination)
            throw SetupFailure("The \(title) download did not match its checksum and was discarded. Retry this step.")
        }
        return destination
    }

    // MARK: Models

    static func installModel(_ spec: ModelSpec) throws {
        try Layout.privateDirectory(ComponentLayout.models)
        let destination = ComponentLayout.models.appendingPathComponent(spec.file)
        func check(_ url: URL) -> Bool {
            Transfer.verify(url, sha256: spec.sha256, size: spec.size, name: spec.title, report: report)
        }
        if fm.fileExists(atPath: destination.path) {
            SetupInterface.activity("Checking \(spec.phrase) already on this Mac…")
            if check(destination) {
                SetupInterface.activity("\(spec.phrase.prefix(1).uppercased() + spec.phrase.dropFirst()) is already installed and verified.")
                return try installEncoder(spec)
            }
            SetupInterface.activity("\(spec.phrase.prefix(1).uppercased() + spec.phrase.dropFirst()) on this Mac is damaged; replacing it.")
            try fm.removeItem(at: destination)
        }
        let elsewhere = carryFolders.map { ($0.appendingPathComponent("models/\(spec.file)"), display($0)) }
            + modelFolders.map { ($0.appendingPathComponent(spec.file), display($0)) }
            + otherAppModels(size: spec.size)
        for (candidate, place) in elsewhere where fm.fileExists(atPath: candidate.path) {
            SetupInterface.activity("Found \(spec.phrase) in \(place). Checking it…")
            guard check(candidate) else { continue }
            SetupInterface.activity("Using \(spec.phrase) from \(place)…")
            try Transfer.copy(candidate, to: destination, name: spec.title, report: report)
            return try installEncoder(spec)
        }
        SetupInterface.activity("Downloading \(spec.phrase) (\(TransferStatus.size(spec.size)))…")
        let download = ComponentLayout.downloads.appendingPathComponent(spec.file)
        try Layout.privateDirectory(ComponentLayout.downloads)
        try Transfer.download(spec.url, to: download, expectedSize: spec.size, name: spec.title, report: report)
        SetupInterface.activity("Checking the download…")
        guard check(download) else {
            try? fm.removeItem(at: download)
            throw SetupFailure("\(spec.phrase.prefix(1).uppercased() + spec.phrase.dropFirst()) did not match its checksum and was discarded. Retry this step.")
        }
        try fm.moveItem(at: download, to: destination)
        try installEncoder(spec)
    }

    private static func installEncoder(_ spec: ModelSpec) throws {
        guard let encoder = spec.encoder else { return }
        let title = spec.title + " (accelerator)"
        let destination = ComponentLayout.models.appendingPathComponent(spec.encoderDirectory)
        if fm.fileExists(atPath: destination.appendingPathComponent("coremldata.bin").path)
            || fm.fileExists(atPath: destination.appendingPathComponent("model.mil").path) {
            SetupInterface.activity("The \(title.lowercased()) is already installed.")
            return
        }
        for carry in carryFolders {
            let candidate = carry.appendingPathComponent("models/\(spec.encoderDirectory)")
            guard fm.fileExists(atPath: candidate.path) else { continue }
            SetupInterface.activity("Using the \(title.lowercased()) from \(display(carry))…")
            try Transfer.copy(candidate, to: destination, name: title, report: report)
            return
        }
        let archive = ComponentLayout.downloads.appendingPathComponent(spec.encoderDirectory + ".zip")
        if !Transfer.verify(archive, sha256: encoder.sha256, size: encoder.size, name: title, report: report) {
            SetupInterface.activity("Downloading the \(title.lowercased()) (\(TransferStatus.size(encoder.size)))…")
            try Transfer.download(encoder.url, to: archive, expectedSize: encoder.size, name: title, report: report)
            guard Transfer.verify(archive, sha256: encoder.sha256, size: encoder.size, name: title, report: report) else {
                try? fm.removeItem(at: archive)
                throw SetupFailure("The \(title.lowercased()) did not match its checksum and was discarded. Retry this step.")
            }
        }
        SetupInterface.activity("Unpacking the \(title.lowercased())…")
        SetupInterface.progress(nil)
        let stage = ComponentLayout.downloads.appendingPathComponent(".unzip-" + UUID().uuidString)
        try Layout.privateDirectory(stage)
        defer { try? fm.removeItem(at: stage) }
        try Commands.run("/usr/bin/unzip", ["-q", archive.path, "-d", stage.path], timeout: 1800)
        guard let extracted = fm.enumerator(at: stage, includingPropertiesForKeys: nil)?
            .compactMap({ $0 as? URL }).first(where: { $0.pathExtension == "mlmodelc" }) else {
            throw SetupFailure("The \(title.lowercased()) archive was empty. Retry this step.")
        }
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: extracted, to: destination)
        try? fm.removeItem(at: archive)
    }

    /// Model folders from earlier installs that have not been migrated yet.
    private static var modelFolders: [URL] {
        let legacy = ComponentLayout.legacyModels
        return (try? fm.destinationOfSymbolicLink(atPath: legacy.path)) == nil && fm.fileExists(atPath: legacy.path) ? [legacy] : []
    }

    /// Apps that ship the same whisper.cpp weights. Matched by exact size
    /// first, then by checksum, so nothing is trusted on its name.
    private static func otherAppModels(size: Int64) -> [(URL, String)] {
        let folders = ["~/Library/Application Support/Mila/Models"]
        return folders.flatMap { folder -> [(URL, String)] in
            let directory = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath)
            let entries = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            return entries.filter { (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0 ?? 0) } == size }
                .map { ($0, display(directory)) }
        }
    }

    // MARK: Housekeeping

    /// Files that arrive from a download, AirDrop or a quarantined disk
    /// image carry the quarantine flag, and an unsigned tool with it is
    /// blocked every time it runs. Everything here was checked before use.
    static func clearQuarantine(_ url: URL = ComponentLayout.root) {
        _ = try? Commands.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", url.path], check: false)
    }

    static func display(_ url: URL) -> String {
        let path = url.path
        if path.hasPrefix("/Volumes/") { return path }
        return path.replacingOccurrences(of: Layout.home.path, with: "~")
    }

    /// What is in place, for the summary at the start and for doctor.
    static func inventory(_ manifest: ReleaseManifest) -> [(String, Bool)] {
        var rows: [(String, Bool)] = []
        let tools: [(String, ReleaseManifest.Dependency?)] = [("agy", manifest.agy), ("codex", manifest.codex), ("claude", manifest.claude)]
        for (name, dependency) in tools {
            guard let dependency else { continue }
            let folder = ComponentLayout.tool(name).appendingPathComponent(dependency.version)
            rows.append(("\(name) \(dependency.version)", fm.isExecutableFile(atPath: binary(name, in: folder).path)))
        }
        for spec in [ModelSpec.live, .archive] {
            let file = ComponentLayout.models.appendingPathComponent(spec.file)
            let size = ((try? fm.attributesOfItem(atPath: file.path)[.size]) as? NSNumber)?.int64Value
            rows.append((spec.title, size == spec.size))
        }
        return rows
    }

    // MARK: Carrying to another Mac

    /// Writes a `calla.notch Components` folder holding the speech models
    /// this Mac already has. Put it on a USB drive (or in Downloads) on the
    /// other Mac and setup copies from it instead of downloading. The tools
    /// are already inside the package.
    static func export(to folder: URL) throws {
        let models = folder.appendingPathComponent("models")
        try fm.createDirectory(at: models, withIntermediateDirectories: true)
        let sources = [ComponentLayout.models, ComponentLayout.legacyModels.resolvingSymlinksInPath()]
        var exported = 0
        for spec in [ModelSpec.live, .archive] {
            guard let source = sources.map({ $0.appendingPathComponent(spec.file) })
                .first(where: { Transfer.verify($0, sha256: spec.sha256, size: spec.size, name: spec.title, report: report) })
            else { print("Not on this Mac: \(spec.title) — the other Mac will download it."); continue }
            let target = models.appendingPathComponent(spec.file)
            if Transfer.verify(target, sha256: spec.sha256, size: spec.size, name: spec.title, report: report) {
                print("Already exported: \(spec.title)")
            } else {
                print("Copying \(spec.title)…")
                try Transfer.copy(source, to: target, name: spec.title, report: report)
            }
            exported += 1
            let encoder = source.deletingLastPathComponent().appendingPathComponent(spec.encoderDirectory)
            if spec.encoder != nil, fm.fileExists(atPath: encoder.path),
               !fm.fileExists(atPath: models.appendingPathComponent(spec.encoderDirectory).path) {
                print("Copying \(spec.title) accelerator…")
                try Transfer.copy(encoder, to: models.appendingPathComponent(spec.encoderDirectory), name: spec.title + " (accelerator)", report: report)
            }
        }
        let readme = """
        calla.notch Components

        Speech models from another Mac, so setup does not download them again.
        Keep this folder next to the calla.notch disk image, in Downloads, on
        the Desktop, or at the top of a USB drive. Setup finds it, checks every
        file against its pinned checksum, and copies what it needs.

        """
        try readme.write(to: folder.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        print("\nExported \(exported) model(s) to \(display(folder)).")
    }
}
