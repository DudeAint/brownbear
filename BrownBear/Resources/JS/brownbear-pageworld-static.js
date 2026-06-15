//
//  brownbear-pageworld-static.js
//  BrownBear
//
//  TRUE document-start injection for grant-none page-world userscripts (the "as great as Violentmonkey"
//  timing win). Added as a `.page`, atDocumentStart WKUserScript by InjectionOrchestrator ONLY when the
//  "Static document-start" setting is on; native prepends `var __bbStaticCfg = <JSON of eligible scripts>;`.
//  Because it's a real WKUserScript (not a late getScripts round-trip), the body runs at the page's actual
//  document-start, before any page script — exactly like a VM static content_script.
//
//  Safety model (why this can't regress):
//   • Eligible scripts are grant-none + page/auto + document-start + simple @match only — no GM bridge, so
//     none of the cross-world rendezvous #177 broke is touched.
//   • The @match guard (matchesURL) is a faithful port of URLMatcher.swift, cross-tested 45/45 against
//     URLMatcherTests.swift (url-matcher-parity.test.js). Conservative: native only emits SIMPLE http/https
//     patterns into __bbStaticCfg; anything exotic is left to the dynamic path.
//   • The page-world wrapper (buildPageWorldSource) is a VERBATIM copy of brownbear-runtime.js's; the run-once
//     guard (window.__bbRanUS[uuid]) is shared, so the static and dynamic paths run a script EXACTLY once and
//     the dynamic path is always the fallback. pageworld-static-equivalence.test.js asserts the copy matches.
//   • If a strict page CSP refuses the eval here, it throws BEFORE the guard runs, so the flag stays unset and
//     the dynamic (native, CSP-immune) path runs the script — no loss, just no timing win on that page.
//

(function () {
  "use strict";
  try {
    var CFG = (typeof __bbStaticCfg !== "undefined" && __bbStaticCfg) || null;
    if (!CFG || !CFG.length) { return; }
    var _JSON = JSON, _url = "";
    try { _url = location.href; } catch (e) { return; }

    // ---- @match / @include / @exclude / @exclude-match matcher (port of URLMatcher.swift; 45/45) ----
    function escapeRegex(s) { return s.replace(/[.*+?^${}()|[\]\\/]/g, "\\$&"); }
    function replaceAll(s, find, repl) { return s.split(find).join(repl); }
    function globToRegex(glob) {
      var specials = ".?^$+{}[]|()/\\", out = "^";
      for (var i = 0; i < glob.length; i++) {
        var ch = glob[i];
        if (ch === "*") { out += ".*"; }
        else if (specials.indexOf(ch) >= 0) { out += "\\" + ch; }
        else { out += ch; }
      }
      return out + "$";
    }
    var MATCH_PATTERN_RE = /^(http:|https:|\*:)\/\/((?:\*\.)?(?:[a-z0-9-]+\.)+(?:[a-z0-9]+)|\*\.[a-z]+|\*|[a-z0-9]+|\[[0-9a-f:.]+\])(\/[^\s]*)$/i;
    function compileMatchPattern(pattern) {
      var m = MATCH_PATTERN_RE.exec(pattern);
      if (!m) { return null; }
      var scheme = m[1], hostToken = m[2], pathToken = m[3], hostPattern;
      if (hostToken[0] === "[" && hostToken[hostToken.length - 1] === "]") {
        hostPattern = "^" + escapeRegex(hostToken) + "$";
      } else {
        var p = "^" + replaceAll(hostToken, ".", "\\.") + "$";
        p = replaceAll(p, "^*$", ".*");
        p = replaceAll(p, "*\\.", "(.*\\.)?");
        hostPattern = p;
      }
      try { return { scheme: scheme, hostRegex: new RegExp(hostPattern, "i"), pathRegex: new RegExp(globToRegex(pathToken), "i") }; }
      catch (e) { return null; }
    }
    function compileIncludeOrExclude(pattern) {
      if (pattern.length >= 2 && pattern[0] === "/" && pattern[pattern.length - 1] === "/") {
        try { return new RegExp(pattern.slice(1, -1), "i"); } catch (e) { return null; }
      }
      try { return new RegExp(globToRegex(pattern), "i"); } catch (e) { return null; }
    }
    function parse(urlString) {
      var u;
      try { u = new URL(urlString); } catch (e) { return null; }
      if (!u.protocol) { return null; }
      var host = u.hostname || "";
      if (host.indexOf(":") >= 0 && host[0] !== "[") { host = "[" + host + "]"; }
      var path = u.pathname || "";
      if (path === "") { path = "/"; }
      if (u.search && u.search.length > 0) { path += u.search; }
      return { scheme: u.protocol.toLowerCase(), host: host, path: path };
    }
    function patternMatches(parts, pattern) {
      if (parts.scheme !== "http:" && parts.scheme !== "https:") { return false; }
      if (pattern.scheme !== "*:" && parts.scheme !== pattern.scheme) { return false; }
      return pattern.hostRegex.test(parts.host) && pattern.pathRegex.test(parts.path);
    }
    function matchesURL(s, urlString) {
      var i, c, parts = null;
      var excludeRegexes = (s.excludes || []).map(compileIncludeOrExclude).filter(Boolean);
      for (i = 0; i < excludeRegexes.length; i++) { if (excludeRegexes[i].test(urlString)) { return false; } }
      var excludePatterns = (s.excludeMatches || []).map(compileMatchPattern).filter(Boolean);
      if (excludePatterns.length) {
        parts = parse(urlString);
        if (parts) { for (i = 0; i < excludePatterns.length; i++) { if (patternMatches(parts, excludePatterns[i])) { return false; } } }
      }
      var allURLs = false, includePatterns = [];
      (s.matches || []).forEach(function (p) { if (p === "<all_urls>") { allURLs = true; } else { c = compileMatchPattern(p); if (c) { includePatterns.push(c); } } });
      if (allURLs) { parts = parts || parse(urlString); if (parts && (parts.scheme === "http:" || parts.scheme === "https:")) { return true; } }
      if (includePatterns.length) {
        parts = parts || parse(urlString);
        if (parts) { for (i = 0; i < includePatterns.length; i++) { if (patternMatches(parts, includePatterns[i])) { return true; } } }
      }
      var includeRegexes = (s.includes || []).map(compileIncludeOrExclude).filter(Boolean);
      for (i = 0; i < includeRegexes.length; i++) { if (includeRegexes[i].test(urlString)) { return true; } }
      return false;
    }

    // ---- PAGE_URLCHANGE_SRC + buildPageWorldSource — VERBATIM copies of brownbear-runtime.js (asserted by
    //      pageworld-static-equivalence.test.js). Keep byte-identical so a script behaves the same on either path.
    var PAGE_URLCHANGE_SRC =
      "(function(){if(window.__bbPageUrlChangeOn){return;}window.__bbPageUrlChangeOn=true;" +
      "var hist=window.history,loc=window.location,_CE=window.CustomEvent,_P=window.Promise,last='';" +
      "try{last=(loc&&loc.href)||'';}catch(e){last='';}" +
      "function defer(fn){if(_P){_P.resolve().then(fn);}else{setTimeout(fn,0);}}" +
      "function emit(){var href='';try{href=(loc&&loc.href)||'';}catch(e){href='';}if(href===last){return;}last=href;" +
      "try{if(typeof _CE==='function'){window.dispatchEvent(new _CE('urlchange',{detail:{url:href}}));}}catch(e){}" +
      "try{var h=window.onurlchange;if(typeof h==='function'){h.call(window,{url:href});}}catch(e){}}" +
      "if(hist){['pushState','replaceState'].forEach(function(n){var o=hist[n];" +
      "if(typeof o!=='function'||o.__bbWrapped){return;}" +
      "var w=function(){var r=o.apply(this,arguments);defer(emit);return r;};w.__bbWrapped=true;" +
      "try{hist[n]=w;}catch(e){}});}" +
      "try{window.addEventListener('popstate',function(){defer(emit);},true);}catch(e){}" +
      "try{window.addEventListener('hashchange',function(){defer(emit);},true);}catch(e){}" +
      "})();\n";
    function buildPageWorldSource(data, body) {
      var infoJSON = "{}";
      try { infoJSON = _JSON.stringify(data.info || {}); } catch (e) { infoJSON = "{}"; }
      var uuid = "";
      try { uuid = String(data.uuid || ""); } catch (e) { uuid = ""; }
      var guard = uuid
        ? ("var R=(window.__bbRanUS=window.__bbRanUS||{});if(R[" + _JSON.stringify(uuid) + "])return;R[" + _JSON.stringify(uuid) + "]=1;\n")
        : "";
      return "(function(){\n" +
        "\"use strict\";\n" +
        guard +
        PAGE_URLCHANGE_SRC +
        "var unsafeWindow = window;\n" +
        "var GM_info = " + infoJSON + ";\n" +
        "if (!GM_info.scriptHandler) { GM_info.scriptHandler = \"BrownBear\"; }\n" +
        "var GM = { info: GM_info };\n" +
        "(function (unsafeWindow, GM, GM_info, window) {\n" +
        body + "\n" +
        "}).call(window, unsafeWindow, GM, GM_info, window);\n" +
        "})();";
    }

    // ---- run matched scripts at THIS document-start ----
    for (var i = 0; i < CFG.length; i++) {
      var s = CFG[i];
      try {
        if (!matchesURL(s, _url)) { continue; }
        // Indirect eval so the body runs at global (page) scope, like the native page-world eval. A strict
        // page CSP (no 'unsafe-eval') throws here BEFORE buildPageWorldSource's run-once guard executes, so
        // the dynamic native path (CSP-immune) still runs the script — no double-run, no miss.
        (0, eval)(buildPageWorldSource({ uuid: s.uuid, info: s.info }, s.source));
      } catch (e) { /* CSP-refused, matcher error, or body threw — dynamic path is the fallback */ }
    }
  } catch (e) { /* never break a page over the static fast-path */ }
})();
