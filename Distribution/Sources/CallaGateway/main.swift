import DistributionCore
import Foundation

let files = FileManager.default
let args = Array(CommandLine.arguments.dropFirst())
let tailscale = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
let target = "isnakolah@nomonhomelab.tailec0dca.ts.net"

func remote(_ script: String, input: Data? = nil, timeout: TimeInterval = 60) throws -> String {
    guard files.isExecutableFile(atPath: tailscale) else {
        throw SetupFailure("Tailscale is not installed. Run calla.notch setup to connect the optional Gateway.")
    }
    return try Commands.run(tailscale, ["ssh", target, script], input: input, timeout: timeout).output
}

func emit(_ data: Data) { FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8)) }

do {
    guard let action = args.first else { throw SetupFailure("Usage: calla-gateway check | update <archive>") }
    let enabledURL = Layout.support.appendingPathComponent("Calla/gateway-enabled.json")
    let enabled = (try? JSONSerialization.jsonObject(with: Data(contentsOf: enabledURL)) as? [String: Bool])?["enabled"] == true
    if action == "manifest-digest" {
        guard args.count == 2 else { throw SetupFailure("Missing archive.") }
        let manifest = try Commands.run("/usr/bin/tar", ["-xOf", args[1], "release/manifest.json"]).output
        guard let object = try JSONSerialization.jsonObject(with: Data(manifest.utf8)) as? [String: Any],
              let digest = object["gatewayDigest"] as? String, digest.count == 64,
              digest.allSatisfy({ $0.isHexDigit }) else { throw SetupFailure("Invalid Gateway manifest.") }
        print(digest)
    } else if !enabled && !(action == "check" && args.contains("--setup")) {
        emit(Data("{\"ok\":false,\"code\":\"GATEWAY_DISABLED\",\"summary\":\"Gateway skipped. Run calla.notch setup to connect it.\"}".utf8))
        exit(action == "check" ? 0 : 78)
    } else {
        switch action {
        case "check":
            // Calls use the Gateway only as an optional answer fallback, so
            // readiness is the Gateway process itself.
            let script = #"""
            export PATH="$HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin"
            if ! command -v openclaw >/dev/null 2>&1; then printf '{"ok":false,"summary":"OpenClaw is not installed on Gateway."}\n'; exit 0; fi
            gateway=false
            timeout 12 openclaw gateway status >/dev/null 2>&1 && gateway=true
            printf '{"ok":%s,"gateway":%s}\n' "$gateway" "$gateway"
            """#
            print(try remote(script, timeout: 60), terminator: "")
        case "update":
            guard args.count == 2 else { throw SetupFailure("Missing Gateway archive.") }
            let archive = URL(fileURLWithPath: args[1])
            let digest = try Checksums.digest(archive)
            let remoteFile = "$HOME/.openclaw/apps/calla-tutor/incoming/" + digest + ".tar.gz"
            _ = try remote("umask 077; mkdir -p \"$HOME/.openclaw/apps/calla-tutor/incoming\"; cat > \"" + remoteFile + "\"", input: Data(contentsOf: archive), timeout: 600)
            // Python and OpenClaw run exclusively on the existing Linux Gateway.
            let script = #"""
            set -euo pipefail
            export PATH="$HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin"
            root="$HOME/.openclaw/apps/calla-tutor"
            archive="$root/incoming/DIGEST.tar.gz"
            test "$(sha256sum "$archive" | cut -d' ' -f1)" = DIGEST
            stage=$(mktemp -d "$root/incoming/.stage.XXXXXX")
            trap 'rm -rf "$stage"' EXIT
            tar -xzf "$archive" -C "$stage"
            if [ -f "$root/current/manifest.json" ] && cmp -s "$stage/release/manifest.json" "$root/current/manifest.json"; then
              result=unchanged
            else
              config=$(openclaw config file | tail -1)
              python3 "$stage/release/bin/calla_gateway_release.py" --staged "$stage/release" --config "$config" --root "$root"
              result=updated
            fi
            current=$(basename "$(readlink -f "$root/current")")
            previous=$(basename "$(readlink -f "$root/previous")")
            printf 'CALLA_GATEWAY_RESULT\t%s\t%s\t%s\n' "$result" "$current" "$previous"
            """#.replacingOccurrences(of: "DIGEST", with: digest)
            print(try remote("/bin/bash -c " + Commands.shellQuote(script), timeout: 600), terminator: "")
        default: throw SetupFailure("Unknown Gateway command.")
        }
    }
} catch {
    let response: [String: Any] = ["ok": false, "code": "GATEWAY_UNAVAILABLE", "summary": error.localizedDescription]
    if let data = try? JSONSerialization.data(withJSONObject: response) { emit(data) }
    exit(1)
}
