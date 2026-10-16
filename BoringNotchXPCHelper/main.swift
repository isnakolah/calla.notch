//
//  main.swift
//  BoringNotchXPCHelper
//
//  Created by Alexander on 2025-11-16.
//

import Foundation

class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    
    /// This method is where the NSXPCListener configures, accepts, and resumes a new incoming NSXPCConnection.
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        
        // Configure the connection.
        // First, set the interface that the exported object implements.
        newConnection.exportedInterface = NSXPCInterface(with: (any BoringNotchXPCHelperProtocol).self)
        
        // Next, set the object that the connection exports. All messages sent on the connection to this service will be sent to the exported object to handle. The connection retains the exported object.
        let exportedObject = BoringNotchXPCHelper()
        newConnection.exportedObject = exportedObject
        
        // The app is the only client: when its last connection goes, so does this
        // service (and any probe it is running), instead of lingering under launchd.
        newConnection.invalidationHandler = { [weak self] in self?.connectionEnded() }
        lock.lock(); liveConnections += 1; lock.unlock()

        // Resuming the connection allows the system to deliver more incoming messages.
        newConnection.resume()
        
        // Returning true from this method tells the system that you have accepted this connection. If you want to reject the connection for some reason, call invalidate() on the connection and return false.
        return true
    }

    private let lock = NSLock()
    private var liveConnections = 0

    private func connectionEnded() {
        lock.lock(); liveConnections -= 1; let remaining = liveConnections; lock.unlock()
        if remaining <= 0 { exit(0) }
    }
}

// Create the delegate for the service.
let delegate = ServiceDelegate()

// Set up the one NSXPCListener for this service. It will handle all incoming connections.
let listener = NSXPCListener.service()
listener.delegate = delegate

// Resuming the serviceListener starts this service. This method does not return.
listener.resume()
