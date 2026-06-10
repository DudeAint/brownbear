"use strict";
//
//  brownbear-inline-video.js
//  BrownBear
//
//  Page-world, document-start. Keeps <video> playing INLINE by neutralizing the JS fullscreen entry
//  points a site/player calls to force a video fullscreen, and by tagging every video `playsinline`.
//  This is the "player" behavior of Focus/Player-style apps: the video stays in the page (good for
//  automation that needs to see/act on the page while it plays) instead of taking over the screen.
//  Injected only when the "Keep videos inline" setting is on. It does NOT disable the user-tappable
//  native fullscreen button — only scripted/auto fullscreen — so a person can still go fullscreen by hand.
//
(function () {
  try {
    var W = window;
    if (W.__bbInlineVideo) { return; }
    W.__bbInlineVideo = 1;

    // Site-/player-initiated fullscreen entry points → no-op. requestFullscreen returns a Promise (reject
    // it so callers' .catch runs cleanly); the iOS HTMLVideoElement.webkitEnterFullscreen returns void.
    function rejector() {
      return (typeof Promise !== "undefined")
        ? Promise.reject(new (W.DOMException || Error)("Fullscreen is disabled (Keep videos inline)"))
        : undefined;
    }
    function override(proto, names, fn) {
      if (!proto) { return; }
      for (var i = 0; i < names.length; i++) {
        var name = names[i];
        if (typeof proto[name] === "function") {
          try { Object.defineProperty(proto, name, { value: fn, writable: true, configurable: true }); }
          catch (e) { try { proto[name] = fn; } catch (e2) {} }
        }
      }
    }
    override(W.Element && W.Element.prototype,
      ["requestFullscreen", "webkitRequestFullscreen", "webkitRequestFullScreen", "mozRequestFullScreen", "msRequestFullscreen"],
      rejector);
    override(W.HTMLVideoElement && W.HTMLVideoElement.prototype,
      ["webkitEnterFullscreen", "webkitEnterFullScreen"],
      function () { /* void: stay inline */ });

    // Tag every video playsinline (existing + future), so a freshly-inserted player doesn't auto-fullscreen.
    function inlineVideo(v) {
      try { v.setAttribute("playsinline", ""); v.setAttribute("webkit-playsinline", ""); } catch (e) {}
    }
    function scan(root) {
      try {
        var vids = (root || document).getElementsByTagName ? (root || document).getElementsByTagName("video") : [];
        for (var i = 0; i < vids.length; i++) { inlineVideo(vids[i]); }
      } catch (e) {}
    }
    try {
      var mo = new MutationObserver(function (mutations) {
        for (var i = 0; i < mutations.length; i++) {
          var added = mutations[i].addedNodes;
          for (var j = 0; j < added.length; j++) {
            var node = added[j];
            if (node && node.tagName === "VIDEO") { inlineVideo(node); }
            else if (node && node.getElementsByTagName) { scan(node); }
          }
        }
      });
      var observe = function () { try { mo.observe(document.documentElement || document, { childList: true, subtree: true }); } catch (e) {} };
      if (document.documentElement) { observe(); } else { document.addEventListener("DOMContentLoaded", observe, { once: true }); }
    } catch (e) {}
    scan(document);
    document.addEventListener("DOMContentLoaded", function () { scan(document); }, { once: true });
  } catch (e) { /* never break a page over this */ }
})();
