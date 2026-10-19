import Foundation

/// Read-only compatibility identifiers. New data must never use this namespace.
public enum LegacyBrand {
    public static let bundleIdentifier = "theboringteam.boringnotch"
    public static let supportName = "boringNotch"
    public static let shelfPreference = "boringShelf"
    public static let runtimeLabels = [bundleIdentifier + ".calla-node", bundleIdentifier + ".calla-runtime"]
    public static let installedApp = "/Applications/boringNotch.app"
    public static let cli = "boring-notch"
}
