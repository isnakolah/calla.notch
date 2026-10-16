import Foundation

public enum PackageInstaller {
    public static let manifestPath = "Contents/Resources/PrivateSetup/manifest.json"
    public static func manifest(in app: URL) throws -> ReleaseManifest {
        let value = try JSONDecoder().decode(ReleaseManifest.self,
                        from: Data(contentsOf: app.appendingPathComponent(manifestPath)))
        try value.validate()
        return value
    }
    public static func validate(_ app: URL) throws -> ReleaseManifest {
        let release = try manifest(in: app)
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == "theboringteam.boringnotch",
              info["BoringPrivateDistribution"] as? Bool == true,
              info["BoringSetupProtocolVersion"] as? Int == 1,
              info["CFBundleShortVersionString"] as? String == release.version,
              String(describing: info["CFBundleVersion"] ?? "") == String(release.build)
        else { throw SetupFailure("This is not a matching private Boring Notch package.") }
        try Commands.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        var files = ["Contents/MacOS/boringNotch", Layout.callHost,
                     "Contents/Helpers/boring-notch", "Contents/Helpers/calla-gateway",
                     "Contents/XPCServices/BoringNotchXPCHelper.xpc/Contents/MacOS/BoringNotchXPCHelper",
                     "Contents/XPCServices/BoringCallaEngine.xpc/Contents/MacOS/BoringCallaEngine"]
        if release.tangit != nil {
            files += ["Contents/Helpers/tangit", "Contents/Resources/Tangit/Providers/codex/bin/codex",
                      "Contents/Resources/Tangit/Providers/claude/bin/claude", "Contents/Resources/Tangit/Providers/agy/bin/agy"]
        }
        if release.graphicalSetup == true, info["BoringSetupUIVersion"] as? Int != 1 {
            throw SetupFailure("This app does not contain the integrated setup window. Obtain the complete private app.")
        }
        for path in files where !FileManager.default.isExecutableFile(atPath: app.appendingPathComponent(path).path) {
            throw SetupFailure("Package is missing executable \(path). Download a complete package.")
        }
        return release
    }
    public static func requirement(_ app: URL) throws -> String {
        let output = try Commands.run("/usr/bin/codesign", ["-d", "-r-", app.path], captureStderr: true).output
        guard let line = output.split(separator: "\n").first(where: { $0.hasPrefix("designated => ") }),
              line.contains("certificate") else { throw SetupFailure("Package needs a persistent signing identity.") }
        return String(line)
    }
    /// Stable identity is required for updates. Ad-hoc or unrelated upstream
    /// builds cannot replace this app while pretending to retain TCC grants.
    public static func checkUpdate(source: URL, installed: URL) throws {
        _ = try validate(source)
        guard FileManager.default.fileExists(atPath: installed.path) else { return }
        guard try requirement(source) == requirement(installed) else {
            throw SetupFailure("Signing identity differs from the installed app. Keep the existing app and obtain a package signed with the same certificate.")
        }
        if let old = try? manifest(in: installed), let new = try? manifest(in: source), new.build < old.build {
            throw SetupFailure("This package is older than the installed build. Obtain the newest private package.")
        }
    }
    /// A same-filesystem rename is the commit point. The old app is kept until
    /// the staged copy verifies; failed copies/signatures cannot remove it.
    public static func transactionScript(source: URL, destination: URL) -> String {
        let parent = Commands.shellQuote(destination.deletingLastPathComponent().path)
        let source = Commands.shellQuote(source.path)
        let destination = Commands.shellQuote(destination.path)
        return """
        set -eu
        stage=$(/usr/bin/mktemp -d \(parent)/.boring-notch-install.XXXXXX)
        committed=0
        restore() {
          if [ "$committed" = 0 ] && [ -d "$stage/previous.app" ]; then
            /bin/mv "$stage/previous.app" \(destination)
          fi
          /bin/rm -rf "$stage"
        }
        trap restore EXIT HUP INT TERM
        /usr/bin/ditto \(source) "$stage/next.app"
        /usr/bin/codesign --verify --deep --strict "$stage/next.app"
        # The user approved this exact package once in Privacy & Security.
        # ditto carries the disk image's quarantine flag onto every nested
        # helper and provider, so without this each one is re-assessed by
        # Gatekeeper on first launch. Cleared only after the signature verified.
        /usr/bin/xattr -dr com.apple.quarantine "$stage/next.app" 2>/dev/null || true
        if [ -e \(destination) ]; then /bin/mv \(destination) "$stage/previous.app"; fi
        /bin/mv "$stage/next.app" \(destination)
        committed=1
        """
    }
}
