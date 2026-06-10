//
//  WebExtensionPageModuleBundler.swift
//  BrownBear
//
//  An extension page (popup / options / dashboard) can load its JS as ES modules —
//  `<script src="js/popup.js" type="module">` with static `import`/`export` (uBlock Origin Lite's
//  popup and dashboard do exactly this). WKWebView will NOT load a module script over our custom
//  `chrome-extension://` scheme — the scheme isn't a module-eligible "secure" context, and the only
//  switch is a private API we can't ship — so the page renders BLANK even though it works in Chrome.
//
//  We fix it the same way we run MV3 module service workers (WebExtensionBackgroundContext+ModuleWorker):
//  PRE-LINK the page's module graph into ONE classic script and serve that. Because the MV3 default CSP
//  (`script-src 'self'`) forbids inline scripts, we don't inline the bundle — we serve it as a
//  same-origin resource under a synthetic `__bb-page-bundle/<hash>.js` path (allowed by `'self'`) and
//  rewrite the page's first module `<script>` to reference it (dropping the rest, since all module
//  scripts on a page share one module map — the bundle runs them in document order).
//
//  Pure serve-time work: a throwaway JSContext loads acorn + the ESM linker + the page bundler, the
//  graph is read synchronously and path-contained via the store's `nonisolated fileSync`, and the
//  result is cached per (extension, page, sources). ANY failure returns nil → the scheme handler serves
//  the raw HTML unchanged (fail-open to current behavior, never worse than today).
//

import Foundation
import JavaScriptCore

enum WebExtensionPageModuleBundler {

    /// Synthetic path prefix under which pre-linked page bundles are served. Same-origin, so it satisfies
    /// a `script-src 'self'` CSP exactly as a packaged `js/*.js` would.
    static let bundlePathPrefix = "__bb-page-bundle/"

    private static let lock = NSLock()
    /// "extID\u{1}synthPath" -> generated bundle JS (served when the page requests the synthetic script).
    private static var bundles: [String: String] = [:]
    /// "extID\u{1}htmlPath\u{1}srcKey" -> rewritten HTML, or `.some(nil)` memo for "nothing to rewrite".
    /// Keyed by the module-script sources so an extension update (new id) or edited page recomputes.
    private static var htmlRewrites: [String: String?] = [:]

    // MARK: - Serving a generated bundle

    /// If `path` names a bundle we previously generated for this extension, return its JS. The scheme
    /// handler calls this BEFORE touching the package, so the synthetic script resolves without a file.
    static func cachedBundle(extensionID: String, path: String) -> String? {
        guard path.hasPrefix(bundlePathPrefix) else { return nil }
        lock.lock(); defer { lock.unlock() }
        return bundles[key(extensionID, path)]
    }

    // MARK: - Rewriting an HTML page

    /// Pre-link the module graph referenced by `html` (the page at `htmlPath` in extension `extensionID`)
    /// and return HTML whose module scripts are replaced by a reference to a same-origin classic bundle.
    /// Returns nil when there is nothing to do (no external module scripts) or it cannot be safely
    /// pre-linked (inline module script present, a graph read fails, the linker throws) — the caller then
    /// serves the original HTML untouched. `moduleSource` reads a packaged module synchronously and
    /// path-contained; `log` surfaces a skipped/failed pre-link to the Logs tab.
    static func rewrittenHTML(extensionID: String,
                              htmlPath: String,
                              html: String,
                              scheme: String = WebExtensionSchemeHandler.scheme,
                              moduleSource: @escaping @Sendable (String) -> Data?,
                              log: (_ level: String, _ message: String) -> Void) -> String? {
        let scripts = moduleScripts(in: html)
        guard !scripts.isEmpty else { return nil }   // no module scripts → nothing for us to do

        // An inline module script (`<script type="module">CODE</script>`) has no packaged file to read;
        // we can't pre-link it yet. Rather than mangle the page, serve it raw and say so (it would also
        // fail under a 'self' CSP in Chrome, so this is an honest, diagnosable boundary).
        if scripts.contains(where: { $0.src == nil }) {
            log("warn", "\(htmlPath): inline `<script type=module>` can't be pre-linked yet — page served unmodified")
            return nil
        }

        let srcs = scripts.compactMap { $0.src }
        let srcKey = srcs.joined(separator: "\u{1}")
        let rewriteKey = key(extensionID, htmlPath, srcKey)

        lock.lock()
        if let memo = htmlRewrites[rewriteKey] {
            lock.unlock()
            return memo                              // cached rewrite (or cached "nothing to do" = nil)
        }
        lock.unlock()

        // Build the classic bundle in a throwaway JSContext.
        guard let bundleJS = buildBundle(extensionID: extensionID, htmlPath: htmlPath, srcs: srcs,
                                         scheme: scheme, moduleSource: moduleSource, log: log) else {
            lock.lock(); htmlRewrites[rewriteKey] = .some(nil); lock.unlock()   // memo the no-op
            return nil
        }

        let synthPath = bundlePathPrefix + fnv1aHex(srcKey + "\u{1}" + htmlPath) + ".js"
        let rewritten = rewriteHTML(html, scripts: scripts, bundleHref: "/" + synthPath)

        lock.lock()
        bundles[key(extensionID, synthPath)] = bundleJS
        htmlRewrites[rewriteKey] = .some(rewritten)
        lock.unlock()
        return rewritten
    }

    // MARK: - Bundle generation (JSContext)

    private static func buildBundle(extensionID: String,
                                    htmlPath: String,
                                    srcs: [String],
                                    scheme: String,
                                    moduleSource: @escaping @Sendable (String) -> Data?,
                                    log: (_ level: String, _ message: String) -> Void) -> String? {
        guard let context = JSContext() else { return nil }

        // Synchronous, path-contained package reader; a missing file becomes JS null → the linker fails
        // closed with "module not found", which bubbles up here and we fall back to the raw HTML.
        let resolveSource: @convention(block) (String) -> String? = { path in
            guard let data = moduleSource(path) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        context.setObject(resolveSource, forKeyedSubscript: "__bbModuleSource" as NSString)
        let baseURL = "\(scheme)://\(extensionID)/"
        context.setObject(baseURL as NSString, forKeyedSubscript: "__bbBgBaseURL" as NSString)

        context.evaluateScript(runtimeJS, withSourceURL: URL(string: "brownbear://webext/\(extensionID)/page-bundler.js"))
        if let exception = context.exception {
            log("warn", "\(htmlPath): page module pre-linker runtime failed to load (\(exception.toString() ?? "?")) — served raw")
            return nil
        }
        guard let bundler = context.objectForKeyedSubscript("__bbBundlePage"),
              !bundler.isUndefined, !bundler.isNull else {
            log("warn", "\(htmlPath): page module pre-linker missing — served raw")
            return nil
        }

        guard let entriesData = try? JSONSerialization.data(withJSONObject: srcs),
              let entriesJSON = String(data: entriesData, encoding: .utf8) else { return nil }

        let result = bundler.call(withArguments: [entriesJSON, htmlPath, baseURL])
        if let exception = context.exception {
            // The linker throws on a graph it can't pre-link (unresolved/missing module, bad syntax). That
            // is the canonical "blank page" cause; name it so the Logs tab explains why we fell back.
            log("warn", "\(htmlPath): module graph couldn't be pre-linked (\(exception.toString() ?? "?")) — served raw")
            return nil
        }
        guard let bundleJS = result?.toString(), !bundleJS.isEmpty, bundleJS != "undefined" else {
            return nil
        }
        return bundleJS
    }

    // MARK: - HTML scanning / rewriting

    private struct ModuleScript {
        let range: NSRange     // full `<script ...>...</script>` span in the original HTML
        let src: String?       // external src, or nil for an inline module script
    }

    /// Find every `<script ... type="module" ...>...</script>` element, in document order.
    private static func moduleScripts(in html: String) -> [ModuleScript] {
        guard let re = try? NSRegularExpression(
            pattern: "<script\\b([^>]*)>([\\s\\S]*?)</script\\s*>", options: [.caseInsensitive]) else {
            return []
        }
        let full = NSRange(html.startIndex..., in: html)
        var out: [ModuleScript] = []
        re.enumerateMatches(in: html, range: full) { match, _, _ in
            guard let match else { return }
            let attrs = substring(html, match.range(at: 1))
            guard isModuleType(attrs) else { return }
            let body = substring(html, match.range(at: 2))
            let src = attributeValue("src", in: attrs)
            // A module script either references a file (src) or holds inline code; trim decides which.
            if let src, !src.isEmpty {
                out.append(ModuleScript(range: match.range, src: src))
            } else if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out.append(ModuleScript(range: match.range, src: ""))   // empty external-less module → treat as src-less
            } else {
                out.append(ModuleScript(range: match.range, src: nil))  // inline module (has code)
            }
        }
        // A `<script type=module></script>` with neither src nor body is inert; drop it from consideration.
        return out.filter { $0.src == nil || !($0.src?.isEmpty ?? true) }
    }

    /// Replace the FIRST module script with the bundle reference and remove the rest (all module scripts
    /// on a page share one module map; the bundle already runs every entry in document order).
    private static func rewriteHTML(_ html: String, scripts: [ModuleScript], bundleHref: String) -> String {
        var result = html
        // `defer` so the bundle runs after the document is parsed and in order — matching the deferred
        // execution of the `<script type="module">` tags it replaces (correct even if a page put its
        // module scripts in <head> rather than at end-of-body).
        let tag = "<script defer src=\"\(bundleHref)\"></script>"
        // Apply from last to first so earlier NSRange offsets stay valid as we splice.
        for (index, script) in scripts.enumerated().reversed() {
            guard let range = Range(script.range, in: result) else { continue }
            result.replaceSubrange(range, with: index == 0 ? tag : "")
        }
        return result
    }

    // MARK: - Attribute parsing

    /// True when an attribute string declares `type="module"` (quoted or bare, any case/spacing).
    private static func isModuleType(_ attrs: String) -> Bool {
        guard let re = try? NSRegularExpression(
            pattern: "\\btype\\s*=\\s*[\"']?\\s*module\\b", options: [.caseInsensitive]) else { return false }
        return re.firstMatch(in: attrs, range: NSRange(attrs.startIndex..., in: attrs)) != nil
    }

    /// Extract an attribute's value (double-, single-, or unquoted) from an attribute string.
    private static func attributeValue(_ name: String, in attrs: String) -> String? {
        let pattern = "\\b\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s\"'>]+))"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: attrs, range: NSRange(attrs.startIndex..., in: attrs)) else { return nil }
        for group in 1...3 {
            let s = substring(attrs, m.range(at: group))
            if !s.isEmpty { return s }
        }
        return ""
    }

    private static func substring(_ s: String, _ range: NSRange) -> String {
        guard range.location != NSNotFound, let r = Range(range, in: s) else { return "" }
        return String(s[r])
    }

    // MARK: - Keys / hashing

    private static func key(_ parts: String...) -> String { parts.joined(separator: "\u{1}") }

    /// FNV-1a 64-bit hex — a stable, dependency-free content hash for the synthetic bundle path.
    private static func fnv1aHex(_ s: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    // MARK: - Runtime source

    /// acorn + ESM linker + page bundler, concatenated once. acorn must precede the linker (which captures
    /// `globalThis.__bbAcorn` at load); the page bundler reads `globalThis.__bbEsm` the linker exposes.
    private static let runtimeJS: String = {
        let acorn = bundledJS("brownbear-acorn")
        let linker = bundledJS("brownbear-esm-linker")
        let pageBundler = bundledJS("brownbear-esm-page-bundler")
        return acorn + "\n;\n" + linker + "\n;\n" + pageBundler
    }()

    private static func bundledJS(_ name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "js", subdirectory: nil)
                ?? Bundle.main.url(forResource: name, withExtension: "js", subdirectory: "JS"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            return "/* \(name).js missing */"
        }
        return source
    }
}
