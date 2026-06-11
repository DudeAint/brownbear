"use strict";
//
//  brownbear-inline-video.js
//  BrownBear
//
//  Page-world, document-start. Keeps <video> playing INLINE by neutralizing the JS fullscreen entry
//  points a site/player calls to force a video fullscreen, and by tagging every video `playsinline`.
//  This is the "player" behavior of Focus/Player-style apps: the video stays in the page (good for
//  automation that needs to see/act on the page while it plays) instead of taking over the screen.
//  Injected only when the "Keep videos inline" setting is on. It blocks only AUTO/scripted fullscreen
//  (autoplay → fullscreen, timers, etc.); an EXPLICIT fullscreen the user asks for — tapping a player's
//  own fullscreen button, which calls these same APIs from a click handler — is allowed through.
//
(function () {
  try {
    var W = window;
    if (W.__bbInlineVideo) { return; }
    W.__bbInlineVideo = 1;

    // Remember the last REAL user gesture so we can tell an explicit fullscreen (a person tapping the
    // player's fullscreen button) from a scripted/auto one. A custom player's button calls
    // requestFullscreen/webkitEnterFullscreen from inside its click handler, so it lands within this window.
    var lastGesture = 0;
    function markGesture() { lastGesture = Date.now(); }
    ["pointerup", "touchend", "mouseup", "click", "keydown"].forEach(function (t) {
      try { W.addEventListener(t, markGesture, { capture: true, passive: true }); } catch (e) {}
    });
    function userInitiated() {
      try {
        if (W.navigator && W.navigator.userActivation && W.navigator.userActivation.isActive) { return true; }
      } catch (e) {}
      return (Date.now() - lastGesture) < 1500;
    }

    // Auto/scripted fullscreen entry points → no-op. requestFullscreen returns a Promise (reject it so
    // callers' .catch runs cleanly); the iOS HTMLVideoElement.webkitEnterFullscreen returns void.
    function rejector() {
      return (typeof Promise !== "undefined")
        ? Promise.reject(new (W.DOMException || Error)("Fullscreen is disabled (Keep videos inline)"))
        : undefined;
    }
    // Wrap each method: a user-initiated call runs the ORIGINAL (real fullscreen) so the user can go
    // fullscreen by hand; a scripted call is neutralized so the video stays inline.
    function gate(proto, names, blocked) {
      if (!proto) { return; }
      for (var i = 0; i < names.length; i++) {
        (function (name) {
          var orig = proto[name];
          if (typeof orig !== "function") { return; }
          var wrapped = function () {
            if (userInitiated()) { return orig.apply(this, arguments); }
            return blocked.apply(this, arguments);
          };
          try { Object.defineProperty(proto, name, { value: wrapped, writable: true, configurable: true }); }
          catch (e) { try { proto[name] = wrapped; } catch (e2) {} }
        })(names[i]);
      }
    }
    gate(W.Element && W.Element.prototype,
      ["requestFullscreen", "webkitRequestFullscreen", "webkitRequestFullScreen", "mozRequestFullScreen", "msRequestFullscreen"],
      rejector);
    gate(W.HTMLVideoElement && W.HTMLVideoElement.prototype,
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
