//
//  brownbear-esm-linker.js
//  BrownBear
//
//  A pure-JavaScript ES-module linker for headless JavaScriptCore contexts (the MV3 module service
//  worker). JSC on iOS ships no ES-module loader, and its native loader API (`JSScript`,
//  `JSContext.moduleLoaderDelegate`, `kJSScriptTypeModule`) is private SPI absent from the public
//  iOS SDK — so an extension whose manifest declares `"background": { "service_worker": "...",
//  "type": "module" }` (e.g. uBlock Origin Lite) cannot be evaluated with a bare `import`. This
//  linker resolves the module graph from the extension package at boot, rewrites each module's
//  static `import`/`export` syntax into calls against a small synchronous registry, and runs the
//  graph inside the ordinary classic-script context — no private API, App-Store-safe.
//
//  The rewrite is AST-driven (acorn parses each module; we apply *surgical* edits keyed on exact
//  node offsets, leaving every other byte untouched), not regex — this app runs untrusted code, so
//  a fragile source transform is a security hazard. Loaded after brownbear-acorn.js, which exposes
//  `globalThis.__bbAcorn`. The native side provides `__bbModuleSource(path)` (a synchronous,
//  path-contained package read) and `__bbBgBaseURL` (the `chrome-extension://<id>/` origin used for
//  `import.meta.url`). Swift calls `__bbRunModuleWorker(entryPath)` once, after the chrome.* runtime
//  is installed.
//
//  Import bindings are LIVE: a reference to a named/default import is rewritten to read through the
//  exporting module's namespace (`tmp.foo`) every time, so a value the exporter assigns AFTER the
//  import line is seen at its current value — ESM-faithful, and the fix for esbuild's lazy `__esm`
//  init pattern (Phantom's `import{j as E}…; …E.FORCE_PRODUCTION_API`, where the env object is filled
//  in by an init function the importer calls after the import). Only references provably unshadowed
//  by an inner scope are rewritten; the eager `var local=…` snapshot + `__fixup` re-snapshot remain as
//  a safety net for any reference the rewrite conservatively skips (so it can never become a
//  ReferenceError). Import cycles keep ESM-faithful semantics (they broke uBO Lite's admin ⇄
//  ruleset-manager boot before): export getters are HOISTED to the top of each module body, so a
//  cycle partner re-entering mid-evaluation resolves hoisted function declarations immediately.
//  Top-level `await` is unsupported (synchronous registry); a module that uses it fails closed with
//  a clear error rather than silently mis-running.
//

(function (global) {
    'use strict';

    var acorn = global.__bbAcorn;

    // ---- path resolution -------------------------------------------------------------------------

    /** Normalize a slash path, resolving "." and ".." segments. Returns a package-relative path
     *  with no leading slash. A ".." that would climb above the root is clamped at the root (the
     *  native reader enforces containment too — this is belt-and-suspenders). */
    function normalize(path) {
        var parts = path.split('/');
        var out = [];
        for (var i = 0; i < parts.length; i++) {
            var seg = parts[i];
            if (seg === '' || seg === '.') continue;
            if (seg === '..') { if (out.length) out.pop(); continue; }
            out.push(seg);
        }
        return out.join('/');
    }

    function dirname(path) {
        var i = path.lastIndexOf('/');
        return i < 0 ? '' : path.slice(0, i);
    }

    /** Resolve a module specifier (as written in source) against the importing module's path to a
     *  package-relative path. Throws for anything we can't serve from the package (bare specifiers,
     *  cross-origin http(s) imports), so resolution fails closed. */
    function resolve(spec, fromPath) {
        if (typeof spec !== 'string' || spec.length === 0) {
            throw new Error('invalid module specifier: ' + String(spec));
        }
        // {chrome,moz}-extension://<id>/<path> — accept our own origin (Firefox builds are served under
        // moz-extension), reduce to its package path.
        if (/^(?:chrome|moz)-extension:\/\//i.test(spec)) {
            var rest = spec.replace(/^(?:chrome|moz)-extension:\/\//i, '');
            var slash = rest.indexOf('/');
            return normalize(slash < 0 ? '' : rest.slice(slash + 1));
        }
        // Any other URL scheme (http:, https:, data:, blob:, node:, npm bare-with-colon) is not a
        // packaged file — refuse rather than reach onto the network from a background worker.
        if (/^[a-zA-Z][a-zA-Z0-9+.\-]*:/.test(spec)) {
            throw new Error('unsupported module specifier (not a packaged path): ' + spec);
        }
        if (spec.charAt(0) === '/') return normalize(spec.slice(1));        // package-absolute
        if (spec.charAt(0) === '.') return normalize(dirname(fromPath) + '/' + spec);  // relative
        // Bare specifier ("lodash"): MV3 service workers have no import map, so this is unresolvable.
        throw new Error('bare module specifier not supported: ' + spec);
    }

    // ---- AST helpers -----------------------------------------------------------------------------

    /** The string key of an Identifier or string-Literal node (e.g. `export {x as "a-b"}`). */
    function nameOf(node) {
        return node.type === 'Literal' ? String(node.value) : node.name;
    }

    /** Collect every binding name introduced by a (possibly destructuring) declarator target. */
    function boundNames(node, out) {
        if (!node) return;
        switch (node.type) {
            case 'Identifier': out.push(node.name); break;
            case 'ObjectPattern':
                for (var i = 0; i < node.properties.length; i++) {
                    var p = node.properties[i];
                    boundNames(p.type === 'RestElement' ? p.argument : p.value, out);
                }
                break;
            case 'ArrayPattern':
                for (var j = 0; j < node.elements.length; j++) boundNames(node.elements[j], out);
                break;
            case 'AssignmentPattern': boundNames(node.left, out); break;
            case 'RestElement': boundNames(node.argument, out); break;
            case 'Property': boundNames(node.value, out); break;
        }
    }

    /** Walk every node in the tree, invoking visit(node). acorn nodes are plain objects whose
     *  child nodes are reachable via own enumerable properties (objects/arrays that carry a `type`). */
    function walk(node, visit) {
        if (!node || typeof node !== 'object') return;
        if (typeof node.type === 'string') visit(node);
        for (var key in node) {
            if (key === 'type' || key === 'start' || key === 'end') continue;
            var child = node[key];
            if (!child || typeof child !== 'object') continue;
            if (Array.isArray(child)) {
                for (var i = 0; i < child.length; i++) walk(child[i], visit);
            } else if (typeof child.type === 'string') {
                walk(child, visit);
            }
        }
    }

    // A literal for use as a JS string in generated code. JSON.stringify is exact for this.
    function lit(str) { return JSON.stringify(String(str)); }

    // True for a name usable as a bare identifier after a `.` (reserved words are legal there).
    function validIdent(name) { return /^[A-Za-z_$][A-Za-z0-9_$]*$/.test(name); }

    // The live member-access expression for an imported binding: `tmp.foo` or `tmp["weird-name"]`.
    // Reading THROUGH the require-result every time is what makes the binding live (ESM-faithful),
    // so a value the exporter assigns after the import line (esbuild's lazy `__esm` init pattern —
    // Phantom's `import{j as E}…; E.FORCE_PRODUCTION_API`) is seen at its settled value, not the
    // `undefined` an eager snapshot captured at import time.
    function memberFor(tmp, prop) {
        return validIdent(prop) ? tmp + '.' + prop : tmp + '[' + lit(prop) + ']';
    }

    // ---- rewrite ---------------------------------------------------------------------------------

    /** Build the require/binding code for a single `import` declaration. `tmp` is a unique temp name;
     *  `live` is a map (localName → member-access string) the caller uses to rewrite each binding's
     *  *references* into a live read-through (see rewriteLiveRefs).
     *
     *  Live bindings: a named/default import reference is rewritten to `tmp.foo` so every read forwards
     *  to the exporter's current value — ESM-faithful, and the fix for esbuild's lazy `__esm` pattern
     *  (Phantom's `import{j as E}…; …E.FORCE_PRODUCTION_API`, where the exporter assigns the value via
     *  an init function called AFTER the import line). The eager `var local=…` snapshot + `__fixup`
     *  re-snapshot are KEPT as a safety net: any reference the rewrite conservatively skips (e.g. a
     *  binding it can't prove is unshadowed) still resolves to the snapshot, i.e. today's behaviour —
     *  never a ReferenceError. The snapshot read is guarded (a mid-cycle read of a not-yet-initialised
     *  let/const export getter throws TDZ, which must not abort the importer the way real ESM linking
     *  wouldn't). Namespace imports bind the live exports object itself and need neither snapshot fixup
     *  nor reference rewriting. */
    function rewriteImport(node, tmp, live) {
        var spec = node.source.value;
        if (node.specifiers.length === 0) return '__require(' + lit(spec) + ');';
        var code = 'var ' + tmp + '=__require(' + lit(spec) + ');';
        var binds = '';
        for (var i = 0; i < node.specifiers.length; i++) {
            var s = node.specifiers[i];
            if (s.type === 'ImportDefaultSpecifier') {
                code += 'var ' + s.local.name + ';';
                binds += 'try{' + s.local.name + '=' + tmp + '.default;}catch(__bbE){}';
                live[s.local.name] = tmp + '.default';
            } else if (s.type === 'ImportNamespaceSpecifier') {
                code += 'var ' + s.local.name + '=' + tmp + ';';
            } else { // ImportSpecifier
                code += 'var ' + s.local.name + ';';
                var nm = nameOf(s.imported);
                binds += 'try{' + s.local.name + '=' + memberFor(tmp, nm) + ';}catch(__bbE){}';
                live[s.local.name] = memberFor(tmp, nm);
            }
        }
        if (binds) {
            code += binds + '__fixup(function(){' + binds + '});';
        }
        return code;
    }

    /** Transform module source into a registry-executable Function. Throws on parse failure or an
     *  unsupported construct (top-level await — UNLESS `opts.allowTopLevelAwait`, used by the page
     *  bundler: page module scripts legally support TLA, so it compiles the body as an AsyncFunction
     *  and marks `fn.__bbAsync`; the service-worker path passes no opts and keeps rejecting TLA). */
    function transform(src, path, sourceURL, opts) {
        var allowAsync = !!(opts && opts.allowTopLevelAwait);
        var ast;
        try {
            ast = acorn.parse(src, { ecmaVersion: 'latest', sourceType: 'module', allowHashBang: true });
        } catch (e) {
            throw new Error('parse error in ' + path + ': ' + (e && e.message ? e.message : e));
        }

        var edits = [];          // { start, end, text }
        var tmpCount = 0;
        function tmp() { return '__bb_m' + (tmpCount++); }
        var deps = [];           // static + string-literal-dynamic import specifiers (for page bundling)
        // Export-getter registrations hoisted to the TOP of the module body, BEFORE any imports run.
        // In an import cycle the partner re-enters this module mid-evaluation; with the getters already
        // registered, its reads resolve hoisted function declarations immediately (real ESM semantics)
        // instead of finding an empty namespace — the uBO Lite admin ⇄ ruleset-manager boot deadlock.
        // The getters close over module-scope names: functions are hoisted (defined), `var`s read
        // undefined until assigned, let/const throw TDZ until initialised — all faithful to ESM.
        var prelude = [];
        var live = Object.create(null);   // import local name → live member-access (e.g. "__bb_m0.foo")

        // Top-level import/export declarations (only valid at Program.body level).
        var body = ast.body;
        for (var b = 0; b < body.length; b++) {
            var node = body[b];
            switch (node.type) {
                case 'ImportDeclaration':
                    if (node.source) { deps.push(node.source.value); }
                    edits.push({ start: node.start, end: node.end, text: rewriteImport(node, tmp(), live) });
                    break;
                case 'ExportNamedDeclaration':
                    if (node.source) { deps.push(node.source.value); }
                    rewriteExportNamed(node, edits, prelude, live);
                    break;
                case 'ExportDefaultDeclaration':
                    rewriteExportDefault(node, src, edits, prelude);
                    break;
                case 'ExportAllDeclaration':
                    if (node.source) { deps.push(node.source.value); }
                    rewriteExportAll(node, edits, prelude, tmp());
                    break;
            }
        }

        // Rewrite each *reference* to a named/default import into a live read-through (`tmp.foo`), so a
        // value assigned by the exporter after the import line (esbuild lazy `__esm` init) is seen live.
        // Conservative: only references provably unshadowed by an inner scope are rewritten; the rest
        // fall back to the eager snapshot rewriteImport emitted (today's behaviour, never a crash).
        // Collected SEPARATELY so that, if the rewrite ever yields source that won't compile (an
        // unforeseen construct), the whole module can fall back to the boundary-edits-only output
        // below — making live bindings strictly non-regressive (worst case = pre-live-bindings behaviour).
        var liveEdits = [];
        rewriteLiveRefs(ast, live, liveEdits);

        // Dynamic import() and import.meta, anywhere in the tree. These compose with the boundary
        // edits above (an `export const x = import('y')` keeps the inner import() edit inside the
        // untouched declaration body).
        walk(ast, function (n) {
            if (n.type === 'ImportExpression') {
                // Replace just the `import` keyword (6 chars) so `import( ... )` becomes the call
                // `__import( ... )`, preserving the argument list and any whitespace verbatim.
                edits.push({ start: n.start, end: n.start + 6, text: '__import' });
                // A string-literal dynamic import is statically resolvable, so the page bundler can
                // include it; a computed import() can't be pre-bundled (left to fail closed if reached).
                if (n.source && n.source.type === 'Literal' && typeof n.source.value === 'string') {
                    deps.push(n.source.value);
                }
            } else if (n.type === 'MetaProperty' && n.meta && n.meta.name === 'import'
                       && n.property && n.property.name === 'meta') {
                edits.push({ start: n.start, end: n.end, text: '__meta' });
            }
        });

        // Compile the module body for a given edit set. Page module scripts legally use top-level await,
        // so on the "await" SyntaxError (and only when allowed) recompile as an AsyncFunction and flag it
        // for the bundler. A real syntax error rethrows to the caller, which decides whether to fall back.
        function compile(editList) {
            var rewritten = applyEdits(src, editList, path);
            var fnSource = '"use strict";' + prelude.join('') + rewritten + '\n//# sourceURL=' + sourceURL;
            var isAsync = false, fn;
            try {
                // eslint-disable-next-line no-new-func
                fn = new Function('__exports', '__require', '__import', '__meta', '__export', '__fixup', fnSource);
            } catch (e) {
                var msg = e && e.message ? e.message : String(e);
                if (/await/i.test(msg) && allowAsync) {
                    var AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
                    fn = new AsyncFunction('__exports', '__require', '__import', '__meta', '__export', '__fixup', fnSource);
                    isAsync = true;
                } else if (/await/i.test(msg)) {
                    throw new Error('top-level await is not supported in module service workers (' + path + ')');
                } else {
                    throw e;   // genuine syntax error — caller decides
                }
            }
            return { fn: fn, isAsync: isAsync, fnSource: fnSource };
        }

        var result;
        try {
            result = compile(edits.concat(liveEdits));
        } catch (e) {
            var em = e && e.message ? e.message : String(e);
            // A live-binding reference rewrite that produced uncompilable source must never make a module
            // fail to pre-link: recompile with the boundary edits ONLY (the pre-live-bindings output —
            // eager snapshot, no read-through). Surface the module so the rewrite gap can be fixed.
            if (liveEdits.length && !/top-level await/.test(em)) {
                if (global.console && global.console.warn) {
                    global.console.warn('brownbear-esm-linker: live-binding rewrite fell back to snapshot for '
                        + path + ' (' + em + ')');
                }
                try {
                    result = compile(edits);
                } catch (e2) {
                    throw new Error('codegen error in ' + path + ': ' + (e2 && e2.message ? e2.message : e2));
                }
            } else {
                throw new Error('codegen error in ' + path + ': ' + em);
            }
        }
        var fn = result.fn, isAsync = result.isAsync, fnSource = result.fnSource;
        // Stash the rewritten body + static deps so the page bundler (which can't execute modules —
        // they need the page's DOM/window) can emit a self-contained classic bundle. Inert for the SW.
        fn.__bbSource = fnSource;
        fn.__bbDeps = deps;
        fn.__bbAsync = isAsync;
        return fn;
    }

    function rewriteExportNamed(node, edits, prelude, live) {
        if (node.source) {
            // Re-export: export { a, b as c } from './x'  /  export {} from './x'
            // Getters go to the PRELUDE so a mid-cycle importer already sees the names; each getter
            // requires lazily (memoized — mid-cycle it hands back the partial ns, after settle the full
            // one, so the binding is live). The source position keeps a bare __require so WHEN the dep
            // evaluates is unchanged.
            for (var i = 0; i < node.specifiers.length; i++) {
                var s = node.specifiers[i];
                prelude.push('__export(' + lit(nameOf(s.exported)) + ',function(){return __require('
                    + lit(node.source.value) + ')[' + lit(nameOf(s.local)) + '];});');
            }
            edits.push({ start: node.start, end: node.end, text: '__require(' + lit(node.source.value) + ');' });
            return;
        }
        if (node.declaration) {
            // export const/let/var ... | export function ... | export class ...
            var names = [];
            var decl = node.declaration;
            if (decl.type === 'VariableDeclaration') {
                for (var d = 0; d < decl.declarations.length; d++) boundNames(decl.declarations[d].id, names);
            } else if (decl.id) {
                names.push(decl.id.name);
            }
            // Strip only the `export ` keyword; leave the declaration (and any inner import()) intact.
            // The getter registrations are hoisted to the prelude (see transform) so a cycle partner
            // re-entering before this line sees hoisted functions already bound.
            edits.push({ start: node.start, end: decl.start, text: '' });
            for (var n = 0; n < names.length; n++) {
                prelude.push('__export(' + lit(names[n]) + ',function(){return ' + names[n] + ';});');
            }
            return;
        }
        // export { a, b as c };  (local bindings, no `from`) — registrations hoist; the statement goes.
        // If the local name is itself an imported binding, the getter reads it LIVE (`tmp.foo`) so a
        // re-export forwards the exporter's current value (the bare-name read would see the snapshot).
        for (var k = 0; k < node.specifiers.length; k++) {
            var sp = node.specifiers[k];
            var read = (live && live[sp.local.name]) ? live[sp.local.name] : sp.local.name;
            prelude.push('__export(' + lit(nameOf(sp.exported)) + ',function(){return ' + read + ';});');
        }
        edits.push({ start: node.start, end: node.end, text: '' });
    }

    function rewriteExportDefault(node, src, edits, prelude) {
        var decl = node.declaration;
        var isNamedDecl = (decl.type === 'FunctionDeclaration' || decl.type === 'ClassDeclaration') && decl.id;
        if (isNamedDecl) {
            // export default function foo(){} -> keep the (hoistable) declaration; the getter hoists so a
            // cycle partner resolves the function immediately (a class stays TDZ until its line, like ESM).
            edits.push({ start: node.start, end: decl.start, text: '' });
            edits.push({ start: decl.end, end: node.end, text: ';' });
            prelude.push('__export("default",function(){return ' + decl.id.name + ';});');
        } else {
            // Anonymous function/class or an arbitrary expression -> evaluate in place into a hoisted
            // slot; the prelude getter makes ns.default visible (undefined until the line runs, as in
            // a CJS-style cycle — importers' __fixup re-snapshot lands the settled value).
            prelude.push('var __bb_default$;__export("default",function(){return __bb_default$;});');
            edits.push({ start: node.start, end: decl.start, text: '__bb_default$=(' });
            edits.push({ start: decl.end, end: node.end, text: ');' });
        }
    }

    function rewriteExportAll(node, edits, prelude, t) {
        if (node.exported) {
            // export * as ns from './x' — the getter hoists (lazy require keeps it live); the source
            // position keeps a bare __require so dep evaluation order is unchanged.
            prelude.push('__export(' + lit(nameOf(node.exported)) + ',function(){return __require('
                + lit(node.source.value) + ');});');
            edits.push({ start: node.start, end: node.end, text: '__require(' + lit(node.source.value) + ');' });
            return;
        }
        // export * from './x' — the names aren't knowable until the dep evaluates, so this stays at its
        // source position (re-exported names appear once the dep settles; importers' __fixup re-snapshot
        // covers a cycle). Kept live via getters.
        var code = 'var ' + t + '=__require(' + lit(node.source.value) + ');'
            + 'for(var __k in ' + t + '){if(__k!=="default"){(function(k){__export(k,function(){return '
            + t + '[k];});})(__k);}}';
        edits.push({ start: node.start, end: node.end, text: code });
    }

    // ---- live import-binding references ----------------------------------------------------------

    /** Record into `out` (a plain-object set) the live-binding names that function `fn` SHADOWS for the
     *  whole of its body: its own name (named expressions / declarations), its parameters, and every
     *  binding declared anywhere in its body that is not inside a further nested function. Deliberately
     *  OVER-approximate — extra shadowing only makes a reference fall back to the eager snapshot
     *  (today's behaviour), never produces a wrong value; UNDER-approximating would risk rewriting a
     *  shadowed reference, which must never happen. */
    function collectFunctionShadows(fn, live, out) {
        if (fn.id && live[fn.id.name]) out[fn.id.name] = true;
        var pnames = [];
        for (var i = 0; i < fn.params.length; i++) boundNames(fn.params[i], pnames);
        for (var p = 0; p < pnames.length; p++) if (live[pnames[p]]) out[pnames[p]] = true;
        if (fn.body && fn.body.type === 'BlockStatement') collectBodyBindings(fn.body, live, out);
    }

    /** Collect binding names declared within a function/block body WITHOUT descending into nested
     *  function bodies (those bindings belong to their own scope), but DO record a nested
     *  FunctionDeclaration's name (it binds in this scope). */
    function collectBodyBindings(node, live, out) {
        if (!node || typeof node !== 'object') return;
        var t = node.type;
        if (t === 'FunctionDeclaration') { if (node.id && live[node.id.name]) out[node.id.name] = true; return; }
        if (t === 'FunctionExpression' || t === 'ArrowFunctionExpression') return;
        if (t === 'VariableDeclaration') {
            for (var d = 0; d < node.declarations.length; d++) {
                var ns = []; boundNames(node.declarations[d].id, ns);
                for (var k = 0; k < ns.length; k++) if (live[ns[k]]) out[ns[k]] = true;
            }
        } else if (t === 'ClassDeclaration') {
            if (node.id && live[node.id.name]) out[node.id.name] = true;
        } else if (t === 'CatchClause' && node.param) {
            var cn = []; boundNames(node.param, cn);
            for (var c = 0; c < cn.length; c++) if (live[cn[c]]) out[cn[c]] = true;
        }
        for (var key in node) {
            if (key === 'type' || key === 'start' || key === 'end') continue;
            var child = node[key];
            if (!child || typeof child !== 'object') continue;
            if (Array.isArray(child)) { for (var a = 0; a < child.length; a++) collectBodyBindings(child[a], live, out); }
            else if (typeof child.type === 'string') collectBodyBindings(child, live, out);
        }
    }

    /** Rewrite every *reference* to a named/default import local into its live member read (`tmp.foo`).
     *  Descends with a `shadowed` set (prototype-chained = union of enclosing function scopes); a name
     *  is rewritten only when it is live AND unshadowed. Binding positions (declarator ids, params,
     *  catch params, class/function names), non-computed property keys, labels, and import/export
     *  specifier names are never treated as references — and anything this misses simply keeps the eager
     *  snapshot, so a conservative skip is always safe. */
    function rewriteLiveRefs(ast, live, edits) {
        var hasLive = false; for (var _n in live) { hasLive = true; break; }
        if (!hasLive) return;

        function visit(node, shadowed) {
            if (!node || typeof node.type !== 'string') return;
            switch (node.type) {
                case 'Identifier':
                    if (live[node.name] && !shadowed[node.name]) {
                        edits.push({ start: node.start, end: node.end, text: live[node.name] });
                    }
                    return;
                case 'FunctionDeclaration':
                case 'FunctionExpression':
                case 'ArrowFunctionExpression': {
                    var inner = Object.create(shadowed);   // params/ids are bindings → never visited as refs
                    collectFunctionShadows(node, live, inner);
                    if (node.body) visit(node.body, inner);
                    return;
                }
                case 'MemberExpression':
                    visit(node.object, shadowed);
                    if (node.computed) visit(node.property, shadowed);   // non-computed key is not a ref
                    return;
                case 'Property':
                    if (node.computed) visit(node.key, shadowed);
                    if (node.shorthand) {
                        var v = node.value;                              // {E} → {E: tmp.foo}
                        if (v && v.type === 'Identifier' && live[v.name] && !shadowed[v.name]) {
                            edits.push({ start: node.start, end: node.end, text: v.name + ':' + live[v.name] });
                        }
                        return;
                    }
                    visit(node.value, shadowed);
                    return;
                case 'MethodDefinition':
                case 'PropertyDefinition':
                    if (node.computed) visit(node.key, shadowed);
                    if (node.value) visit(node.value, shadowed);
                    return;
                case 'VariableDeclarator':
                    if (node.init) visit(node.init, shadowed);           // id is a binding target
                    return;
                case 'ClassDeclaration':
                case 'ClassExpression':
                    if (node.superClass) visit(node.superClass, shadowed);
                    if (node.body) visit(node.body, shadowed);           // id is a binding
                    return;
                case 'CatchClause':
                    if (node.body) visit(node.body, shadowed);           // param is a binding
                    return;
                case 'AssignmentExpression':
                    if (node.left && node.left.type === 'MemberExpression') visit(node.left, shadowed);
                    if (node.right) visit(node.right, shadowed);         // a bare-Identifier/pattern target is a write
                    return;
                case 'UpdateExpression':
                    if (node.argument && node.argument.type === 'MemberExpression') visit(node.argument, shadowed);
                    return;
                case 'LabeledStatement':
                    if (node.body) visit(node.body, shadowed);           // label is not a ref
                    return;
                case 'BreakStatement':
                case 'ContinueStatement':
                case 'ImportDeclaration':                                // handled by rewriteImport
                case 'ExportAllDeclaration':
                case 'MetaProperty':
                    return;
                case 'ExportNamedDeclaration':
                    if (node.declaration) visit(node.declaration, shadowed);   // specifiers → getters
                    return;
                case 'ExportDefaultDeclaration':
                    if (node.declaration) visit(node.declaration, shadowed);
                    return;
                default:
                    for (var key in node) {
                        if (key === 'type' || key === 'start' || key === 'end') continue;
                        var child = node[key];
                        if (!child || typeof child !== 'object') continue;
                        if (Array.isArray(child)) { for (var i = 0; i < child.length; i++) visit(child[i], shadowed); }
                        else if (typeof child.type === 'string') visit(child, shadowed);
                    }
                    return;
            }
        }

        visit(ast, Object.create(null));
    }

    /** Apply non-overlapping edits to source. Edits are sorted descending by start so each splice
     *  leaves earlier offsets valid. Overlap is a transform bug — fail closed. */
    function applyEdits(src, edits, path) {
        edits.sort(function (a, b) { return b.start - a.start || b.end - a.end; });
        var prevStart = src.length + 1;
        var out = src;
        for (var i = 0; i < edits.length; i++) {
            var e = edits[i];
            if (e.end > prevStart) {
                throw new Error('overlapping rewrite in ' + path + ' at ' + e.start + '-' + e.end);
            }
            out = out.slice(0, e.start) + e.text + out.slice(e.end);
            prevStart = e.start;
        }
        return out;
    }

    // ---- registry / execution --------------------------------------------------------------------

    var registry = Object.create(null);

    function load(path, opts) {
        var rec = registry[path];
        if (rec) return rec;
        var src = global.__bbModuleSource(path);
        if (src == null) throw new Error('module not found: ' + path);
        var baseURL = global.__bbBgBaseURL || '';
        rec = { path: path, exports: {}, evaluated: false, evaluating: false, fn: null };
        rec.fn = transform(String(src), path, baseURL + path, opts);
        registry[path] = rec;
        return rec;
    }

    // Import-binding fixups: each import statement registers a re-snapshot closure; once the OUTERMOST
    // evaluation finishes (evalDepth back to 0 — every cycle in the graph has settled), they run so a
    // binding snapshotted mid-cycle (undefined) lands on its real value. Runs synchronously before any
    // microtask, so async continuations (a worker's start()) always see settled bindings.
    var fixups = [];
    var evalDepth = 0;
    function registerFixup(fn) { fixups.push(fn); }
    function runFixups() {
        var queue = fixups;
        fixups = [];
        for (var i = 0; i < queue.length; i++) {
            try { queue[i](); } catch (eIgnored) { /* a still-TDZ binding keeps its eager value */ }
        }
    }

    function evaluate(path) {
        var rec = load(path);
        if (rec.evaluated || rec.evaluating) return rec.exports;   // cycle: hand back the partial ns
        rec.evaluating = true;
        var here = rec.path;
        var req = function (spec) { return evaluate(resolve(spec, here)); };
        var dyn = function (spec) {
            try { return Promise.resolve(evaluate(resolve(spec, here))); }
            catch (err) { return Promise.reject(err); }
        };
        var meta = { url: (global.__bbBgBaseURL || '') + here };
        var exp = function (name, getter) {
            Object.defineProperty(rec.exports, name, { get: getter, enumerable: true, configurable: true });
        };
        evalDepth++;
        try {
            rec.fn(rec.exports, req, dyn, meta, exp, registerFixup);
            rec.evaluated = true;
        } catch (e) {
            // A module is evaluated exactly once; a failed module STAYS failed (ESM semantics). Mark it
            // so it is never re-evaluated (which would re-run side effects and could cascade into a
            // misleading downstream error), and attribute the failure to its path ONCE so the real first
            // error surfaces in the worker's Logs tab rather than a confusing later crash.
            rec.evaluated = true;
            rec.failed = true;
            rec.error = e;
            if (!(e && e.__bbModuleFailed)) {
                var wrapped = new Error('module "' + rec.path + '" failed to initialize: '
                    + (e && e.message ? e.message : e));
                wrapped.__bbModuleFailed = true;
                e = wrapped;
            }
            throw e;
        } finally {
            rec.evaluating = false;
            evalDepth--;
            // Outermost evaluation done (even if it threw — partial graphs still get their bindings
            // settled, so a sibling module that DID evaluate isn't left with stale snapshots).
            if (evalDepth === 0) { runFixups(); }
        }
        return rec.exports;
    }

    /** Entry point Swift invokes once. The entry is a package-relative path (the manifest's
     *  service_worker value), not a specifier, so it is normalized directly rather than resolved. */
    global.__bbRunModuleWorker = function (entryPath) {
        evaluate(normalize(String(entryPath).charAt(0) === '/'
            ? String(entryPath).slice(1) : String(entryPath)));
    };

    // Expose the pure transform/resolve helpers so the PAGE bundler (brownbear-esm-page-bundler.js) can
    // reuse them to emit a classic bundle for extension popup/options pages — WKWebView won't load
    // `<script type="module">` over our custom scheme, so we pre-link page module graphs the same way we
    // link module service workers. Additive; the SW path is unaffected.
    global.__bbEsm = { transform: transform, resolve: resolve, normalize: normalize, dirname: dirname, load: load };

    // Test seam: expose pure functions when running under a CommonJS harness (Node tests). Has no
    // effect inside JSC, which has no `module`.
    if (typeof module !== 'undefined' && module.exports) {
        module.exports = { transform: transform, resolve: resolve, normalize: normalize };
    }
})(typeof globalThis !== 'undefined' ? globalThis : this);
