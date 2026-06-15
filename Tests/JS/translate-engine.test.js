//
//  translate-engine.test.js
//  BrownBear
//
//  The in-page translation engine (brownbear-translate.js): native injects it, calls collect() to gather
//  translatable text nodes IN PLACE, then apply() to write translations back onto those exact nodes, with
//  showOriginal()/showTranslated() toggling the live page. This boots the REAL engine over a minimal DOM +
//  TreeWalker and asserts: it collects only real linguistic text (skipping script/style/code/notranslate/
//  translate="no"/numbers), writes translations onto the original nodes, toggles both ways, and resets.
//
//  Pure Node. Run by CI (globs Tests/JS/*.test.js) and locally with `node Tests/JS/translate-engine.test.js`.
//

"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const assert = require("assert");

const SRC = fs.readFileSync(path.resolve(__dirname, "../../BrownBear/Resources/JS/brownbear-translate.js"), "utf8");

// ---- minimal DOM ----------------------------------------------------------------------------------
let DOC;
function text(value) { return { nodeType: 3, nodeValue: value, parentNode: null, ownerDocument: () => DOC }; }
function el(tag, attrs, children) {
    const e = {
        nodeType: 1, tagName: tag.toUpperCase(), childNodes: [], parentNode: null,
        _attrs: attrs || {}, isContentEditable: (attrs && attrs.editable) || false,
        getAttribute(n) { return Object.prototype.hasOwnProperty.call(this._attrs, n) ? this._attrs[n] : null; },
        classList: { contains: (c) => ((attrs && attrs.class) || "").split(/\s+/).indexOf(c) !== -1 }
    };
    (children || []).forEach((c) => { c.parentNode = e; e.childNodes.push(c); });
    return e;
}
function descendants(root) {   // document-order DFS
    const out = [];
    (function rec(n) { (n.childNodes || []).forEach((c) => { out.push(c); rec(c); }); })(root);
    return out;
}
function makeDocument(root) {
    return {
        documentElement: root, body: root,
        createTreeWalker(r, whatToShow) {
            const texts = descendants(r).filter((n) => n.nodeType === 3);   // SHOW_TEXT
            let i = -1;
            return { nextNode() { i++; return i < texts.length ? texts[i] : null; } };
        }
    };
}

function append(parent, child) { child.parentNode = parent; parent.childNodes.push(child); child.ownerDocument = DOC; }

function boot(root) {
    DOC = makeDocument(root);
    root.ownerDocument = DOC;
    descendants(root).forEach((n) => { n.ownerDocument = DOC; });
    const win = {};
    win.window = win; win.document = DOC; win.RegExp = RegExp;
    vm.createContext(win);
    vm.runInContext(SRC, win, { filename: "brownbear-translate.js" });
    return win;
}

let passed = 0, failed = 0;
const ok = (n) => { console.log("  ok   " + n); passed++; };
const bad = (n, e) => { console.log("  FAIL " + n + "\n       " + (e && e.message ? e.message : e)); failed++; };

// A page: a heading + paragraph (translate), a <script> + <code> + a translate="no" + .notranslate + a
// pure-number node (all skipped).
function buildPage() {
    const hello = text("Hello world");
    const para = text("This is a paragraph.");
    const codeText = text("const x = 1;");
    const scriptText = text("var a = 2;");
    const noTrans = text("Do not translate me");
    const brand = text("BrownBear");   // inside .notranslate
    const number = text("  42  ");
    const root = el("div", {}, [
        el("h1", {}, [hello]),
        el("p", {}, [para]),
        el("code", {}, [codeText]),
        el("script", {}, [scriptText]),
        el("span", { translate: "no" }, [noTrans]),
        el("span", { class: "notranslate" }, [brand]),
        el("span", {}, [number])
    ]);
    return { root, hello, para, codeText, scriptText, noTrans, brand, number };
}

// 1) collect() gathers only the real linguistic text, skipping script/code/translate=no/.notranslate/numbers.
try {
    const p = buildPage();
    const win = boot(p.root);
    const items = win.__bbTranslate.collect();
    const texts = [...items.map((i) => i.text)].sort();   // spread → host realm (deepStrictEqual is realm-sensitive)
    assert.deepStrictEqual(texts, ["Hello world", "This is a paragraph."],
        "only genuine linguistic text is collected (script/code/translate=no/.notranslate/numbers skipped)");
    assert.ok(items.every((i) => typeof i.id === "string" && i.id), "each collected node gets a stable id");
    ok("collect() gathers translatable text and skips non-translatable subtrees");
} catch (e) { bad("collect", e); }

// 2) apply() writes the translation onto the ORIGINAL text node (in place).
try {
    const p = buildPage();
    const win = boot(p.root);
    const items = win.__bbTranslate.collect();
    const map = {}; items.forEach((i) => { map[i.text] = i.id; });
    const n = win.__bbTranslate.apply([
        { id: map["Hello world"], text: "Hola mundo" },
        { id: map["This is a paragraph."], text: "Esto es un párrafo." }
    ]);
    assert.strictEqual(n, 2, "apply reports the number of nodes written");
    assert.strictEqual(p.hello.nodeValue, "Hola mundo", "the heading text node now reads the translation IN PLACE");
    assert.strictEqual(p.para.nodeValue, "Esto es un párrafo.", "the paragraph text node now reads the translation");
    assert.strictEqual(p.codeText.nodeValue, "const x = 1;", "a skipped code node is never touched");
    ok("apply() writes translations onto the original text nodes in place");
} catch (e) { bad("apply", e); }

// 3) showOriginal() / showTranslated() toggle the live page both ways.
try {
    const p = buildPage();
    const win = boot(p.root);
    const items = win.__bbTranslate.collect();
    const map = {}; items.forEach((i) => { map[i.text] = i.id; });
    win.__bbTranslate.apply([{ id: map["Hello world"], text: "Hola mundo" }]);
    win.__bbTranslate.showOriginal();
    assert.strictEqual(p.hello.nodeValue, "Hello world", "showOriginal restores the source text");
    win.__bbTranslate.showTranslated();
    assert.strictEqual(p.hello.nodeValue, "Hola mundo", "showTranslated re-applies the translation");
    ok("showOriginal()/showTranslated() toggle the page in place");
} catch (e) { bad("toggle", e); }

// 4) A translation that streams in WHILE showing original is stored, applied only on showTranslated.
try {
    const p = buildPage();
    const win = boot(p.root);
    const items = win.__bbTranslate.collect();
    const map = {}; items.forEach((i) => { map[i.text] = i.id; });
    win.__bbTranslate.showOriginal();                                       // user toggled back mid-stream
    win.__bbTranslate.apply([{ id: map["Hello world"], text: "Hola mundo" }]);
    assert.strictEqual(p.hello.nodeValue, "Hello world", "a streamed translation does NOT overwrite while showing original");
    win.__bbTranslate.showTranslated();
    assert.strictEqual(p.hello.nodeValue, "Hola mundo", "...but is shown once the user switches to translated");
    ok("streamed apply() respects the current original/translated toggle");
} catch (e) { bad("stream-toggle", e); }

// 5) rescan() only returns text added since the last pass; reset() restores + forgets everything.
try {
    const p = buildPage();
    const win = boot(p.root);
    win.__bbTranslate.collect();
    const again = win.__bbTranslate.rescan();
    assert.strictEqual(again.length, 0, "rescan returns nothing when no new text was added");
    const fresh = text("Newly loaded content");
    const newPara = el("p", {}, [fresh]);   // el() already parents `fresh` under newPara
    append(p.root, newPara); fresh.ownerDocument = DOC;   // attach the new subtree under the live root
    const added = win.__bbTranslate.rescan();
    assert.deepStrictEqual([...added.map((i) => i.text)], ["Newly loaded content"], "rescan returns only the newly-added text");
    win.__bbTranslate.apply([{ id: added[0].id, text: "Contenido recién cargado" }]);
    assert.strictEqual(fresh.nodeValue, "Contenido recién cargado", "newly-added text is translatable too");
    win.__bbTranslate.reset();
    assert.strictEqual(p.hello.nodeValue, "Hello world", "reset restores all original text");
    assert.strictEqual(win.__bbTranslate.status().total, 0, "reset forgets the registry");
    ok("rescan() picks up new content; reset() restores + clears");
} catch (e) { bad("rescan/reset", e); }

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
