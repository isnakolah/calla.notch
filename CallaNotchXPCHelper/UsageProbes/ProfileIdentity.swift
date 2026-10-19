import Foundation

/// Reads public identity fields only. Credential values never leave the profile.
enum ProfileIdentity {
    static func read(provider: String, directory: URL) -> String? {
        if provider == "claude" {
            let url = directory.appendingPathComponent(".claude.json")
            guard let data = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let account = root["oauthAccount"] as? [String: Any] else { return nil }
            return account["emailAddress"] as? String
        }
        let url = directory.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let token = tokens["id_token"] as? String else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        let payload = String(parts[1])
        let padded = payload + String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let decoded = Data(base64Encoded: padded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")),
              let json = try? JSONSerialization.jsonObject(with: decoded) as? [String: Any] else { return nil }
        return json["email"] as? String
    }
}
