import Darwin
import Foundation

/// Product identity shared by the app, its XPC services, and distribution tools.
public enum CallaBrand {
    public static let name = "calla.notch"
    public static let bundleIdentifier = "org.calla.notch"
    public static let engineService = bundleIdentifier + ".CallaEngine"
    public static let helperService = bundleIdentifier + ".CallaNotchXPCHelper"
    public static let setupScheme = "callanotch-setup"
    public static let setupCommand = "calla-notch"
    public static let installedApp = URL(fileURLWithPath: "/Applications/calla.notch.app")
    public static var userHome: URL {
        URL(fileURLWithPath: String(cString: getpwuid(getuid()).pointee.pw_dir), isDirectory: true)
    }
    public static func support(in home: URL = userHome) -> URL {
        home.appendingPathComponent("Library/Application Support/" + name, isDirectory: true)
    }
}
