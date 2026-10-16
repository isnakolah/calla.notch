import Foundation

/// A network error is not a request to sign in again. Check the actual Google
/// endpoint without credentials before starting a process which may offer OAuth.
public enum AgyConnectivity {
    public static func canReachGoogle() async -> Bool {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 6
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://accounts.google.com/.well-known/openid-configuration")!
        do {
            let (data, response) = try await session.data(from: url)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  let metadata = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return false }
            return metadata["issuer"] as? String == "https://accounts.google.com"
        } catch { return false }
    }
}
