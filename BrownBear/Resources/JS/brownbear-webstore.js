//
//  brownbear-webstore.js
//  BrownBear
//
//  Injected at document-start in the PAGE world on every page; it does nothing unless the page is a
//  Chrome Web Store, Microsoft Edge Add-ons, or Firefox (AMO) extension page. There it:
//    1. Spoofs whatever each store sniffs for so it renders an ENABLED install button instead of a
//       "you're not on <Browser>" download CTA (Chrome: userAgentData/vendor/window.chrome; Firefox:
//       InstallTrigger + navigator.mozAddonManager; Edge: window.chrome). The native side additionally
//       forces the matching desktop User-Agent for store hosts at the navigation layer.
//    2. Rewrites the store's install button to "Add to BrownBear" / "Remove from BrownBear" and routes
//       its click to BrownBear's native installer (window.webkit.messageHandlers.brownbearWebStore),
//       intercepting the page's own handler. Re-applies as the SPA re-renders / route-navigates between
//       listings WITHOUT a full reload — the case where the button used to snap back to the store's own
//       "Add to <Browser>" disabled state.
//
//  The native side (WebStoreInstallHandler) resolves the store + extension from the page URL and runs
//  the real CRX/XPI download + install/remove, replying so the button can show the result.
//

(function () {
    "use strict";

    var host = location.hostname.toLowerCase();
    var STORE = null;
    if (host === "chromewebstore.google.com"
        || (host === "chrome.google.com" && location.pathname.indexOf("/webstore") === 0)) {
        STORE = "chrome";
    } else if (host === "microsoftedge.microsoft.com") {
        STORE = "edge";
    } else if (host === "addons.mozilla.org" || host.indexOf(".addons.mozilla.org") >= 0) {
        STORE = "firefox";
    }
    if (!STORE) { return; }

    // --- 1. Spoof so each store renders an enabled install button. ---

    function spoofChrome() {
        try {
            var brands = [
                { brand: "Google Chrome", version: "120" },
                { brand: "Chromium", version: "120" },
                { brand: "Not?A_Brand", version: "24" }
            ];
            if (!navigator.userAgentData) {
                Object.defineProperty(navigator, "userAgentData", {
                    configurable: true,
                    get: function () {
                        return {
                            brands: brands, mobile: false, platform: "macOS",
                            getHighEntropyValues: function () {
                                return Promise.resolve({
                                    architecture: "arm", bitness: "64", mobile: false, model: "",
                                    platform: "macOS", platformVersion: "14.0.0",
                                    uaFullVersion: "120.0.0.0", fullVersionList: brands
                                });
                            },
                            toJSON: function () { return { brands: brands, mobile: false, platform: "macOS" }; }
                        };
                    }
                });
            }
            try {
                Object.defineProperty(navigator, "vendor", { configurable: true, get: function () { return "Google Inc."; } });
            } catch (e) { /* vendor not redefinable here — harmless */ }
            if (!window.chrome) { window.chrome = { runtime: {}, webstore: {} }; }
        } catch (e) { /* best-effort */ }
    }

    function spoofFirefox() {
        // AMO only paints the real "Add to Firefox" install button when it believes it's Firefox WITH the
        // add-on manager — a UA string alone isn't enough. Define the legacy InstallTrigger global and a
        // minimal navigator.mozAddonManager. If this isn't enough on a given AMO build, we still rewrite
        // its "Download Firefox" fallback button below, so the affordance works either way.
        try {
            if (typeof window.InstallTrigger === "undefined") {
                Object.defineProperty(window, "InstallTrigger", {
                    configurable: true, value: { install: function () {}, enabled: function () { return true; } }
                });
            }
        } catch (e) { /* best-effort */ }
        try {
            if (!navigator.mozAddonManager) {
                Object.defineProperty(navigator, "mozAddonManager", {
                    configurable: true,
                    get: function () {
                        return {
                            getInstallForURL: function () { return Promise.resolve({ install: function () {} }); },
                            createInstall: function () { return Promise.resolve({ install: function () {} }); },
                            permissionPromptsEnabled: true,
                            addEventListener: function () {}, removeEventListener: function () {}
                        };
                    }
                });
            }
        } catch (e) { /* best-effort */ }
    }

    function spoofEdge() {
        try { if (!window.chrome) { window.chrome = { runtime: {}, webstore: {} }; } } catch (e) { /* best-effort */ }
    }

    if (STORE === "chrome") { spoofChrome(); }
    else if (STORE === "firefox") { spoofFirefox(); }
    else { spoofEdge(); }

    // --- 2. Find + rewrite the install button. ---

    var TAG = "__brownbearStoreButton";
    var ADD_LABEL = "Add to BrownBear";
    var REMOVE_LABEL = "Remove from BrownBear";
    var installed = false;     // last known state for the current extension
    var busy = false;
    var lastKey = null;        // the detail page we last queried, to re-query on SPA navigation

    function findButton() {
        var tagged = document.querySelector("[" + TAG + '="1"]');
        if (tagged && document.contains(tagged)) { return tagged; }
        // Firefox AMO renders the install (or "Download Firefox" fallback) button with stable classes.
        if (STORE === "firefox") {
            var amo = document.querySelector(
                ".AMInstallButton-button, .GetFirefoxButton-button, .InstallButtonWrapper button, .InstallButtonWrapper a");
            if (amo) { return amo; }
        }
        var nodes = document.querySelectorAll("button, a[role='button'], a.Button");
        for (var i = 0; i < nodes.length; i++) {
            var text = (nodes[i].textContent || "").trim();
            if (/^Add to (Chrome|Firefox|Edge|Opera|Brave|Safari|Desktop|Browser)\b/i.test(text)) { return nodes[i]; }
            if (STORE === "edge" && /^get$/i.test(text)) { return nodes[i]; }
            if (STORE === "firefox" && /^Download Firefox\b/i.test(text)) { return nodes[i]; }
        }
        return null;
    }

    function labelNode(button) {
        return button.querySelector('span[jsname="V67aGc"]')
            || button.querySelector("span:not(:empty)")
            || button;
    }

    function setLabel(button, text) {
        try { labelNode(button).textContent = text; } catch (e) { button.textContent = text; }
    }

    function send(action) {
        return window.webkit.messageHandlers.brownbearWebStore.postMessage({ action: action, url: location.href });
    }

    // Only WRITE when something actually differs — otherwise our own changes would re-trigger the
    // attribute MutationObserver below in a tight every-frame loop.
    function applyState(button) {
        if (busy) { return; }
        var want = installed ? REMOVE_LABEL : ADD_LABEL;
        if ((labelNode(button).textContent || "").trim() !== want) { setLabel(button, want); }
        if (button.hasAttribute("disabled")) { button.removeAttribute("disabled"); }
        if (button.disabled) { button.disabled = false; }
        if (button.getAttribute("aria-disabled") !== "false") { button.setAttribute("aria-disabled", "false"); }
        if (button.style.pointerEvents !== "auto") { button.style.pointerEvents = "auto"; }
        if (button.style.opacity !== "1") { button.style.opacity = "1"; }
    }

    function onClick(event) {
        event.preventDefault();
        event.stopImmediatePropagation();
        var button = event.currentTarget;
        if (busy) { return; }
        busy = true;
        setLabel(button, installed ? "Removing…" : "Adding…");
        send(installed ? "remove" : "install").then(function (result) {
            busy = false;
            if (result && typeof result.installed === "boolean") { installed = result.installed; }
            applyState(button);
        }).catch(function () {
            busy = false;
            applyState(button);   // revert to the prior state on failure
        });
    }

    function rewire() {
        if (STORE === "chrome") { hideChromeUnavailableNotice(); }
        var button = findButton();
        if (!button) { return; }
        if (button.getAttribute(TAG) !== "1") {
            // A fresh button element (first paint, or the SPA replaced it on re-render/navigation):
            // claim it and intercept its click in the capture phase so we beat the store's own handler.
            button.setAttribute(TAG, "1");
            button.addEventListener("click", onClick, true);
        }
        var key = location.pathname;
        if (key !== lastKey) {
            // Navigated to a different listing (SPA route change, no reload) — re-query its install state.
            lastKey = key;
            installed = false;
            busy = false;
            send("query").then(function (result) {
                if (result && typeof result.installed === "boolean") { installed = result.installed; }
                applyState(button);
            }).catch(function () { applyState(button); });
        }
        applyState(button);
    }

    // The Chrome store client-renders a red "Item currently unavailable / troubleshooting guide" notice
    // for our spoofed client even though BrownBear installs the item fine. Blank it (visibility:hidden, so
    // its reserved layout band stays and the title doesn't jump up), matched by visible text.
    function hideChromeUnavailableNotice() {
        if (!document.body) { return; }
        try {
            var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
            var node;
            while ((node = walker.nextNode())) {
                var text = (node.nodeValue || "").toLowerCase();
                if (text.indexOf("currently unavailable") < 0
                    && !(text.indexOf("troubleshooting") >= 0 && text.indexOf("guide") >= 0)) { continue; }
                var el = node.parentElement;
                while (el && el.parentElement && el.parentElement !== document.body
                       && (el.parentElement.textContent || "").length < 240) {
                    el = el.parentElement;
                }
                if (el) { el.style.visibility = "hidden"; el.style.backgroundColor = "transparent"; }
                return;
            }
        } catch (e) { /* best-effort */ }
    }

    var scheduled = false;
    function schedule() {
        if (scheduled) { return; }
        scheduled = true;
        requestAnimationFrame(function () { scheduled = false; try { rewire(); } catch (e) {} });
    }

    if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", schedule);
    } else {
        schedule();
    }
    try {
        // Watch childList AND attributes/characterData: the stores re-disable / relabel the SAME button
        // element (no childList change) after route-navigating, which a childList-only observer missed —
        // that was the "snaps back to Add to <Browser>, disabled" bug. applyState only writes on a real
        // difference, so this can't loop on our own edits.
        new MutationObserver(schedule).observe(document.documentElement, {
            childList: true, subtree: true, attributes: true, characterData: true
        });
    } catch (e) { /* no DOM yet — DOMContentLoaded will cover it */ }
    // SPA route changes between listings use history.pushState/replaceState (not just popstate); hook them.
    ["pushState", "replaceState"].forEach(function (method) {
        var original = history[method];
        if (typeof original === "function") {
            history[method] = function () {
                var result = original.apply(this, arguments);
                schedule();
                return result;
            };
        }
    });
    window.addEventListener("popstate", schedule);
    setInterval(schedule, 1500);   // safety net for late hydration that replaces the button
})();
