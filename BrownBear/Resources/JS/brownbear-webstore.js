//
//  brownbear-webstore.js
//  BrownBear
//
//  Injected at document-start in the PAGE world on every page; it does nothing unless the page is a
//  Chrome Web Store detail page. There it:
//    1. Makes the store believe this is desktop Chrome (navigator.userAgentData / vendor / window.chrome
//       spoof) so it renders the enabled install button and skips the "you're not on Chrome" banner.
//    2. Rewrites the store's install button to "Add to BrownBear" / "Remove from BrownBear" and routes
//       its click to BrownBear's native installer (window.webkit.messageHandlers.brownbearWebStore),
//       intercepting the page's own handler. Re-applies as the SPA re-renders / navigates.
//
//  The native side (WebStoreInstallHandler) does the real CRX download + install/remove and replies,
//  and additionally forces a desktop Chrome User-Agent for store hosts at the navigation layer.
//

(function () {
    "use strict";

    var host = location.hostname;
    var isStore = host === "chromewebstore.google.com"
        || (host === "chrome.google.com" && location.pathname.indexOf("/webstore") === 0);
    if (!isStore) { return; }

    // --- 1. Look like desktop Chrome so the store renders the real install button and no banner. ---
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
                        brands: brands,
                        mobile: false,
                        platform: "macOS",
                        getHighEntropyValues: function () {
                            return Promise.resolve({
                                architecture: "arm", bitness: "64", mobile: false, model: "",
                                platform: "macOS", platformVersion: "14.0.0",
                                uaFullVersion: "120.0.0.0", fullVersionList: brands
                            });
                        },
                        toJSON: function () {
                            return { brands: brands, mobile: false, platform: "macOS" };
                        }
                    };
                }
            });
        }
        try {
            Object.defineProperty(navigator, "vendor", {
                configurable: true, get: function () { return "Google Inc."; }
            });
        } catch (e) { /* vendor not redefinable on this engine — harmless */ }
        if (!window.chrome) { window.chrome = { runtime: {}, webstore: {} }; }
    } catch (e) { /* spoof best-effort */ }

    // --- 2. Rewrite the install button. ---
    var TAG = "__brownbearStoreButton";
    var ADD_LABEL = "Add to BrownBear";
    var REMOVE_LABEL = "Remove from BrownBear";
    var installed = false;     // last known state for the current extension
    var busy = false;

    function extensionId() {
        var parts = location.pathname.split("/").filter(Boolean);
        for (var i = parts.length - 1; i >= 0; i--) {
            if (/^[a-p]{32}$/.test(parts[i])) { return parts[i]; }
        }
        return null;
    }

    function labelNode(button) {
        return button.querySelector('span[jsname="V67aGc"]')
            || button.querySelector("span:not(:empty)")
            || button;
    }

    function findButton() {
        var tagged = document.querySelector("button[" + TAG + '="1"]');
        if (tagged) { return tagged; }
        var buttons = document.querySelectorAll("button");
        for (var i = 0; i < buttons.length; i++) {
            var text = (buttons[i].textContent || "").trim();
            if (/^Add to (Chrome|Desktop|Firefox|Edge|Opera|Brave|Safari|Browser)\b/i.test(text)) {
                return buttons[i];
            }
        }
        return null;
    }

    function send(action, id) {
        return window.webkit.messageHandlers.brownbearWebStore.postMessage({ action: action, id: id });
    }

    function setLabel(button, text) {
        labelNode(button).textContent = text;
    }

    function applyState(button) {
        if (busy) { return; }
        setLabel(button, installed ? REMOVE_LABEL : ADD_LABEL);
        button.removeAttribute("disabled");
        button.disabled = false;
        button.setAttribute("aria-disabled", "false");
        button.style.pointerEvents = "auto";
        button.style.opacity = "1";
    }

    function onClick(event) {
        event.preventDefault();
        event.stopImmediatePropagation();
        var button = event.currentTarget;
        var id = extensionId();
        if (!id || busy) { return; }
        busy = true;
        setLabel(button, installed ? "Removing…" : "Adding…");
        send(installed ? "remove" : "install", id).then(function (result) {
            busy = false;
            if (result && typeof result.installed === "boolean") { installed = result.installed; }
            applyState(button);
        }).catch(function () {
            busy = false;
            applyState(button);   // revert to the prior state on failure
        });
    }

    // The store client-renders a red "Item currently unavailable / check the troubleshooting guide"
    // notice for some clients (our spoofed desktop-Chrome-on-iOS hits it), even though BrownBear can
    // install the item fine. It's not in the SSR, so match it by visible text at runtime and hide its
    // banner container — climbing only while the container stays small so we never nuke real content.
    function hideUnavailableNotice() {
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
                if (el) { el.style.display = "none"; }
                return;
            }
        } catch (e) { /* best-effort */ }
    }

    function rewire() {
        hideUnavailableNotice();
        var id = extensionId();
        if (!id) { return; }
        var button = findButton();
        if (!button) { return; }
        if (button.getAttribute(TAG) !== "1") {
            button.setAttribute(TAG, "1");
            button.addEventListener("click", onClick, true);   // capture → beats the store's handler
            // Ask native whether it's already added, then paint the right label.
            send("query", id).then(function (result) {
                if (result && typeof result.installed === "boolean") { installed = result.installed; }
                applyState(button);
            }).catch(function () { applyState(button); });
        }
        applyState(button);
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
        new MutationObserver(schedule).observe(document.documentElement, { childList: true, subtree: true });
    } catch (e) { /* no DOM yet — DOMContentLoaded will cover it */ }
    // SPA route changes between extensions reset our state, so re-query.
    window.addEventListener("popstate", function () { installed = false; busy = false; schedule(); });
    setInterval(schedule, 2000);   // safety net for late hydration that replaces the button
})();
