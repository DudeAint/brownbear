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
//  Known, documented limitations (acceptable for bundled extension service workers, which are the
//  only consumers): named imports (`import {a} from './x'`) are snapshot at first evaluation, so a
//  *true* import cycle that reads a not-yet-initialised named binding sees `undefined` (the classic
//  CommonJS-cycle hazard; namespace imports and re-exports stay live via getters, and acyclic graphs
//  — the overwhelming majority — are always correct because dependencies fully evaluate first).
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
        // chrome-extension://<id>/<path> — accept our own origin, reduce to its package path.
        if (/^chrome-extension:\/\//i.test(spec)) {
            var rest = spec.replace(/^chrome-extension:\/\//i, '');
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

    // ---- rewrite ---------------------------------------------------------------------------------

    /** Build the require/binding code for a single `import` declaration. `tmp` is a unique temp name. */
    function rewriteImport(node, tmp) {
        var spec = node.source.value;
        if (node.specifiers.length === 0) return '__require(' + lit(spec) + ');';
        var code = 'var ' + tmp + '=__require(' + lit(spec) + ');';
        for (var i = 0; i < node.specifiers.length; i++) {
            var s = node.specifiers[i];
            if (s.type === 'ImportDefaultSpecifier') {
                code += 'var ' + s.local.name + '=' + tmp + '.default;';
            } else if (s.type === 'ImportNamespaceSpecifier') {
                code += 'var ' + s.local.name + '=' + tmp + ';';
            } else { // ImportSpecifier
                code += 'var ' + s.local.name + '=' + tmp + '[' + lit(nameOf(s.imported)) + '];';
            }
        }
        return code;
    }

    /** Transform module source into a registry-executable Function. Throws on parse failure or an
     *  unsupported construct (top-level await), so a bad module fails closed. */
    function transform(src, path, sourceURL) {
        var ast;
        try {
            ast = acorn.parse(src, { ecmaVersion: 'latest', sourceType: 'module', allowHashBang: true });
        } catch (e) {
            throw new Error('parse error in ' + path + ': ' + (e && e.message ? e.message : e));
        }

        var edits = [];          // { start, end, text }
        var tmpCount = 0;
        function tmp() { return '__bb_m' + (tmpCount++); }

        // Top-level import/export declarations (only valid at Program.body level).
        var body = ast.body;
        for (var b = 0; b < body.length; b++) {
            var node = body[b];
            switch (node.type) {
                case 'ImportDeclaration':
                    edits.push({ start: node.start, end: node.end, text: rewriteImport(node, tmp()) });
                    break;
                case 'ExportNamedDeclaration':
                    rewriteExportNamed(node, edits, tmp);
                    break;
                case 'ExportDefaultDeclaration':
                    rewriteExportDefault(node, src, edits);
                    break;
                case 'ExportAllDeclaration':
                    rewriteExportAll(node, edits, tmp());
                    break;
            }
        }

        // Dynamic import() and import.meta, anywhere in the tree. These compose with the boundary
        // edits above (an `export const x = import('y')` keeps the inner import() edit inside the
        // untouched declaration body).
        walk(ast, function (n) {
            if (n.type === 'ImportExpression') {
                // Replace just the `import` keyword (6 chars) so `import( ... )` becomes the call
                // `__import( ... )`, preserving the argument list and any whitespace verbatim.
                edits.push({ start: n.start, end: n.start + 6, text: '__import' });
            } else if (n.type === 'MetaProperty' && n.meta && n.meta.name === 'import'
                       && n.property && n.property.name === 'meta') {
                edits.push({ start: n.start, end: n.end, text: '__meta' });
            }
        });

        var rewritten = applyEdits(src, edits, path);
        var fnSource = '"use strict";' + rewritten + '\n//# sourceURL=' + sourceURL;
        try {
            // eslint-disable-next-line no-new-func
            return new Function('__exports', '__require', '__import', '__meta', '__export', fnSource);
        } catch (e) {
            var msg = e && e.message ? e.message : String(e);
            if (/await/i.test(msg)) {
                throw new Error('top-level await is not supported in module service workers (' + path + ')');
            }
            throw new Error('codegen error in ' + path + ': ' + msg);
        }
    }

    function rewriteExportNamed(node, edits, tmp) {
        if (node.source) {
            // Re-export: export { a, b as c } from './x'  /  export {} from './x'
            var t = tmp();
            var code = 'var ' + t + '=__require(' + lit(node.source.value) + ');';
            for (var i = 0; i < node.specifiers.length; i++) {
                var s = node.specifiers[i];
                code += '__export(' + lit(nameOf(s.exported)) + ',function(){return ' + t
                      + '[' + lit(nameOf(s.local)) + '];});';
            }
            edits.push({ start: node.start, end: node.end, text: code });
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
            edits.push({ start: node.start, end: decl.start, text: '' });
            var appended = ';';
            for (var n = 0; n < names.length; n++) {
                appended += '__export(' + lit(names[n]) + ',function(){return ' + names[n] + ';});';
            }
            edits.push({ start: decl.end, end: decl.end, text: appended });
            return;
        }
        // export { a, b as c };  (local bindings, no `from`)
        var only = '';
        for (var k = 0; k < node.specifiers.length; k++) {
            var sp = node.specifiers[k];
            only += '__export(' + lit(nameOf(sp.exported)) + ',function(){return ' + sp.local.name + ';});';
        }
        edits.push({ start: node.start, end: node.end, text: only });
    }

    function rewriteExportDefault(node, src, edits) {
        var decl = node.declaration;
        var isNamedDecl = (decl.type === 'FunctionDeclaration' || decl.type === 'ClassDeclaration') && decl.id;
        if (isNamedDecl) {
            // export default function foo(){} -> keep the (hoistable) declaration, assign by name.
            edits.push({ start: node.start, end: decl.start, text: '' });
            edits.push({ start: decl.end, end: node.end, text: ';__exports.default=' + decl.id.name + ';' });
        } else {
            // Anonymous function/class or an arbitrary expression -> assign as an expression value,
            // wrapping in parens so an anonymous `function(){}`/`class{}` is read as an expression.
            edits.push({ start: node.start, end: decl.start, text: '__exports.default=(' });
            edits.push({ start: decl.end, end: node.end, text: ');' });
        }
    }

    function rewriteExportAll(node, edits, t) {
        var code = 'var ' + t + '=__require(' + lit(node.source.value) + ');';
        if (node.exported) {
            // export * as ns from './x'
            code += '__export(' + lit(nameOf(node.exported)) + ',function(){return ' + t + ';});';
        } else {
            // export * from './x' — re-export all named (not default) exports, kept live via getters.
            code += 'for(var __k in ' + t + '){if(__k!=="default"){(function(k){__export(k,function(){return '
                  + t + '[k];});})(__k);}}';
        }
        edits.push({ start: node.start, end: node.end, text: code });
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

    function load(path) {
        var rec = registry[path];
        if (rec) return rec;
        var src = global.__bbModuleSource(path);
        if (src == null) throw new Error('module not found: ' + path);
        var baseURL = global.__bbBgBaseURL || '';
        rec = { path: path, exports: {}, evaluated: false, evaluating: false, fn: null };
        rec.fn = transform(String(src), path, baseURL + path);
        registry[path] = rec;
        return rec;
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
        try {
            rec.fn(rec.exports, req, dyn, meta, exp);
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
        }
        return rec.exports;
    }

    /** Entry point Swift invokes once. The entry is a package-relative path (the manifest's
     *  service_worker value), not a specifier, so it is normalized directly rather than resolved. */
    global.__bbRunModuleWorker = function (entryPath) {
        evaluate(normalize(String(entryPath).charAt(0) === '/'
            ? String(entryPath).slice(1) : String(entryPath)));
    };

    // Test seam: expose pure functions when running under a CommonJS harness (Node tests). Has no
    // effect inside JSC, which has no `module`.
    if (typeof module !== 'undefined' && module.exports) {
        module.exports = { transform: transform, resolve: resolve, normalize: normalize };
    }
})(typeof globalThis !== 'undefined' ? globalThis : this);
