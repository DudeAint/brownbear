//
//  brownbear-esm-page-bundler.js
//  BrownBear
//
//  An extension's popup / options / offscreen pages can be ES modules (`<script type="module">` with
//  static imports — e.g. uBlock Origin Lite's dashboard). WebKit does NOT load module scripts over our
//  custom `chrome-extension://` scheme (the scheme isn't a "secure"/module-eligible context, and the only
//  switch is a private API we can't ship), so such a page renders BLANK in WKWebView even though it works
//  in Chrome. We fix that the same way we run MV3 module service workers: PRE-LINK the page's module graph
//  into a single CLASSIC script and serve that in place of the module entry, so the page runs identically
//  to Chrome.
//
//  This runs in a throwaway serve-time JSContext alongside brownbear-acorn.js + brownbear-esm-linker.js
//  (which exposes `__bbEsm`). The Swift scheme handler provides `__bbModuleSource(path)` (a synchronous,
//  path-contained package read), calls `__bbBundlePage(JSON.stringify(entryPaths), baseURL)`, and injects
//  the returned classic bundle. No acorn ships to the page — only the small registry runtime + the
//  already-rewritten module bodies. Fails closed (throws) so the handler can fall back to the raw HTML.
//
(function (global) {
  "use strict";

  /**
   * Build a self-contained classic-script bundle for an extension page's module graph.
   * @param {string} entriesJSON  JSON array of the page's `<script type="module" src>` values, in
   *                              document order — exactly as written in the HTML (URL-relative to the
   *                              page, NOT module-specifier syntax). Resolved here vs `htmlPath`.
   * @param {string} htmlPath     package-relative path of the HTML page (e.g. "popup.html",
   *                              "src/options.html") — entry `src`s resolve against its directory.
   * @param {string} baseURL      `chrome-extension://<id>/` — used for import.meta.url.
   * @returns {string} a classic IIFE that reconstructs the module registry and runs the entries.
   */
  global.__bbBundlePage = function (entriesJSON, htmlPath, baseURL) {
    var esm = global.__bbEsm;
    if (!esm || typeof esm.load !== "function") {
      throw new Error("esm-linker (__bbEsm) not loaded");
    }
    var entries;
    try { entries = JSON.parse(entriesJSON); } catch (e) { throw new Error("bad entriesJSON"); }
    if (!entries || !entries.length) { throw new Error("no module entries"); }
    htmlPath = esm.normalize(String(htmlPath || ""));

    // A page's `<script src>` is URL-relative to the HTML document, NOT a module specifier — so
    // "js/popup.js" means <pageDir>/js/popup.js, never a bare specifier. Resolve it that way to a
    // package path; return null for anything not served from this package (http(s)/data/cross-origin),
    // which the caller skips (such an entry can't be pre-linked — it would fail to load in Chrome too
    // under a 'self' CSP). {chrome,moz}-extension://<thisId>/<p> reduces to its package path <p>
    // (Firefox builds are served under moz-extension).
    function resolveEntrySrc(src) {
      src = String(src);
      if (/^(?:chrome|moz)-extension:\/\//i.test(src)) {
        var rest = src.replace(/^(?:chrome|moz)-extension:\/\//i, "");
        var s = rest.indexOf("/");
        return esm.normalize(s < 0 ? "" : rest.slice(s + 1));
      }
      if (/^[a-zA-Z][a-zA-Z0-9+.\-]*:/.test(src)) { return null; }   // http(s):, data:, blob:, …
      if (src.charAt(0) === "/") { return esm.normalize(src.slice(1)); }   // root-relative
      var dir = esm.dirname(htmlPath);                                     // page-relative
      return esm.normalize((dir ? dir + "/" : "") + src);
    }

    var modules = Object.create(null);   // package path -> { src, isAsync, deps }
    var anyAsync = false;                 // any module uses top-level await → emit the async runtime

    // DFS the static graph. esm.load() reads via __bbModuleSource + transforms; transform stashes the
    // rewritten body (__bbSource), static/string-literal-dynamic import specs (__bbDeps), and whether the
    // module needs top-level await (__bbAsync). `allowTopLevelAwait` lets a page module use TLA (legal in
    // browser module scripts) instead of failing closed the way a service worker module would.
    function visit(path) {
      path = esm.normalize(path);
      if (modules[path] !== undefined) { return path; }
      var rec = esm.load(path, { allowTopLevelAwait: true });   // "module not found" bubbles → raw-HTML fallback
      var deps = rec.fn.__bbDeps || [];
      var resolvedDeps = [];
      for (var i = 0; i < deps.length; i++) {
        var resolved;
        // A bare/cross-origin/computed specifier can't be pre-bundled; skip it (the rewritten body still
        // calls require(spec) → resolve() throws AT RUNTIME if actually reached, matching fail-closed).
        try { resolved = esm.resolve(deps[i], path); } catch (e) { continue; }
        resolvedDeps.push(resolved);
      }
      modules[path] = { src: String(rec.fn.__bbSource || ""), isAsync: !!rec.fn.__bbAsync, deps: resolvedDeps };
      if (modules[path].isAsync) { anyAsync = true; }
      for (var j = 0; j < resolvedDeps.length; j++) { visit(resolvedDeps[j]); }
      return path;
    }

    var entryPaths = [];
    for (var e = 0; e < entries.length; e++) {
      var ep = resolveEntrySrc(entries[e]);
      if (ep == null) { continue; }   // external/non-packaged entry — can't pre-link; skip it
      entryPaths.push(visit(ep));
    }
    if (!entryPaths.length) { throw new Error("no packaged module entries to bundle"); }

    // Emit the bundle. resolve/normalize/dirname are reused verbatim from the linker via toString() (so
    // the page resolves specifiers exactly as the SW does); the tiny evaluate runtime is hand-written
    // (no acorn/transform needed — modules are pre-rewritten). Two runtimes:
    //   • synchronous (no module uses top-level await) — the common case (popup, options/dashboard),
    //     identical to plain `import` ordering;
    //   • asynchronous (some module uses TLA, legal in page module scripts) — pre-evaluates each module's
    //     static deps (awaiting only deps not already in progress, so import cycles don't deadlock) before
    //     running its (async) body, then runs entries in document order, each awaited.
    var out = [];
    out.push('(function(){"use strict";');
    out.push("var __base=" + JSON.stringify(String(baseURL || "")) + ";");
    out.push("var normalize=" + esm.normalize.toString() + ";");
    out.push("var dirname=" + esm.dirname.toString() + ";");
    out.push("var resolve=" + esm.resolve.toString() + ";");
    out.push("var __reg=Object.create(null),__cache=Object.create(null);");

    // A page-visible run report so a stuck/blank page is diagnosable from the host: how many of the
    // page's module entries fully evaluated, and the error (message + stack) for any that threw. The
    // scheme handler's load probe reads `globalThis.__bbPageBundle` and surfaces it to the Logs tab,
    // naming the exact failing module instead of just "still-loading".
    out.push("var __bbg=(typeof globalThis!==\"undefined\")?globalThis:((typeof self!==\"undefined\")?self:this);");
    out.push("var __bbrep=__bbg.__bbPageBundle={total:" + entryPaths.length + ",ran:0,errors:[]};");
    out.push("function __bbrec(entry,e){__bbrep.errors.push({entry:entry," +
             "message:String((e&&e.message)||e),stack:String((e&&e.stack)||\"\")});" +
             "if(typeof console!==\"undefined\"){console.error(\"[bb page bundle] \"+entry,e);}}");

    // Import-binding fixups (mirrors the SW registry): each import registers a re-snapshot closure,
    // drained once the outermost evaluation settles, so a binding snapshotted mid-cycle (undefined)
    // lands on its real value — uBO Lite's dashboard links the same cyclic modules as its worker.
    out.push("var __fixq=[],__fdepth=0;");
    out.push("function __fix(f){__fixq.push(f);}");
    out.push("function __drainFix(){var q=__fixq;__fixq=[];for(var i=0;i<q.length;i++){try{q[i]();}catch(e){}}}");

    if (!anyAsync) {
      // A failed module stays FAILED (ESM semantics): the cache records its error and re-import replays
      // it, never handing back the half-built exports object the body populated before it threw. Without
      // this, a module cached BEFORE its body runs left a partial exports object in __cache on throw; a
      // later import() (Momentum re-imports through Vite's Promise.allSettled, which swallows the first
      // rejection) got that partial object — e.g. Handlebars.template called on an object missing `.main`
      // → "Unknown template object". The error replay turns one swallowed failure back into a real one.
      out.push(
        "function __eval(path){var rec=__cache[path];if(rec){if(rec.error)throw rec.error;return rec.exports;}" +
        "rec={exports:{}};__cache[path]=rec;var fn=__reg[path];" +
        'if(!fn)throw new Error("module not found: "+path);var here=path;' +
        "var require=function(s){return __eval(resolve(s,here));};" +
        "var dyn=function(s){try{return Promise.resolve(__eval(resolve(s,here)));}catch(e){return Promise.reject(e);}};" +
        "var meta={url:__base+here};" +
        "var exp=function(n,g){Object.defineProperty(rec.exports,n,{get:g,enumerable:true,configurable:true});};" +
        "__fdepth++;" +
        "try{fn(rec.exports,require,dyn,meta,exp,__fix);}" +
        "catch(__bbErr){rec.error=__bbErr;throw __bbErr;}" +
        "finally{__fdepth--;if(__fdepth===0){__drainFix();}}" +
        "return rec.exports;}"
      );
    } else {
      out.push("var __deps=Object.create(null);");
      out.push(
        "function __eval(path){" +                                 // async; returns Promise<exports>
        "var rec=__cache[path];" +
        // A failed module stays failed: replay its rejection on re-import (see the sync runtime above).
        "if(rec){if(rec.error)return Promise.reject(rec.error);return rec.done?Promise.resolve(rec.exports):(rec.promise||Promise.resolve(rec.exports));}" +
        "rec={exports:{},done:false,promise:null};__cache[path]=rec;" +
        "var fn=__reg[path];" +
        'if(!fn){return Promise.reject(new Error("module not found: "+path));}' +
        "var here=path;" +
        // Static binding: deps are pre-evaluated before the body, so this synchronous lookup is ready.
        "var require=function(s){var r=__cache[resolve(s,here)];return r?r.exports:undefined;};" +
        "var dyn=function(s){var rp;try{rp=resolve(s,here);}catch(e){return Promise.reject(e);}return __eval(rp);};" +
        "var meta={url:__base+here};" +
        "var exp=function(n,g){Object.defineProperty(rec.exports,n,{get:g,enumerable:true,configurable:true});};" +
        "var deps=__deps[path]||[];var p=Promise.resolve();" +
        "for(var i=0;i<deps.length;i++){(function(dp){p=p.then(function(){" +
        // Skip deps already started/done — an in-progress dep is an import cycle (its exports object exists
        // with live getters), so awaiting it would deadlock; a done dep is ready. Only fresh deps are awaited.
        "if(__cache[dp])return;return __eval(dp);});})(deps[i]);}" +
        "rec.promise=p.then(function(){return fn(rec.exports,require,dyn,meta,exp,__fix);})" +
        ".then(function(){rec.done=true;return rec.exports;},function(__bbErr){rec.error=__bbErr;throw __bbErr;});return rec.promise;}"
      );
      // Per-module resolved static deps, so the runtime can pre-evaluate them before each body runs.
      for (var d in modules) {
        out.push("__deps[" + JSON.stringify(d) + "]=" + JSON.stringify(modules[d].deps) + ";");
      }
    }

    for (var pth in modules) {
      // The rewritten body already opens with "use strict"; and references the 6 params below — the same
      // signature the linker's transform compiles against. A TLA module is wrapped in an async function.
      var kw = modules[pth].isAsync ? "async function" : "function";
      out.push(
        "__reg[" + JSON.stringify(pth) + "]=" + kw + "(__exports,__require,__import,__meta,__export,__fixup){\n" +
        modules[pth].src + "\n};"
      );
    }

    if (!anyAsync) {
      // Each entry is its OWN `<script type="module">` in the page — independent evaluation roots that
      // merely share the module map. In a browser a throw in one entry's graph does NOT stop a sibling
      // entry from running, so isolate each here (catch + record). Without this, an early entry throwing
      // (e.g. a chrome.* call the bridge doesn't satisfy) would abort the whole chain and the last entry —
      // the one that typically clears a page's "loading" state — would never run (the uBO Lite "popup
      // rendered still-loading" symptom). Matches the async runtime's per-entry isolation below.
      for (var k = 0; k < entryPaths.length; k++) {
        var ek = JSON.stringify(entryPaths[k]);
        out.push("try{__eval(" + ek + ");__bbrep.ran++;}catch(__e){__bbrec(" + ek + ",__e);}");
      }
    } else {
      // Run entries sequentially, each fully awaited — matching deferred module-script ordering where a
      // TLA entry blocks the next. A failed entry is recorded (and console.error'd), not swallowed.
      // Fixups drain after EACH entry settles (the async runtime has no synchronous outermost frame),
      // so cycle bindings are corrected before the next entry — and before any user interaction.
      out.push("(async function(){");
      for (var m = 0; m < entryPaths.length; m++) {
        var em = JSON.stringify(entryPaths[m]);
        out.push("try{await __eval(" + em + ");__bbrep.ran++;}catch(__e){__bbrec(" + em + ",__e);}finally{__drainFix();}");
      }
      out.push("})();");
    }
    out.push("})();");
    return out.join("\n");
  };
})(typeof globalThis !== "undefined" ? globalThis : this);
