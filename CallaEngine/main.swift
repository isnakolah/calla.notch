import AppKit
import CallaContracts
import Darwin
import Foundation

// A warmed Quiz worker may exit between readiness and dispatch (expired auth,
// quota, model withdrawal). Writing to its closed stdin must become a normal
// EPIPE error handled by the worker pool, never terminate the entire XPC engine.
signal(SIGPIPE, SIG_IGN)

if Array(CommandLine.arguments.dropFirst()) == ["--migrate-branding"] {
    do {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: LegacyBrand.bundleIdentifier).isEmpty else {
            throw BrandMigration.Failure("Finish active work and quit the previous app before migrating.")
        }
        let migration = BrandMigration()
        _ = try migration.run(includePreferences: false)
        try migration.finalizeInstalledIdentity()
        print("calla.notch data migration complete")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
        exit(78)
    }
}

if Array(CommandLine.arguments.dropFirst()) == ["--prepare-quiz-key"] {
    do {
        _ = try QuizHistoryKey.loadOrCreate(allowBootstrap: false)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Quiz key preparation failed\n".utf8))
        exit(78)
    }
}

private final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let engine = CallaEngine()
        connection.exportedInterface = NSXPCInterface(with: CallaEngineProtocol.self)
        connection.exportedInterface?.setInterface(
            NSXPCInterface(with: CallaEngineStatusObserver.self),
            for: #selector(CallaEngineProtocol.subscribeStatus(_:with:)), argumentIndex: 0, ofReply: false)
        connection.exportedInterface?.setInterface(
            NSXPCInterface(with: CallaEngineCallObserver.self),
            for: #selector(CallaEngineProtocol.subscribeCallEvents(_:with:)), argumentIndex: 0, ofReply: false)
        connection.exportedInterface?.setInterface(
            NSXPCInterface(with: CallaEngineCodingObserver.self),
            for: #selector(CallaEngineProtocol.subscribeCodingEvents(_:with:)), argumentIndex: 0, ofReply: false)
        connection.exportedObject = engine
        // A quit, a force quit and a crash all end the same way from here: the
        // connection dies. Without this, whatever the engine started — the call
        // host holding the microphone, a resident `agy` language server holding
        // ~190MB — is reparented to launchd and runs until the machine restarts.
        connection.invalidationHandler = { [weak self] in
            engine.shutdownEverything()
            self?.connectionEnded()
        }
        connection.interruptionHandler = { engine.shutdownEverything() }
        lock.lock(); liveConnections += 1; lock.unlock()
        connection.resume()
        return true
    }

    private let lock = NSLock()
    private var liveConnections = 0

    /// The app is this service's only client. Once its last connection is gone
    /// the service has no reason to exist, and staying around under launchd is
    /// exactly the "one process outlives the app" this is meant to prevent.
    /// launchd starts it again on the next connection.
    private func connectionEnded() {
        lock.lock(); liveConnections -= 1; let remaining = liveConnections; lock.unlock()
        guard remaining <= 0 else { return }
        NSLog("[CallaEngine] last client gone; exiting")
        exit(0)
    }
}

private let delegate = ServiceDelegate()
private let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
