//
//  WebExtensionPortHub.swift
//  BrownBear
//
//  The broker for chrome.runtime.connect / chrome.runtime.onConnect long-lived PORTS (Module 6).
//  A port is a named, bidirectional channel between an INITIATOR (a content script or an extension
//  page/popup) and a RESPONDER (the extension's background worker, which receives the connection via
//  chrome.runtime.onConnect). BrownBear has no real MessageChannel across the JS↔native boundary, so
//  we EMULATE one: the hub mints a stable port id, remembers both endpoints, and relays postMessage /
//  disconnect between them by evaluating into the right surface (content world, page world, or the
//  background JSContext).
//
//  Why the runtime owns it: the runtime is the single @MainActor object that already holds every
//  background context and reaches every surface's router. A content script's router, a popup's router,
//  and the background worker each call the hub through the runtime, so one table sees every endpoint.
//
//  Security: every relayed payload is opaque JSON that the hub never interprets — it only forwards.
//  An endpoint can only address the SPECIFIC port id it was handed (unguessable UUID), and a port is
//  scoped to one extension id: the responder is always that extension's own background worker, so a
//  script can never open a port into another extension. Closing a tab/page or disabling the extension
//  tears its ports down (the weak client/context references resolve nil and the port is reaped).
//

import Foundation

/// A surface that can deliver port lifecycle/data callbacks into one of its JS endpoints. The content
/// and popup routers conform (they evaluate into the content/page world); the background side is
/// handled by the runtime directly against the worker's JSContext, so it is not a client here.
@MainActor
protocol WebExtensionPortClient: AnyObject {
    /// Deliver `chrome.runtime.onConnect(port)` to the endpoint identified by `token` — used when the
    /// BACKGROUND worker initiates the connection toward a content/page endpoint (rare, but Chrome
    /// allows it). `name` is the developer-supplied port name; `senderJSON` is the JSON sender object.
    func deliverPortConnect(token: String, portId: String, name: String, senderJSON: String)
    /// Deliver `port.onMessage(message)` to the endpoint identified by `token`.
    func deliverPortMessage(token: String, portId: String, messageJSON: String)
    /// Deliver `port.onDisconnect()` to the endpoint identified by `token`.
    func deliverPortDisconnect(token: String, portId: String)
}

@MainActor
final class WebExtensionPortHub {

    /// One end of a port. A content/page endpoint is reached through its owning router (held weakly so
    /// a closed tab/dismissed popup can't pin it) plus its session token; the background endpoint is
    /// reached through the runtime against the extension's worker.
    private enum Endpoint {
        case client(token: String, client: WeakClient)
        case background(extensionID: String)
    }

    /// Weak box so a port can't keep a dead router (and thus a closed web view) alive.
    private final class WeakClient { weak var value: WebExtensionPortClient?; init(_ v: WebExtensionPortClient) { value = v } }

    /// A live port: the two endpoints and the extension it belongs to.
    private struct Port {
        let extensionID: String
        let name: String
        var initiator: Endpoint
        var responder: Endpoint
    }

    /// Delivers background-side callbacks (onConnect/onMessage/onDisconnect) into a worker's JSContext.
    /// The runtime sets this once it owns the contexts; without it, background endpoints silently drop
    /// (no worker means nothing could have connected anyway).
    weak var backgroundDeliverer: WebExtensionPortBackgroundDeliverer?

    private var ports: [String: Port] = [:]
    /// Cap so a runaway script can't mint unbounded ports; FIFO-evict the oldest when exceeded.
    private static let maxPorts = 4000
    private var portOrder: [String] = []

    // MARK: - Connect

    /// A content script or page/popup opened a port toward its extension's background worker.
    /// Mints a port id, records both endpoints, and fires chrome.runtime.onConnect in the worker with a
    /// Port whose .sender is `senderJSON`. Returns the new port id so the initiator can address it.
    func connectFromClient(extensionID: String, name: String, initiatorToken: String,
                           initiatorClient: WebExtensionPortClient, senderJSON: String) -> String {
        let portId = UUID().uuidString
        let port = Port(extensionID: extensionID, name: name,
                        initiator: .client(token: initiatorToken, client: WeakClient(initiatorClient)),
                        responder: .background(extensionID: extensionID))
        register(portId: portId, port: port)
        // The worker receives the connection; the initiator already has its Port object client-side.
        backgroundDeliverer?.deliverPortConnect(extensionID: extensionID, portId: portId,
                                                name: name, senderJSON: senderJSON)
        return portId
    }

    // MARK: - Message / disconnect (called from either endpoint)

    /// Relay a postMessage from `senderPortId`'s sender side to its peer. `fromBackground` disambiguates
    /// which endpoint sent it (the background worker has no token, so it can't be matched by token).
    func postMessage(portId: String, fromBackground: Bool, messageJSON: String) {
        guard let port = ports[portId] else { return }
        let target = fromBackground ? port.initiator : port.responder
        deliver(.message(messageJSON), to: target, portId: portId)
    }

    /// Relay a disconnect from one endpoint: notify the peer and reap the port. Idempotent.
    func disconnect(portId: String, fromBackground: Bool) {
        guard let port = ports.removeValue(forKey: portId) else { return }
        portOrder.removeAll { $0 == portId }
        let peer = fromBackground ? port.initiator : port.responder
        deliver(.disconnect, to: peer, portId: portId)
    }

    /// A content script's frame went away (its session token was purged on navigation) or a popup was
    /// dismissed: drop every port whose client endpoint is one of `tokens`, and notify the surviving peer
    /// (the worker's onDisconnect). Ports are also reaped lazily when a delivery finds a nil router.
    func disconnectClientPorts(tokens: Set<String>) {
        guard !tokens.isEmpty else { return }
        let doomed = ports.filter { _, port in
            if case let .client(token, _) = port.initiator, tokens.contains(token) { return true }
            if case let .client(token, _) = port.responder, tokens.contains(token) { return true }
            return false
        }
        for (portId, port) in doomed {
            // The surviving peer is whichever endpoint is NOT the doomed client.
            let clientIsInitiator: Bool = { if case let .client(token, _) = port.initiator { return tokens.contains(token) }; return false }()
            ports.removeValue(forKey: portId)
            portOrder.removeAll { $0 == portId }
            deliver(.disconnect, to: clientIsInitiator ? port.responder : port.initiator, portId: portId)
        }
    }

    // MARK: - Delivery

    private enum Push { case connect(name: String, senderJSON: String); case message(String); case disconnect }

    private func deliver(_ push: Push, to endpoint: Endpoint, portId: String) {
        switch endpoint {
        case let .client(token, weakClient):
            guard let client = weakClient.value else { reap(portId); return }
            switch push {
            case let .connect(name, senderJSON):
                client.deliverPortConnect(token: token, portId: portId, name: name, senderJSON: senderJSON)
            case let .message(messageJSON):
                client.deliverPortMessage(token: token, portId: portId, messageJSON: messageJSON)
            case .disconnect:
                client.deliverPortDisconnect(token: token, portId: portId)
            }
        case let .background(extensionID):
            switch push {
            case let .connect(name, senderJSON):
                backgroundDeliverer?.deliverPortConnect(extensionID: extensionID, portId: portId,
                                                        name: name, senderJSON: senderJSON)
            case let .message(messageJSON):
                backgroundDeliverer?.deliverPortMessage(extensionID: extensionID, portId: portId, messageJSON: messageJSON)
            case .disconnect:
                backgroundDeliverer?.deliverPortDisconnect(extensionID: extensionID, portId: portId)
            }
        }
    }

    // MARK: - Bookkeeping

    private func register(portId: String, port: Port) {
        ports[portId] = port
        portOrder.append(portId)
        guard portOrder.count > Self.maxPorts else { return }
        let evicted = portOrder.removeFirst()
        if let stale = ports.removeValue(forKey: evicted) {
            // Notify both ends so neither side strands a listener on the evicted channel.
            deliver(.disconnect, to: stale.initiator, portId: evicted)
            deliver(.disconnect, to: stale.responder, portId: evicted)
        }
    }

    private func reap(_ portId: String) {
        ports.removeValue(forKey: portId)
        portOrder.removeAll { $0 == portId }
    }
}

/// The runtime's adapter for delivering background-side port callbacks into a worker's JSContext.
/// Implemented by WebExtensionRuntime, which routes to the WebExtensionBackgroundContext for the
/// extension. Kept as a protocol so the hub never imports JavaScriptCore or touches a context directly.
@MainActor
protocol WebExtensionPortBackgroundDeliverer: AnyObject {
    func deliverPortConnect(extensionID: String, portId: String, name: String, senderJSON: String)
    func deliverPortMessage(extensionID: String, portId: String, messageJSON: String)
    func deliverPortDisconnect(extensionID: String, portId: String)
}
