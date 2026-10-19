import Foundation

/// A profile is accepted only when it is named by Tangit's registry and its
/// provider directory is inside Tangit's own profiles tree.
struct TangitUsageProfile {
    let id: String
    let directory: URL

    static func resolve(_ id: String, provider: String) -> TangitUsageProfile? {
        guard !id.isEmpty, id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil,
              ["claude", "codex"].contains(provider) else { return nil }
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/tangit", isDirectory: true)
        let registry = root.appendingPathComponent("profiles.json")
        guard let data = try? Data(contentsOf: registry),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profiles = json["profiles"] as? [[String: Any]],
              profiles.contains(where: { $0["name"] as? String == id }) else { return nil }
        let directory = root.appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent(provider, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              directory.resolvingSymlinksInPath().path.hasPrefix(root.appendingPathComponent("profiles").path + "/") else { return nil }
        return .init(id: id, directory: directory)
    }

    /// Every registered profile that has a directory for `provider`, in registry order.
    static func all(provider: String) -> [TangitUsageProfile] {
        let registry = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/tangit/profiles.json")
        guard let data = try? Data(contentsOf: registry),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profiles = json["profiles"] as? [[String: Any]] else { return [] }
        return profiles.compactMap { ($0["name"] as? String).flatMap { resolve($0, provider: provider) } }
    }
}
