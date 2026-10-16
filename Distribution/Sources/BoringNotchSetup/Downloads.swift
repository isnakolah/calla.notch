import DistributionCore
import Foundation

enum Downloads {
    static func fetch(_ dependency: ReleaseManifest.Dependency, name: String) throws -> URL {
        try dependency.validate()
        let directory = Layout.setup.appendingPathComponent("downloads")
        try Layout.privateDirectory(directory)
        let destination = directory.appendingPathComponent(name + "-" + dependency.version)
        if FileManager.default.fileExists(atPath: destination.path) {
            if (try? Checksums.verify(destination, dependency: dependency)) != nil { return destination }
            try FileManager.default.removeItem(at: destination)
        }
        let partial = destination.appendingPathExtension("partial")
        print("Downloading \(name) \(dependency.version). Progress is shown below; interrupted downloads can be retried.")
        let result = try Commands.run("/usr/bin/curl", ["--fail", "--location", "--proto", "=https",
            "--proto-redir", "=https", "--retry", "3", "--connect-timeout", "20",
            "--speed-limit", "1", "--speed-time", "90", "--continue-at", "-",
            "--output", partial.path, dependency.url.absoluteString], inherit: true, timeout: 7200, check: false)
        if result.status == 33 {
            try? FileManager.default.removeItem(at: partial)
            throw SetupFailure("This server cannot resume the interrupted download. Rerun setup to start a fresh download.")
        }
        guard result.status == 0 else { throw SetupFailure("Download failed. Check your internet connection and rerun setup to resume.") }
        do { try Checksums.verify(partial, dependency: dependency) }
        catch { try? FileManager.default.removeItem(at: partial); throw error }
        try FileManager.default.moveItem(at: partial, to: destination)
        return destination
    }

    static func installAgy(_ dependency: ReleaseManifest.Dependency) throws {
        let versionDirectory = Layout.managed.appendingPathComponent(dependency.version)
        let binary = versionDirectory.appendingPathComponent("agy")
        if FileManager.default.isExecutableFile(atPath: binary.path),
           (try? Commands.run(binary.path, ["--version"]).output.trimmingCharacters(in: .whitespacesAndNewlines)) == dependency.version {
            try activate(versionDirectory)
            print("Managed AGY \(dependency.version) is already installed.")
            return
        }
        let stage = Layout.managed.appendingPathComponent(".stage-" + UUID().uuidString)
        try Layout.privateDirectory(stage)
        defer { try? FileManager.default.removeItem(at: stage) }
        let extracted = stage.appendingPathComponent("antigravity")
        let bundled = Layout.provider("agy")
        if FileManager.default.isExecutableFile(atPath: bundled.path) {
            try FileManager.default.copyItem(at: bundled, to: extracted)
            print("Installing AGY from this package; no download is needed.")
        } else {
            let archive = try fetch(dependency, name: "agy")
            try Commands.run("/usr/bin/tar", ["-xzf", archive.path, "-C", stage.path, "antigravity"])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: extracted.path)
        // A copy from an older, still-quarantined install would be blocked by
        // Gatekeeper every time the engine starts AGY in the background.
        removexattr(extracted.path, "com.apple.quarantine", XATTR_NOFOLLOW)
        let version = try Commands.run(extracted.path, ["--version"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard version == dependency.version else { throw SetupFailure("AGY version does not match this package.") }
        try FileManager.default.moveItem(at: extracted, to: stage.appendingPathComponent("agy"))
        // The native binary is self-contained. Do not invoke `agy install`,
        // which edits shell profiles and aliases intended for a global CLI.
        let backup = Layout.managed.appendingPathComponent(".previous-" + UUID().uuidString)
        if FileManager.default.fileExists(atPath: versionDirectory.path) {
            try FileManager.default.moveItem(at: versionDirectory, to: backup)
        }
        do { try FileManager.default.moveItem(at: stage, to: versionDirectory) }
        catch {
            if FileManager.default.fileExists(atPath: backup.path) { try? FileManager.default.moveItem(at: backup, to: versionDirectory) }
            throw error
        }
        try? FileManager.default.removeItem(at: backup)
        try activate(versionDirectory)
    }

    private static func activate(_ directory: URL) throws {
        try Layout.privateDirectory(Layout.managed)
        let next = Layout.managed.appendingPathComponent(".current-" + UUID().uuidString)
        try FileManager.default.createSymbolicLink(atPath: next.path, withDestinationPath: directory.lastPathComponent)
        // POSIX rename replaces a symlink atomically; remove+create leaves a
        // window in which the app would fall back to an unrelated global AGY.
        guard rename(next.path, Layout.managed.appendingPathComponent("current").path) == 0 else {
            try? FileManager.default.removeItem(at: next)
            throw SetupFailure("Could not activate managed AGY; the previous version is unchanged.")
        }
    }
}
