//
//  WebExtensionBackgroundContext+ModuleWorker.swift
//  BrownBear
//
//  Loads an MV3 service worker declared with `"background": { "type": "module" }` (e.g. uBlock Origin
//  Lite) via JavaScriptCore's ES-module loader. A classic worker is run with evaluateScript, but a
//  module worker can't be — its top-level `import`/`export` is a SyntaxError there ("import call
//  expects one or two arguments"). Split out of the main context file to stay under the length limit.
//

import Foundation
import JavaScriptCore

extension WebExtensionBackgroundContext {

    /// Evaluate `source` as an ES module in `context`, resolving its `import`s from the extension's own
    /// package (via the synchronous, traversal-guarded fileSync). `import`s of files outside this
    /// extension — or missing files — reject, exactly as a 404 would. Runs on the context's serial queue.
    func evaluateModuleWorker(_ source: String, into context: JSContext,
                              baseURL: String, workerPath: String?) {
        let extID = extensionID
        guard let entryURL = URL(string: baseURL + (workerPath ?? "background.js"))
                ?? URL(string: "brownbear://webext/\(extID)/background.js") else { return }
        var moduleError: NSError?
        let ok = BBEvaluateModuleScript(context, source, entryURL, { identifier in
            // Serve the resolved absolute module URL from THIS extension's package only.
            guard let url = URL(string: identifier), url.host == extID else { return nil }
            var path = url.path
            while path.hasPrefix("/") { path.removeFirst() }
            guard !path.isEmpty else { return nil }
            return BrownBearServices.shared.webExtensionStore
                .fileSync(extensionID: extID, path: path)
                .flatMap { String(data: $0, encoding: .utf8) }
        }, &moduleError)
        if !ok {
            logSink(makeLog(.error, "module service worker failed to load: \(moduleError?.localizedDescription ?? "unknown")"))
        }
    }
}
