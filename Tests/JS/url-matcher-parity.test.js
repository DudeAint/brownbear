//
//  url-matcher-parity.test.js
//  BrownBear
//
//  SECURITY-CRITICAL: the static document-start fast-path (brownbear-pageworld-static.js) decides IN JS
//  whether a grant-none script runs on a URL. If its @match/@exclude logic disagrees with the native
//  URLMatcher.swift, a script could inject on the WRONG page. This drives the SHIPPED matcher (inside
//  pageworld-static.js, via its __bbStaticCfg entry point) through EVERY vector in
//  BrownBearTests/URLMatcherTests.swift and asserts identical match/no-match. Run-on-match => the script's
//  wrapped body is eval'd (evaled.length===1); no-match => nothing (0).
//
//  Pure Node, no deps. Run by CI + locally with `node Tests/JS/url-matcher-parity.test.js`.
//

"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const assert = require("assert");

const SRC = fs.readFileSync(path.resolve(__dirname, "../../BrownBear/Resources/JS/brownbear-pageworld-static.js"), "utf8");

let passed = 0, failed = 0;

// Run the shipped static matcher: one script with the given directives, at `href`. Returns true if it ran.
function ran(dirs, href) {
    const cfg = [Object.assign({
        uuid: "u1", matches: [], includes: [], excludes: [], excludeMatches: [],
        info: {}, source: "/* noop */"
    }, dirs)];
    let evaled = 0;
    const win = {}; win.window = win;
    const sandbox = {
        __bbStaticCfg: cfg, location: { href: href }, JSON, RegExp, URL, console,
        window: win, self: win, top: win, history: {}, CustomEvent: function () {}, Promise, addEventListener() {},
        eval: function () { evaled++; }
    };
    vm.runInContext(SRC, vm.createContext(sandbox));
    return evaled === 1;
}

let i = 0;
function expect(dirs, href, want, label) {
    i++;
    const got = ran(dirs, href);
    if (got === want) { passed++; }
    else { failed++; console.log("  FAIL #" + i + " " + (label || "") + " matches(" + JSON.stringify(href) + ") => " + got + " expected " + want); }
}

console.log("URLMatcher parity: shipped pageworld-static matcher vs every URLMatcherTests.swift vector");

// testSubdomainWildcardMatchesHostAndSubdomains
expect({ matches: ["*://*.example.com/*"] }, "https://www.example.com/page", true);
expect({ matches: ["*://*.example.com/*"] }, "https://example.com/", true);
expect({ matches: ["*://*.example.com/*"] }, "http://a.b.example.com/x?y=1", true);
expect({ matches: ["*://*.example.com/*"] }, "https://evil.com/example.com", false);
expect({ matches: ["*://*.example.com/*"] }, "https://notexample.com/", false);
// testSchemeSpecificMatch
expect({ matches: ["https://secure.test/*"] }, "https://secure.test/x", true);
expect({ matches: ["https://secure.test/*"] }, "http://secure.test/x", false);
// testAllURLsMatchesHTTPOnly
expect({ matches: ["<all_urls>"] }, "https://anything.example/", true);
expect({ matches: ["<all_urls>"] }, "http://plain.test/path", true);
expect({ matches: ["<all_urls>"] }, "file:///etc/hosts", false);
expect({ matches: ["<all_urls>"] }, "about:blank", false);
// testPathWildcard
expect({ matches: ["https://example.com/foo/*"] }, "https://example.com/foo/bar", true);
expect({ matches: ["https://example.com/foo/*"] }, "https://example.com/foo/", true);
expect({ matches: ["https://example.com/foo/*"] }, "https://example.com/other", false);
// testExclusionWins (@exclude-match)
expect({ matches: ["*://*.example.com/*"], excludeMatches: ["*://*.example.com/private/*"] }, "https://example.com/public", true);
expect({ matches: ["*://*.example.com/*"], excludeMatches: ["*://*.example.com/private/*"] }, "https://example.com/private/secret", false);
expect({ matches: ["*://*.example.com/*"], excludeMatches: ["*://*.example.com/private/*"] }, "https://www.example.com/private/x", false);
// testExcludeGlobApex (@exclude glob)
expect({ matches: ["*://*.example.com/*"], excludes: ["*example.com/private/*"] }, "https://example.com/public", true);
expect({ matches: ["*://*.example.com/*"], excludes: ["*example.com/private/*"] }, "https://example.com/private/secret", false);
// testExcludeMatchUsesMatchPatternSemantics
expect({ matches: ["<all_urls>"], excludeMatches: ["https://blocked.test/*"] }, "https://allowed.test/", true);
expect({ matches: ["<all_urls>"], excludeMatches: ["https://blocked.test/*"] }, "https://blocked.test/anything", false);
// testIncludeGlob
expect({ includes: ["*://*.test.com/*"] }, "https://sub.test.com/page", true);
expect({ includes: ["*://*.test.com/*"] }, "https://test.org/", false);
// testIncludeRegex
expect({ includes: ["/^https:\\/\\/foo\\.bar\\//"] }, "https://foo.bar/baz", true);
expect({ includes: ["/^https:\\/\\/foo\\.bar\\//"] }, "https://other.bar/", false);
// testNoDirectivesMatchesNothing
expect({}, "https://example.com/", false);
// testMatchPatternIgnoresNonHTTP
expect({ matches: ["*://*/*"] }, "https://example.com/", true);
expect({ matches: ["*://*/*"] }, "ftp://example.com/", false);
// testIPv6LiteralMatchPattern
expect({ matches: ["https://[::1]/*"] }, "https://[::1]/dashboard", true);
expect({ matches: ["https://[::1]/*"] }, "https://[::1]/", true);
expect({ matches: ["https://[::1]/*"] }, "http://[::1]/x", false);
expect({ matches: ["https://[::1]/*"] }, "https://[::2]/x", false);
expect({ matches: ["https://[::1]/*"] }, "https://example.com/x", false);
// testFullIPv6AddressMatchPattern
expect({ matches: ["*://[2001:db8::1]/*"] }, "https://[2001:db8::1]/app", true);
expect({ matches: ["*://[2001:db8::1]/*"] }, "http://[2001:db8::1]/", true);
expect({ matches: ["*://[2001:db8::1]/*"] }, "https://[2001:DB8::1]/x", true);
expect({ matches: ["*://[2001:db8::1]/*"] }, "https://[2001:db8::2]/", false);
// testWildcardHostAndAllUrlsCoverIPv6
expect({ matches: ["*://*/*"] }, "https://[::1]/x", true);
expect({ matches: ["<all_urls>"] }, "https://[fe80::1]/y", true);
// testHostClassesStillMatchAfterIPv6Support
expect({ matches: ["https://example.com/*"] }, "https://example.com/a", true);
expect({ matches: ["https://*.example.com/*"] }, "https://www.example.com/a", true);
expect({ matches: ["https://127.0.0.1/*"] }, "https://127.0.0.1/a", true);
expect({ matches: ["http://localhost/*"] }, "http://localhost/a", true);
expect({ matches: ["https://example.com/*"] }, "https://evil.com/a", false);
expect({ matches: ["https://127.0.0.1/*"] }, "https://127.0.0.2/a", false);

console.log("\n" + passed + " passed, " + failed + " failed (of " + i + " native vectors)");
if (failed) { process.exitCode = 1; }
