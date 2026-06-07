//
//  WebExtensionMessageRouter+Ports.swift
//  BrownBear
//
//  chrome.runtime.connect / chrome.runtime.onConnect long-lived PORTS for the content/popup/options
//  side. Split into its own file so WebExtensionMessageRouter.swift stays under the file-length limit.
//  The router is the CLIENT endpoint of a port (a content script or an extension page): it relays the
//  JS port.connect/postMessage/disconnect calls into the shared WebExtensionPortHub (owned by the
//  runtime), and conversely evaluates the hub's onConnect/onMessage/onDisconnect callbacks back into the
//  endpoint's JS surface. The hub brokers the other end (the extension's background worker).
//
//  Everything here reaches the router's state only through the small internal accessors the main type
//  exposes (portDeliveryTarget / portContentWorld / encodeJSONForJS / resolveExtensionID) — the private
//  `sessions` table and `Session` type stay encapsulated in the primary file.
//

import WebKit

extension WebExtensionMessageRouter {

    /// chrome.runtime.connect/onConnect over the port hub. `port.connect` mints a port id (returned so
    /// the JS Port object can address the channel) and fires onConnect in the extension's background
    /// worker; `port.postMessage`/`port.disconnect` relay opaquely to the peer. The token resolves the
    /// extension + this endpoint's identity, so a script can only open/use ports for its own extension.
    func routePort(api: String, payload: [String: Any], token: String?) async throws -> Any? {
        let extensionID = try await resolveExtensionID(token)
        guard let token else { throw BrownBearError.bridgeRejected("port call missing token") }
        let hub = BrownBearServices.shared.webExtensionRuntime.portHub
        switch api {
        case "port.connect":
            let name = (payload["name"] as? String) ?? ""
            // The sender object the worker's onConnect Port.sender exposes: the extension id and the
            // originating URL (if the endpoint provided one). Frame ids are main-frame on iOS.
            var sender: [String: Any] = ["id": extensionID]
            if let url = payload["url"] as? String { sender["url"] = url }
            let portId = hub.connectFromClient(extensionID: extensionID, name: name,
                                               initiatorToken: token, initiatorClient: self,
                                               senderJSON: Self.encodeJSONForJS(sender))
            return ["portId": portId]

        case "port.postMessage":
            guard let portId = payload["portId"] as? String else {
                throw BrownBearError.bridgeRejected("port.postMessage missing portId")
            }
            hub.postMessage(portId: portId, fromBackground: false,
                            messageJSON: Self.encodeJSONForJS(payload["message"] ?? NSNull()))
            return NSNull()

        case "port.disconnect":
            guard let portId = payload["portId"] as? String else {
                throw BrownBearError.bridgeRejected("port.disconnect missing portId")
            }
            hub.disconnect(portId: portId, fromBackground: false)
            return NSNull()

        default:
            throw BrownBearError.bridgeRejected("unsupported port api '\(api)'")
        }
    }
}

// MARK: - WebExtensionPortClient (deliver port callbacks into a content/page endpoint)
//
// The port hub hands the router a session token + port id; the router evaluates the matching push into
// the endpoint's JS surface. A content endpoint exposes window.__bbExtContent[token]; a page/popup
// endpoint exposes window.__brownbearExtPage. Both go through the BBWebKitBridge ObjC shim, never the
// Swift WebKit overlay (iOS 16.4 crash). A dead/gone session silently drops (the hub then reaps it).
extension WebExtensionMessageRouter: WebExtensionPortClient {

    func deliverPortConnect(token: String, portId: String, name: String, senderJSON: String) {
        evaluatePortPush(token: token, call: "onPortConnect",
                         args: "\(jsLiteral(portId)),\(Self.encodeJSONForJS(name)),\(senderJSON)")
    }

    func deliverPortMessage(token: String, portId: String, messageJSON: String) {
        evaluatePortPush(token: token, call: "onPortMessage", args: "\(jsLiteral(portId)),\(messageJSON)")
    }

    func deliverPortDisconnect(token: String, portId: String) {
        evaluatePortPush(token: token, call: "onPortDisconnect", args: jsLiteral(portId))
    }

    /// Evaluate one port callback into the endpoint registered under `token`. Content endpoints are
    /// keyed by token under window.__bbExtContent; page/popup endpoints expose window.__brownbearExtPage.
    private func evaluatePortPush(token: String, call: String, args: String) {
        guard let target = portDeliveryTarget(token: token) else { return }
        let js: String
        if target.isContent {
            js = "window.__bbExtContent&&window.__bbExtContent[\(jsLiteral(token))]&&"
                + "window.__bbExtContent[\(jsLiteral(token))].\(call)(\(args));"
        } else {
            js = "window.__brownbearExtPage&&window.__brownbearExtPage.\(call)(\(args));"
        }
        BBEvaluateJavaScriptInFrame(target.webView, js, target.frame, portContentWorld)
    }

    /// A safe JS string literal (quotes included) for an id/token we control — encoded via JSON so a
    /// pathological value can never break out of the evaluated expression.
    private func jsLiteral(_ value: String) -> String { Self.encodeJSONForJS(value) }
}
