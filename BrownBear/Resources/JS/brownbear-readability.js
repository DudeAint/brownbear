"use strict";
//
//  brownbear-readability.js
//  BrownBear
//
//  A clean-room article extractor for Reader mode. Independently implemented from the well-known
//  readability scoring approach (NOT copied from Mozilla's Readability): score block elements by
//  text density and punctuation, penalize link-heavy navigation chrome, propagate scores to
//  ancestors, pick the top candidate, and emit cleaned HTML. Invoked once via evaluateJavaScript —
//  the trailing IIFE returns a JSON-serializable result (or null when the page isn't article-like),
//  so the native side reads it straight from the call's return value. It mutates only a clone of the
//  DOM, never the live page.
//
(function () {
  try {
    var doc = document;

    function textOf(node) { return (node.textContent || "").trim(); }

    function linkDensity(el) {
      var total = textOf(el).length;
      if (total === 0) { return 0; }
      var linkLen = 0;
      var anchors = el.getElementsByTagName("a");
      for (var i = 0; i < anchors.length; i++) { linkLen += textOf(anchors[i]).length; }
      return linkLen / total;
    }

    // Tags that never hold article body — stripped from the working clone up front.
    var STRIP = ["script", "style", "noscript", "iframe", "form", "nav", "aside", "header",
                 "footer", "button", "object", "embed", "svg", "figure"];
    // Class/id substrings that strongly signal non-article chrome.
    var JUNK = /(comment|share|related|promo|sponsor|advert|sidebar|footer|header|nav|menu|social|newsletter|subscribe|cookie|banner|popup|modal|breadcrumb)/i;

    var root = doc.body ? doc.body.cloneNode(true) : null;
    if (!root) { return null; }

    STRIP.forEach(function (tag) {
      var nodes = root.getElementsByTagName(tag);
      for (var i = nodes.length - 1; i >= 0; i--) {
        if (nodes[i].parentNode) { nodes[i].parentNode.removeChild(nodes[i]); }
      }
    });

    // Score candidate containers. Base score by tag; bonus for text length + commas; penalty for
    // link density. Scores propagate up: a paragraph's score lifts its parent and (halved) grandparent.
    var candidates = [];
    var all = root.getElementsByTagName("*");
    for (var i = 0; i < all.length; i++) {
      var el = all[i];
      var tag = el.tagName.toLowerCase();
      if (tag !== "p" && tag !== "div" && tag !== "article" && tag !== "section" && tag !== "td" && tag !== "pre") {
        continue;
      }
      var text = textOf(el);
      if (text.length < 25) { continue; }

      var score = 0;
      if (tag === "article") { score += 30; } else if (tag === "section") { score += 12; }
      else if (tag === "div") { score += 5; } else if (tag === "pre") { score += 5; }
      var idClass = (el.className || "") + " " + (el.id || "");
      if (JUNK.test(idClass)) { score -= 25; }
      score += Math.min(Math.floor(text.length / 100), 5);
      score += (text.match(/,/g) || []).length;
      score = score * (1 - linkDensity(el));

      if (el.__bbScore === undefined) { el.__bbScore = 0; candidates.push(el); }
      el.__bbScore += score;
      var parent = el.parentNode;
      if (parent && parent.nodeType === 1) {
        if (parent.__bbScore === undefined) { parent.__bbScore = 0; candidates.push(parent); }
        parent.__bbScore += score;
        var grand = parent.parentNode;
        if (grand && grand.nodeType === 1) {
          if (grand.__bbScore === undefined) { grand.__bbScore = 0; candidates.push(grand); }
          grand.__bbScore += score / 2;
        }
      }
    }

    var best = null;
    for (var j = 0; j < candidates.length; j++) {
      if (!best || candidates[j].__bbScore > best.__bbScore) { best = candidates[j]; }
    }
    if (!best || best.__bbScore < 20) { return null; }

    // Strip residual junk-class descendants and inline event handlers from the chosen subtree.
    var descendants = best.getElementsByTagName("*");
    for (var k = descendants.length - 1; k >= 0; k--) {
      var d = descendants[k];
      var dic = (d.className || "") + " " + (d.id || "");
      if (JUNK.test(dic) && textOf(d).length < 200) {
        if (d.parentNode) { d.parentNode.removeChild(d); }
        continue;
      }
      var attrs = d.attributes;
      for (var a = attrs.length - 1; a >= 0; a--) {
        var name = attrs[a].name;
        if (name.indexOf("on") === 0 || name === "style" || name === "class" || name === "id") {
          d.removeAttribute(name);
        }
      }
    }

    var content = best.innerHTML || "";
    var textContent = textOf(best);
    if (textContent.length < 250) { return null; }   // too short to be a real article

    function meta(selectors) {
      for (var s = 0; s < selectors.length; s++) {
        var node = doc.querySelector(selectors[s]);
        if (node) {
          var val = node.getAttribute("content") || textOf(node);
          if (val) { return val.trim(); }
        }
      }
      return null;
    }

    var title = meta(['meta[property="og:title"]', 'meta[name="twitter:title"]']) ||
                (doc.title ? doc.title.trim() : null) ||
                (doc.querySelector("h1") ? textOf(doc.querySelector("h1")) : null) || "";
    var byline = meta(['meta[name="author"]', 'meta[property="article:author"]', '[rel="author"]', '.byline']);

    return {
      title: title,
      byline: byline || "",
      content: content,
      textLength: textContent.length,
      url: location.href
    };
  } catch (e) {
    return null;
  }
})();
