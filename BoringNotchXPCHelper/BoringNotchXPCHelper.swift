import OSLog
//
//  BoringNotchXPCHelper.swift
//  BoringNotchXPCHelper
//
//  Created by Alexander on 2025-11-16.
//

import Foundation
import AppKit
import ApplicationServices
import IOKit
import CoreGraphics

class BoringNotchXPCHelper: NSObject, BoringNotchXPCHelperProtocol {
    
    /// Only the active Zen document matching the system media title is eligible.
    /// Uses existing Accessibility authorization without prompting or reading history.
    @objc func zenYouTubeArtworkURL(_ title: String, with reply: @escaping (String?) -> Void) {
        guard AXIsProcessTrusted(), !title.isEmpty, title.count < 1000 else { Logger(subsystem: "theboringteam.boringnotch", category: "artwork").notice("Zen artwork: accessibility unavailable or title invalid"); reply(nil); return }
        DispatchQueue.main.async {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "app.zen-browser.zen").first else { reply(nil); return }
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.25)
            func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
                var result: CFTypeRef?
                return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
            }
            // Firefox-family browsers may expose no focused window while the
            // notch is active. Match a window title before reading its document.
            var windows = attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
            if let focused = attribute(root, kAXFocusedWindowAttribute),
               CFGetTypeID(focused) == AXUIElementGetTypeID() {
                windows.insert(unsafeBitCast(focused, to: AXUIElement.self), at: 0)
            }
            guard let window = windows.first(where: {
                (attribute($0, kAXTitleAttribute) as? String)?.contains(title) == true
            }) else { Logger(subsystem: "theboringteam.boringnotch", category: "artwork").notice("Zen artwork: no matching accessible window"); reply(nil); return }
            var queue = [window]
            let deadline = Date().addingTimeInterval(1)
            var index = 0
            while index < queue.count && index < 250 && Date() < deadline {
                let element = queue[index]; index += 1
                let role = attribute(element, kAXRoleAttribute) as? String
                if role == "AXWebArea" {
                    let pageTitle = [attribute(element, kAXTitleAttribute) as? String,
                                     attribute(element, kAXDescriptionAttribute) as? String]
                        .compactMap { $0 }.first(where: { !$0.isEmpty }) ?? ""
                    guard pageTitle.isEmpty || pageTitle.contains(title) else {
                        Logger(subsystem: "theboringteam.boringnotch", category: "artwork").notice("Zen artwork: web document title did not match")
                        continue
                    }
                    let raw = attribute(element, kAXURLAttribute)
                    let address = (raw as? URL)?.absoluteString ?? (raw as? String) ?? ""
                    guard let url = URL(string: address),
                          let host = url.host?.lowercased(), ["youtube.com", "www.youtube.com", "m.youtube.com"].contains(host),
                          url.path == "/watch",
                          let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value,
                          id.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil else { continue }
                    Logger(subsystem: "theboringteam.boringnotch", category: "artwork").notice("Zen artwork: matched active YouTube document")
                    reply("https://i.ytimg.com/vi/\(id)/hqdefault.jpg")
                    return
                }
                if let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
                    queue.append(contentsOf: children.prefix(250 - min(queue.count, 250)))
                }
            }
            Logger(subsystem: "theboringteam.boringnotch", category: "artwork").notice("Zen artwork: no matching document after \(index) nodes")
            reply(nil)
        }
    }

    @objc func isAccessibilityAuthorized(with reply: @escaping (Bool) -> Void) {
        reply(AXIsProcessTrusted())
    }

    @objc func requestAccessibilityAuthorization() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    @objc func ensureAccessibilityAuthorization(_ promptIfNeeded: Bool, with reply: @escaping (Bool) -> Void) {
        if AXIsProcessTrusted() {
            reply(true)
            return
        }

        if promptIfNeeded {
            requestAccessibilityAuthorization()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            reply(AXIsProcessTrusted())
        }
    }
    
    private class KeyboardBrightnessClient {
        private static let keyboardID: UInt64 = 1
        private var clientInstance: NSObject?
        private let getSelector = NSSelectorFromString("brightnessForKeyboard:")
        private let setSelector = NSSelectorFromString("setBrightness:forKeyboard:")

        init() {
            var loaded = false
            let bundlePaths = [
                "/System/Library/PrivateFrameworks/CoreBrightness.framework",
                "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"
            ]
            for path in bundlePaths where !loaded {
                if let bundle = Bundle(path: path) {
                    loaded = bundle.load()
                }
            }
            if loaded, let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type {
                clientInstance = cls.init()
            }
        }

        var isAvailable: Bool { clientInstance != nil }

        func currentBrightness() -> Float? {
            guard let clientInstance,
                  let fn: BrightnessGetter = methodIMP(on: clientInstance, selector: getSelector, as: BrightnessGetter.self)
            else { return nil }
            return fn(clientInstance, getSelector, Self.keyboardID)
        }

        func setBrightness(_ value: Float) -> Bool {
            guard let clientInstance,
                  let fn: BrightnessSetter = methodIMP(on: clientInstance, selector: setSelector, as: BrightnessSetter.self)
            else { return false }
            return fn(clientInstance, setSelector, value, Self.keyboardID).boolValue
        }

        private typealias BrightnessGetter = @convention(c) (NSObject, Selector, UInt64) -> Float
        private typealias BrightnessSetter = @convention(c) (NSObject, Selector, Float, UInt64) -> ObjCBool

        private func methodIMP<T>(on object: NSObject, selector: Selector, as type: T.Type) -> T? {
            guard let cls = object_getClass(object),
                  let method = class_getInstanceMethod(cls, selector)
            else { return nil }
            let imp = method_getImplementation(method)
            return unsafeBitCast(imp, to: type)
        }
    }

    private static let keyboardClient = KeyboardBrightnessClient()

    @objc func isKeyboardBrightnessAvailable(with reply: @escaping (Bool) -> Void) {
        reply(Self.keyboardClient.isAvailable)
    }

    @objc func currentKeyboardBrightness(with reply: @escaping (NSNumber?) -> Void) {
        reply(Self.keyboardClient.currentBrightness().map { NSNumber(value: $0) })
    }

    @objc func setKeyboardBrightness(_ value: Float, with reply: @escaping (Bool) -> Void) {
        reply(Self.keyboardClient.setBrightness(value))
    }
    // MARK: - Screen Brightness (moved from client app into helper)

    @objc func isScreenBrightnessAvailable(with reply: @escaping (Bool) -> Void) {
        var b: Float = 0
        reply(displayServicesGetBrightness(displayID: CGMainDisplayID(), out: &b) || ioServiceFor(displayID: CGMainDisplayID()) != nil)
    }

    @objc func currentScreenBrightness(with reply: @escaping (NSNumber?) -> Void) {
        var b: Float = 0
        if displayServicesGetBrightness(displayID: CGMainDisplayID(), out: &b) {
            reply(NSNumber(value: b))
            return
        }
        if let io = ioServiceFor(displayID: CGMainDisplayID()) {
            var level: Float = 0
            if IODisplayGetFloatParameter(io, 0, kIODisplayBrightnessKey as CFString, &level) == kIOReturnSuccess {
                IOObjectRelease(io)
                reply(NSNumber(value: level))
                return
            }
            IOObjectRelease(io)
        }
        reply(nil)
    }

    @objc func setScreenBrightness(_ value: Float, with reply: @escaping (Bool) -> Void) {
        let clamped = max(0, min(1, value))
        if displayServicesSetBrightness(displayID: CGMainDisplayID(), value: clamped) {
            reply(true)
            return
        }
        if let io = ioServiceFor(displayID: CGMainDisplayID()) {
            let ok = IODisplaySetFloatParameter(io, 0, kIODisplayBrightnessKey as CFString, clamped) == kIOReturnSuccess
            IOObjectRelease(io)
            reply(ok)
            return
        }
        reply(false)
    }

    // MARK: - CLI Usage Probing

    @objc func fetchUsage(_ provider: String, securitySessionID: String?, with reply: @escaping (Data?) -> Void) {
        // Hop off the serial XPC message queue — the Claude probe can take ~20s
        // and must not block brightness/accessibility calls on the same connection.
        Task.detached {
            let dto = await UsageProbeService.shared.fetchUsage(provider: provider, securitySessionID: securitySessionID)
            reply(try? UsageReportDTO.encoder.encode(dto))
        }
    }

    // MARK: - Private helpers for DisplayServices / IOKit access
    private func displayServicesGetBrightness(displayID: CGDirectDisplayID, out: inout Float) -> Bool {
        guard let sym = dlsym(DisplayServicesHandle.handle, "DisplayServicesGetBrightness") else { return false }
        typealias Fn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
        let fn = unsafeBitCast(sym, to: Fn.self)
        var tmp: Float = 0
        let r = fn(displayID, &tmp)
        if r == 0 { out = tmp; return true }
        return false
    }

    private func displayServicesSetBrightness(displayID: CGDirectDisplayID, value: Float) -> Bool {
        guard let sym = dlsym(DisplayServicesHandle.handle, "DisplayServicesSetBrightness") else { return false }
        typealias Fn = @convention(c) (CGDirectDisplayID, Float) -> Int32
        let fn = unsafeBitCast(sym, to: Fn.self)
        return fn(displayID, value) == 0
    }

    private func ioServiceFor(displayID: CGDirectDisplayID) -> io_service_t? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iterator) == kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            let info = IODisplayCreateInfoDictionary(service, 0).takeRetainedValue() as NSDictionary
            if let vendorID = info[kDisplayVendorID] as? UInt32,
               let productID = info[kDisplayProductID] as? UInt32,
               vendorID == CGDisplayVendorNumber(displayID),
               productID == CGDisplayModelNumber(displayID) {
                return service
            }
            IOObjectRelease(service)
        }
        return nil
    }

    // MARK: - Helper handle for private framework
    private enum DisplayServicesHandle {
        static let handle: UnsafeMutableRawPointer? = {
            let paths = [
                "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
                "/System/Library/PrivateFrameworks/DisplayServices.framework/Versions/Current/DisplayServices"
            ]
            for p in paths {
                if let h = dlopen(p, RTLD_LAZY) { return h }
            }
            return nil
        }()
    }
}
