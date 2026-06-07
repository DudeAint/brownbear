//
//  WebExtensionBackgroundContext+Ports.swift
//  BrownBear
//
//  The background worker's side of chrome.runtime.connect / chrome.runtime.onConnect long-lived PORTS.
//  Split into its own file so WebExtensionBackgroundContext.swift stays under the file-length limit.
//  The worker is the usual RESPONDER: a content script or extension page connects, and the hub fires
//  onConnect here; the worker then relays postMessage/disconnect back to that peer over the __bb_port_*
//  natives. Everything reaches the context's private JS queue only through the internal helpers the
//  primary type exposes (firePortDispatch / encodePortJSON).
//

import Foundation
import JavaScriptCore

extension WebExtensionBackgroundContext {

    /// The native blocks the worker's port objects call: relay a message to the peer endpoint, and
    /// disconnect a port. Both hop to the main actor to reach the shared port hub, which forwards to the
    /// other endpoint (the content script / page that opened the port). The worker has no token, so it
    /// addresses ports purely by the unguessable port id the hub minted on connect.
    func installPortNatives(into context: JSContext) {
        let post: @convention(block) (String, String) -> Void = { portId, messageJSON in
            Task { @MainActor in
                BrownBearServices.shared.webExtensionRuntime.portHub
                    .postMessage(portId: portId, fromBackground: true, messageJSON: messageJSON)
            }
        }
        context.setObject(post, forKeyedSubscript: "__bb_port_post" as NSString)

        let disconnect: @convention(block) (String) -> Void = { portId in
            Task { @MainActor in
                BrownBearServices.shared.webExtensionRuntime.portHub
                    .disconnect(portId: portId, fromBackground: true)
            }
        }
        context.setObject(disconnect, forKeyedSubscript: "__bb_port_disconnect" as NSString)
    }

    /// Native → worker: a content script or page opened a port to this extension's worker. Fires
    /// chrome.runtime.onConnect(port) inside the worker with the given port id, name, and sender. `name`
    /// is JSON-encoded so the JS dispatcher can _JSON.parse it (the sender JSON is already a JSON string).
    func dispatchPortConnect(portId: String, name: String, senderJSON: String) {
        firePortDispatch(method: "dispatchPortConnect",
                         arguments: [portId, encodePortJSON(name), senderJSON])
    }

    /// Native → worker: the peer posted a message on `portId`. Fires that port's onMessage listeners.
    func dispatchPortMessage(portId: String, messageJSON: String) {
        firePortDispatch(method: "dispatchPortMessage", arguments: [portId, messageJSON])
    }

    /// Native → worker: the peer (or the hub on teardown) disconnected `portId`. Fires onDisconnect.
    func dispatchPortDisconnect(portId: String) {
        firePortDispatch(method: "dispatchPortDisconnect", arguments: [portId])
    }
}
