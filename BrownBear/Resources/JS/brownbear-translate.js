//
//  brownbear-translate.js
//
//  In-page translation engine. Native injects this into the active page (its own isolated world, sharing
//  the DOM), then drives it over BBEvaluateJavaScriptForResult:
//    1. __bbTranslate.collect()       → gather translatable text nodes IN PLACE, tag each with an id,
//                                        return [{id, text}] (native detects the source language + batches).
//    2. __bbTranslate.apply(items)    → write each translation back onto its original text node (storing the
//                                        original), so the live page reads in the target language. Streamed:
//                                        native calls apply() per batch as translations complete.
//    3. __bbTranslate.showOriginal()  / showTranslated() — toggle the page between the two IN PLACE.
//    4. __bbTranslate.rescan()        → collect text added since the last pass (SPA/infinite-scroll content).
//
//  This is BrownBear's own feature (not extension code): it replaces the page's own text nodes only — it
//  never adds scripts or touches attributes/markup — so it can't change page behaviour, only the words shown.
//  Skips script/style/code/editable/`translate="no"` subtrees and non-linguistic text (numbers, symbols).
//

(function () {
  "use strict";
  if (window.__bbTranslate && window.__bbTranslate.__installed) { return; }

  var SKIP_TAGS = { SCRIPT: 1, STYLE: 1, NOSCRIPT: 1, TEXTAREA: 1, CODE: 1, PRE: 1, KBD: 1, SAMP: 1,
                    VAR: 1, TT: 1, SVG: 1, MATH: 1, CANVAS: 1, TEMPLATE: 1 };

  var nextId = 1;
  var registry = Object.create(null);   // id -> { node, original, translated }
  var showing = "original";

  // A node is translatable when it carries real linguistic text and lives in a subtree we're allowed to
  // touch — not script/style/code, not an editable field, not an explicit translate="no" / .notranslate.
  function hasLetters(s) {
    // At least one letter from any script (Latin, CJK, Cyrillic, Arabic, …). Pure numbers/symbols/whitespace
    // are not worth translating and must round-trip untouched.
    return /[A-Za-zÀ-ɏͰ-ϿЀ-ӿ֐-׿؀-ۿ぀-ヿ㐀-鿿가-힯]/.test(s);
  }

  function isSkippedElement(el) {
    if (!el || el.nodeType !== 1) { return false; }
    if (SKIP_TAGS[el.tagName]) { return true; }
    if (el.isContentEditable) { return true; }
    var t = el.getAttribute && el.getAttribute("translate");
    if (t && t.toLowerCase() === "no") { return true; }
    if (el.classList && el.classList.contains("notranslate")) { return true; }
    return false;
  }

  function shouldTranslateTextNode(node) {
    var v = node.nodeValue;
    if (!v || !v.trim() || !hasLetters(v)) { return false; }
    for (var el = node.parentNode; el && el.nodeType === 1; el = el.parentNode) {
      if (isSkippedElement(el)) { return false; }
    }
    return true;
  }

  // Walk the DOM under `root`, collecting NEW translatable text nodes (already-registered nodes are skipped
  // so rescan() only returns fresh content). Tags each with an id and remembers its original text.
  function gather(root) {
    var out = [];
    var doc = root.ownerDocument || document;
    var walker = doc.createTreeWalker(root, 4 /* SHOW_TEXT */, null, false);
    var node;
    while ((node = walker.nextNode())) {
      if (node.__bbTId) { continue; }                 // already collected in a prior pass
      if (!shouldTranslateTextNode(node)) { continue; }
      var id = "t" + (nextId++);
      node.__bbTId = id;
      registry[id] = { node: node, original: node.nodeValue, translated: null };
      out.push({ id: id, text: node.nodeValue });
    }
    return out;
  }

  function apply(items) {
    if (!items || !items.length) { return 0; }
    var n = 0;
    for (var i = 0; i < items.length; i++) {
      var it = items[i];
      var rec = it && registry[it.id];
      if (!rec || typeof it.text !== "string") { continue; }
      rec.translated = it.text;
      // Only write if we're meant to be showing the translation (the user may have toggled back mid-stream).
      if (showing === "translated") {
        try { rec.node.nodeValue = it.text; } catch (e) {}
      }
      n++;
    }
    return n;
  }

  function setShowing(mode) {
    showing = mode;
    var key = mode === "translated" ? "translated" : "original";
    for (var id in registry) {
      var rec = registry[id];
      var val = key === "translated" ? (rec.translated != null ? rec.translated : rec.original) : rec.original;
      try { if (rec.node.nodeValue !== val) { rec.node.nodeValue = val; } } catch (e) {}
    }
    return true;
  }

  window.__bbTranslate = {
    __installed: true,

    // Begin a translation pass: switch the page into "translated" mode (so streamed apply() writes land) and
    // return every translatable text node currently in the document.
    collect: function () {
      showing = "translated";
      return gather(document.documentElement || document.body || document);
    },

    // Collect text added since the last pass (call after the user scrolls an SPA / new content loads).
    rescan: function () {
      return gather(document.documentElement || document.body || document);
    },

    apply: function (items) { return apply(items); },

    showOriginal: function () { return setShowing("original"); },
    showTranslated: function () { return setShowing("translated"); },

    // Forget everything and restore the page to its original text (used when translation is dismissed).
    reset: function () {
      setShowing("original");
      for (var id in registry) { try { delete registry[id].node.__bbTId; } catch (e) {} }
      registry = Object.create(null);
      nextId = 1;
      showing = "original";
      return true;
    },

    status: function () {
      var total = 0, done = 0;
      for (var id in registry) { total++; if (registry[id].translated != null) { done++; } }
      return { total: total, translated: done, showing: showing };
    }
  };
})();
