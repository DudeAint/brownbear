//
//  BrownBearBrowserViewController+NewTabPage.swift
//  BrownBear
//
//  The New Tab page: a clean search box over a frosted-glass start page, then either the user's
//  most-visited sites + bookmarks as favicon tiles, or — on a fresh install — a short onboarding
//  guide (userscripts, extensions, themes, GitHub). Private tabs get a distinct incognito page.
//  Split out of BrownBearBrowserViewController so that file stays under the length limit and the
//  large HTML/CSS/JS string literals live on their own. First-party content; any bookmark/history
//  strings are HTML-escaped and limited to http(s) before injection. The stylesheet and the inline
//  history-popover script are pulled into their own members so `newTabHTML` stays within the
//  function-body length limit.
//

import UIKit

extension BrownBearBrowserViewController {

    // MARK: - Load

    // Not `private`: also used by the WebExtensionBridgeHost conformance for chrome.tabs.create({}).
    /// `allowExtensionOverride` is true for normal new tabs (a `chrome_url_overrides.newtab` extension may
    /// replace the page). Session restore passes false for the throwaway placeholder it shows while it
    /// rebuilds a persisted extension tab in place — the override swap would CLOSE that placeholder and
    /// break the restore's in-place upgrade, so the placeholder always gets the plain built-in page.
    func loadNewTabPage(in tab: Tab, allowExtensionOverride: Bool = true) {
        tab.delegate = self
        // Forget any URL this tab previously committed: it is now genuinely the New Tab page, so a later
        // renderer loss must not resurrect the old page (and isShowingNewTabPage must read true).
        tab.prepareForNewTabPage()
        // Private tabs get a distinct incognito page (no shortcut tiles, explicit "not saved" copy);
        // normal tabs build from the user's bookmarks (a fast actor read).
        if tab.isPrivate {
            tab.webView.loadHTMLString(Self.privateNewTabHTML(), baseURL: nil)
            return
        }
        Task { @MainActor in
            // A chrome_url_overrides.newtab extension (Momentum, Tabliss, …) replaces the New Tab page.
            // Normal tabs can't load chrome-extension:// (their config has no per-extension scheme handler),
            // so swap this placeholder for a tab carrying the extension's page-session configuration. We
            // create the replacement BEFORE closing the placeholder so there's never a no-active-tab gap.
            // Skipped for private tabs (Chrome doesn't apply newtab overrides in incognito) and the common
            // no-override case, so the built-in NTP is unaffected for everyone without such an extension.
            if allowExtensionOverride, let (ext, path) = await firstNewTabOverride() {
                let session = WebExtensionPageSession(ext: ext, kind: .newtab, path: path)
                if session.pageURL != nil {
                    let configuration = await session.makeConfiguration()
                    guard let url = session.pageURL else { return }
                    let wasActive = tabManager.activeTabID == tab.id
                    let newTab = tabManager.createTab(adopting: configuration, activate: wasActive, isPrivate: false)
                    newTab.delegate = self
                    newTab.onClose = { session.invalidate() }   // retain the session for the tab's life
                    session.bind(to: newTab.webView)            // wire ports + live storage/cookie push before load
                    newTab.load(url)
                    tabManager.closeTab(id: tab.id)             // drop the placeholder now that newTab exists + is active
                    return
                }
            }
            let bookmarks = await BrownBearServices.shared.bookmarkStore.all()
            let visited = await BrownBearServices.shared.historyStore.topSites(limit: 8)
            tab.webView.loadHTMLString(Self.newTabHTML(bookmarks: bookmarks, visited: visited), baseURL: nil)
        }
    }

    /// The first enabled extension that overrides the New Tab page (`chrome_url_overrides.newtab`) with its
    /// override path, or nil when none declares one (the common case, so the built-in NTP is untouched).
    /// The store's enabled order is a deterministic precedence; Chrome's last-installed-wins isn't modeled
    /// (rare to have two newtab-override extensions enabled at once).
    private func firstNewTabOverride() async -> (ext: WebExtension, path: String)? {
        for ext in await BrownBearServices.shared.webExtensionStore.enabledExtensions() {
            if let path = ext.manifest?.newTabOverride, !path.isEmpty { return (ext, path) }
        }
        return nil
    }

    // MARK: - HTML builders

    private static func htmlEscape(_ string: String) -> String {
        var out = string.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        out = out.replacingOccurrences(of: "\"", with: "&quot;")
        out = out.replacingOccurrences(of: "'", with: "&#39;")
        return out
    }

    /// A clean New Tab page: a search box, then EITHER the user's bookmarks/most-visited as tiles OR —
    /// when there are none yet — a short onboarding guide to what makes BrownBear different (userscripts,
    /// extensions, themes). Tiles are plain `<a>` links and the search box is a plain `<form>`, so both
    /// navigate through the normal load flow — no privileged bridge. First-party content; bookmark
    /// titles/URLs are HTML-escaped and limited to http(s) before injection.
    private static func newTabHTML(bookmarks: [Bookmark], visited: [HistoryEntry]) -> String {
        let web = bookmarks.filter { ["http", "https"].contains($0.url.scheme?.lowercased() ?? "") }
        let visitedWeb = visited.filter { ["http", "https"].contains($0.url.scheme?.lowercased() ?? "") }
        let engine = AppSettings.searchEngine
        let engineHost = URL(string: engine.formAction)?.host ?? "www.google.com"

        var sections = ""
        var delayStep = 0.10
        if !visitedWeb.isEmpty {
            let entries = visitedWeb.prefix(8).map { ($0.title, $0.url.absoluteString, $0.url.host ?? "") }
            sections += tileSection(title: "Frequently visited", entries: entries, startDelay: delayStep)
            delayStep += 0.06
        }
        if !web.isEmpty {
            let entries = web.prefix(8).map { ($0.displayTitle, $0.url.absoluteString, $0.url.host ?? "") }
            sections += tileSection(title: "Shortcuts", entries: entries, startDelay: delayStep)
            delayStep += 0.06
        }
        if visitedWeb.isEmpty && web.isEmpty {
            sections = newTabGuideHTML
        } else {
            sections += newTabFooterHTML
        }
        // Then always pin the "report a broken extension" CTA below it — BrownBear's whole pitch is
        // running every extension, so the fastest way we hear about (and fix) a broken one is one tap away.
        sections += newTabIssueCTA

        // The search box's history popover data (recent sites), embedded safely for the inline script.
        let histItems = visitedWeb.prefix(8).map { ["t": $0.title, "u": $0.url.absoluteString, "h": $0.url.host ?? ""] }
        let histJSON = ((try? JSONSerialization.data(withJSONObject: histItems))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]")
            .replacingOccurrences(of: "<", with: "\\u003c")

        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
        <style>\(newTabCSS)</style></head><body>
          <div class="wrap">
            <div class="brand fade"><span class="mark">\(brandMark)</span><h1>BrownBear</h1></div>
            <div class="sbox fade" style="animation-delay:.04s">
              <form class="search" action="\(engine.formAction)" method="GET" autocomplete="off">
                <img class="elogo" src="https://\(engineHost)/favicon.ico" alt="" onerror="this.style.visibility='hidden'">
                <input name="\(engine.formQueryParam)" placeholder="Search \(engine.title)" autocapitalize="off" autocorrect="off" spellcheck="false">
              </form>
              <div class="sg" id="sg"></div>
            </div>
        \(sections)
          </div>
          <script>\(newTabScript(histJSON: histJSON))</script>
        </body></html>
        """
    }

    /// The New Tab page stylesheet. Held separately so `newTabHTML` stays within the body-length limit.
    private static let newTabCSS = """
    :root{color-scheme:light dark;
      --bg:#F0F0F5;--text:#1C1C1E;--sub:#6C6C70;--border:rgba(0,0,0,.07);
      --glass:rgba(255,255,255,.62);--glass2:rgba(255,255,255,.7);--hair:rgba(255,255,255,.85);
      --tile:rgba(255,255,255,.55);--lift:rgba(255,255,255,.7);
      --g1:#3A3A3C;--g2:#1C1C1E;--s1:rgba(0,0,0,.05);--s2:rgba(0,0,0,.08);}
    @media (prefers-color-scheme:dark){:root{
      --bg:#0A0A0C;--text:#F5F5F7;--sub:#9A9AA0;--border:rgba(255,255,255,.09);
      --glass:rgba(36,36,40,.58);--glass2:rgba(44,44,48,.66);--hair:rgba(255,255,255,.07);
      --tile:rgba(60,60,66,.42);--lift:rgba(255,255,255,.045);
      --g1:#48484A;--g2:#2C2C2E;--s1:rgba(0,0,0,.5);--s2:rgba(0,0,0,.6);}}
    *{box-sizing:border-box;-webkit-tap-highlight-color:transparent;}
    html,body{margin:0;min-height:100%;font-family:-apple-system,system-ui,sans-serif;
      background:var(--bg);color:var(--text);-webkit-font-smoothing:antialiased;}
    /* A clean, neutral top-lift instead of coloured glows — keeps the graphite-on-white identity. */
    body{background-image:radial-gradient(135% 85% at 50% -20%,var(--lift),transparent 60%);
      background-attachment:fixed;}
    .wrap{position:relative;z-index:1;max-width:600px;margin:0 auto;padding:max(64px,13vh) 22px 52px;}
    @keyframes up{from{opacity:0;transform:translateY(16px) scale(.985);}to{opacity:1;transform:none;}}
    .fade{opacity:0;animation:up .6s cubic-bezier(.16,.84,.34,1) both;}
    @media (prefers-reduced-motion:reduce){.fade{animation:none;opacity:1;}
      .tile,.row,form.search,.sgrow{transition:none;}}
    .brand{display:flex;align-items:center;gap:11px;justify-content:center;margin-bottom:28px;}
    .brand .mark{width:32px;height:32px;border-radius:10px;display:grid;place-items:center;
      background:linear-gradient(160deg,var(--g1),var(--g2));
      box-shadow:inset 0 .5px 0 rgba(255,255,255,.25),0 4px 12px var(--s2);}
    .brand .mark svg{width:22px;height:22px;display:block;}
    .brand h1{font-size:20px;font-weight:700;margin:0;letter-spacing:-.3px;}
    .sbox{position:relative;margin-bottom:34px;z-index:5;}
    form.search{display:flex;align-items:center;gap:11px;background:var(--glass);
      -webkit-backdrop-filter:blur(24px) saturate(1.6);backdrop-filter:blur(24px) saturate(1.6);
      border:.5px solid var(--border);border-radius:17px;padding:0 16px;height:56px;
      box-shadow:inset 0 .5px 0 var(--hair),0 10px 30px var(--s2);
      transition:box-shadow .28s ease,transform .28s ease;}
    form.search:focus-within{box-shadow:inset 0 .5px 0 var(--hair),0 16px 40px var(--s2);transform:translateY(-1px);}
    .elogo{width:20px;height:20px;border-radius:5px;flex:none;object-fit:contain;}
    form.search input{flex:1;border:0;background:transparent;font-size:17px;color:var(--text);
      outline:none;font-weight:450;}
    form.search input::placeholder{color:var(--sub);}
    /* History popover under the search box (the glassy suggestions panel). */
    .sg{position:absolute;left:0;right:0;top:62px;border-radius:17px;overflow:hidden;
      background:var(--glass2);-webkit-backdrop-filter:blur(26px) saturate(1.6);
      backdrop-filter:blur(26px) saturate(1.6);border:.5px solid var(--border);
      box-shadow:inset 0 .5px 0 var(--hair),0 18px 44px var(--s2);
      opacity:0;transform:translateY(-6px) scale(.99);pointer-events:none;
      transition:opacity .2s ease,transform .2s cubic-bezier(.16,.84,.34,1);}
    .sg.on{opacity:1;transform:none;pointer-events:auto;}
    .sgrow{display:flex;align-items:center;gap:11px;padding:11px 15px;text-decoration:none;color:var(--text);
      transition:background .12s ease;}
    .sgrow:active{background:rgba(127,127,127,.16);}
    .sgrow+.sgrow{border-top:.5px solid var(--border);}
    .sgrow img{width:18px;height:18px;border-radius:4px;flex:none;}
    .sgrow .st{font-size:15px;font-weight:500;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}
    .sgrow .sh{font-size:12px;color:var(--sub);margin-left:auto;flex:none;}
    .sghd{font-size:11px;font-weight:700;letter-spacing:.4px;color:var(--sub);
      text-transform:uppercase;padding:12px 15px 6px;}
    .sec{margin-bottom:26px;}
    .hd{font-size:13px;font-weight:600;color:var(--sub);margin:0 0 13px 4px;letter-spacing:-.1px;}
    .grid{display:grid;grid-template-columns:repeat(4,1fr);gap:20px 14px;}
    .tile{display:flex;flex-direction:column;align-items:center;gap:9px;
      text-decoration:none;color:var(--text);transition:transform .16s cubic-bezier(.34,1.56,.64,1);}
    .tile:active{transform:scale(.9);}
    .ico{position:relative;width:60px;height:60px;border-radius:18px;background:var(--tile);
      -webkit-backdrop-filter:blur(14px);backdrop-filter:blur(14px);border:.5px solid var(--border);
      display:grid;place-items:center;overflow:hidden;box-shadow:inset 0 .5px 0 var(--hair),0 4px 14px var(--s1);}
    .ico img{position:absolute;inset:0;width:100%;height:100%;object-fit:contain;
      padding:14px;background:#fff;opacity:0;transition:opacity .18s ease;}
    .ico .mono{font-size:24px;font-weight:600;color:var(--text);}
    .lbl{font-size:12px;font-weight:500;max-width:74px;white-space:nowrap;overflow:hidden;
      text-overflow:ellipsis;text-align:center;color:var(--sub);}
    .guide{display:flex;flex-direction:column;gap:13px;}
    .row{display:flex;align-items:center;gap:15px;background:var(--glass);
      -webkit-backdrop-filter:blur(22px) saturate(1.5);backdrop-filter:blur(22px) saturate(1.5);
      border:.5px solid var(--border);border-radius:22px;padding:17px 18px;text-decoration:none;color:inherit;
      box-shadow:inset 0 .5px 0 var(--hair),0 10px 28px var(--s2);transition:transform .18s ease;}
    a.row:active{transform:scale(.98);}
    .row .g{flex:none;width:46px;height:46px;border-radius:14px;display:grid;place-items:center;
      background:linear-gradient(160deg,var(--g1),var(--g2));
      box-shadow:inset 0 .5px 0 rgba(255,255,255,.22),0 4px 12px var(--s2);}
    .row .g svg{width:23px;height:23px;}
    .row .body{flex:1;min-width:0;}
    .row .t{font-size:16px;font-weight:600;margin:0 0 3px;letter-spacing:-.1px;}
    .row .d{font-size:13px;line-height:1.42;color:var(--sub);margin:0;}
    .row .chev{flex:none;width:9px;height:9px;border-right:2px solid var(--sub);
      border-bottom:2px solid var(--sub);transform:rotate(-45deg);opacity:.45;margin-right:2px;}
    .hello{text-align:center;margin:2px 0 26px;}
    .hello .t{font-size:27px;font-weight:700;letter-spacing:-.6px;margin:0 0 8px;
      background:linear-gradient(180deg,var(--text),var(--sub));-webkit-background-clip:text;
      -webkit-text-fill-color:transparent;}
    .hello .d{font-size:15px;line-height:1.45;color:var(--sub);margin:0 auto;max-width:330px;}
    /* The "report a broken extension" CTA: a small rounded accent pill (graphite gradient, like the brand
       chips) — a button, not a full card. Centered + non-intrusive, sits under the GitHub section. */
    .cta{text-align:center;margin:18px 0 2px;}
    .cta a{display:inline-flex;align-items:center;gap:7px;text-decoration:none;
      background:linear-gradient(160deg,var(--g1),var(--g2));color:#fff;
      font-size:13px;font-weight:600;letter-spacing:-.1px;padding:9px 16px;border-radius:999px;
      box-shadow:inset 0 .5px 0 rgba(255,255,255,.22),0 5px 16px var(--s2);
      transition:transform .16s cubic-bezier(.34,1.56,.64,1);}
    .cta a:active{transform:scale(.94);}
    .cta a svg{width:15px;height:15px;flex:none;}
    @media (max-width:380px){.grid{grid-template-columns:repeat(3,1fr);}}
    """

    /// The inline history-popover script (recent-sites filter under the search box). Held separately so
    /// `newTabHTML` stays within the body-length limit.
    private static func newTabScript(histJSON: String) -> String {
        """
        var H=\(histJSON);
        var inp=document.querySelector(".search input"),sg=document.getElementById("sg");
        function esc(s){var d=document.createElement("div");d.textContent=s==null?"":s;return d.innerHTML;}
        function render(q){q=(q||"").toLowerCase();
          var items=H.filter(function(e){return !q||(e.t||"").toLowerCase().indexOf(q)>=0||(e.u||"").toLowerCase().indexOf(q)>=0;}).slice(0,6);
          if(!items.length){sg.innerHTML="";return false;}
          sg.innerHTML='<div class="sghd">Recently visited</div>'+items.map(function(e){
            return '<a class="sgrow" href="'+esc(e.u)+'">'
              +'<img src="https://'+esc(e.h)+'/favicon.ico" onerror="this.style.visibility=\\'hidden\\'">'
              +'<span class="st">'+esc(e.t||e.h)+'</span>'
              +'<span class="sh">'+esc(e.h)+'</span></a>';
          }).join("");return true;}
        if(inp&&H.length){
          inp.addEventListener("focus",function(){if(render(inp.value))sg.classList.add("on");});
          inp.addEventListener("input",function(){render(inp.value)?sg.classList.add("on"):sg.classList.remove("on");});
          inp.addEventListener("blur",function(){setTimeout(function(){sg.classList.remove("on");},160);});
        }
        """
    }

    /// One titled grid section of favicon tiles (frequently-visited sites or bookmarks), entrance-staggered.
    private static func tileSection(title: String, entries: [(String, String, String)], startDelay: Double) -> String {
        let tiles = entries.enumerated().map { index, entry -> String in
            let (rawTitle, rawURL, rawHost) = entry
            let t = htmlEscape(rawTitle.isEmpty ? rawHost : rawTitle)
            let url = htmlEscape(rawURL)
            let host = htmlEscape(rawHost)
            let letter = htmlEscape((t.first.map { String($0).uppercased() }) ?? "•")
            let delay = String(format: "%.2f", startDelay + Double(index) * 0.025)
            return """
            <a class="tile fade" style="animation-delay:\(delay)s" href="\(url)">
            <span class="ico"><img src="https://\(host)/favicon.ico" onload="this.style.opacity=1" onerror="this.remove()" alt="">
            <span class="mono">\(letter)</span></span>
            <span class="lbl">\(t)</span></a>
            """
        }.joined(separator: "\n")
        return """
        <div class="sec fade" style="animation-delay:\(String(format: "%.2f", startDelay))s">
          <p class="hd">\(htmlEscape(title))</p>
          <div class="grid">
        \(tiles)
          </div>
        </div>
        """
    }

    /// Premium SVG glyphs for the guide (no plain emoji), drawn white inside a graphite gradient chip.
    // Inline SVG icon data: a single token of path/attribute data that doesn't wrap meaningfully.
    // swiftlint:disable line_length
    private static let glyphScript = ##"<svg viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 8l-4 4 4 4"/><path d="M15 8l4 4-4 4"/></svg>"##
    private static let glyphPuzzle = ##"<svg viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.9" stroke-linejoin="round"><rect x="3" y="3" width="7.5" height="7.5" rx="2"/><rect x="13.5" y="3" width="7.5" height="7.5" rx="2"/><rect x="3" y="13.5" width="7.5" height="7.5" rx="2"/><rect x="13.5" y="13.5" width="7.5" height="7.5" rx="2"/></svg>"##
    private static let glyphTheme = ##"<svg viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.9"><circle cx="12" cy="12" r="9"/><path fill="#fff" stroke="none" d="M12 3a9 9 0 010 18z"/></svg>"##
    private static let glyphGithub = ##"<svg viewBox="0 0 24 24" fill="#fff"><path d="M12 2C6.48 2 2 6.58 2 12.25c0 4.53 2.87 8.37 6.84 9.73.5.1.68-.22.68-.49 0-.24-.01-.88-.01-1.73-2.78.62-3.37-1.37-3.37-1.37-.46-1.18-1.11-1.5-1.11-1.5-.91-.64.07-.62.07-.62 1 .07 1.53 1.06 1.53 1.06.89 1.56 2.34 1.11 2.91.85.09-.66.35-1.11.63-1.36-2.22-.26-4.56-1.14-4.56-5.06 0-1.12.39-2.03 1.03-2.75-.1-.26-.45-1.3.1-2.71 0 0 .84-.27 2.75 1.05A9.4 9.4 0 0112 6.84c.85 0 1.71.12 2.51.34 1.91-1.32 2.75-1.05 2.75-1.05.55 1.41.2 2.45.1 2.71.64.72 1.03 1.63 1.03 2.75 0 3.93-2.34 4.79-4.57 5.05.36.32.68.94.68 1.9 0 1.37-.01 2.47-.01 2.81 0 .27.18.59.69.49A10.26 10.26 0 0022 12.25C22 6.58 17.52 2 12 2z"/></svg>"##
    /// The BrownBear mark: a clean bear face (white head + ears, graphite eyes + nose) drawn inside the
    /// brand chip — the actual logo, replacing the bare "B" letter.
    private static let brandMark = ##"<svg viewBox="0 0 24 24"><g fill="#fff"><circle cx="6.7" cy="7.4" r="3"/><circle cx="17.3" cy="7.4" r="3"/><circle cx="12" cy="13.6" r="7.4"/></g><g fill="#2a2a2c"><circle cx="9.5" cy="12.4" r="1.05"/><circle cx="14.5" cy="12.4" r="1.05"/><circle cx="12" cy="15.5" r="1.4"/></g></svg>"##
    // swiftlint:enable line_length

    /// The onboarding guide shown on a fresh New Tab page (no bookmarks/history yet). Static, first-party.
    private static var newTabGuideHTML: String { """
    <div class="hello fade" style="animation-delay:.06s">
      <p class="t">Make the web yours</p>
      <p class="d">A power browser that runs userscripts and real extensions, right on iOS.</p>
    </div>
    <div class="guide">
      <a class="row fade" style="animation-delay:.14s" href="https://greasyfork.org/">
        <span class="g">\(glyphScript)</span>
        <span class="body">
          <p class="t">Userscripts</p>
          <p class="d">Install a script to change how any site looks or works. Browse thousands on GreasyFork.</p>
        </span>
        <span class="chev"></span>
      </a>
      <a class="row fade" style="animation-delay:.2s" href="https://chromewebstore.google.com/">
        <span class="g">\(glyphPuzzle)</span>
        <span class="body">
          <p class="t">Extensions</p>
          <p class="d">Add Chrome and Firefox extensions: ad blockers, userscript managers, and more.</p>
        </span>
        <span class="chev"></span>
      </a>
      <div class="row fade" style="animation-delay:.26s">
        <span class="g">\(glyphTheme)</span>
        <span class="body">
          <p class="t">Make it yours</p>
          <p class="d">Light, Dark, or the classic OG BrownBear theme, in Settings &rsaquo; Appearance.</p>
        </span>
      </div>
      <a class="row fade" style="animation-delay:.32s" href="https://github.com/DudeAint/brownbear">
        <span class="g">\(glyphGithub)</span>
        <span class="body">
          <p class="t">Open on GitHub</p>
          <p class="d">BrownBear is built in the open. Follow along, file issues, or star the project.</p>
        </span>
        <span class="chev"></span>
      </a>
    </div>
    """ }

    /// A slim footer (returning users) keeping GitHub one tap away below their tiles.
    private static let newTabFooterHTML = """
    <a class="row fade" style="animation-delay:.3s" href="https://github.com/DudeAint/brownbear">
      <span class="g">\(glyphGithub)</span>
      <span class="body">
        <p class="t">Open on GitHub</p>
        <p class="d">BrownBear is built in the open. Follow along, file issues, or star the project.</p>
      </span>
      <span class="chev"></span>
    </a>
    """

    /// The "report a broken extension" CTA — a small rounded accent pill (not a full card) under the
    /// GitHub section. BrownBear's pitch is running every extension, so a broken one is the most valuable
    /// signal we get, and the gap between "it's broken" and a *useful* report is where most reports die.
    /// The pill still opens a **prefilled** GitHub issue (label + title prefix + a body asking for the
    /// extension, the site, and the Logs-tab output) — the conversion win is kept; only the heavy card is
    /// traded for a compact, non-intrusive accent button.
    private static var newTabIssueCTA: String {
        let body = """
        Thanks for helping make BrownBear run every extension — a few details get this fixed fast:

        **Which extension?** (its name + where you got it — Chrome Web Store, Edge, Firefox…)


        **What should happen, and what happens instead?**


        **Which website?** (paste the URL if it only breaks on certain sites)


        **Logs** — open Settings › this extension › Logs and paste anything in red below:


        """
        var components = URLComponents(string: "https://github.com/DudeAint/brownbear/issues/new")
        components?.queryItems = [
            URLQueryItem(name: "labels", value: "extension,bug"),
            URLQueryItem(name: "title", value: "Extension not working: "),
            URLQueryItem(name: "body", value: body)
        ]
        let href = htmlEscape(components?.url?.absoluteString
            ?? "https://github.com/DudeAint/brownbear/issues/new")
        return """
        <p class="cta fade" style="animation-delay:.36s"><a href="\(href)">\(glyphGithub)Extension not working? Report it</a></p>
        """
    }

    /// The private/incognito New Tab page: a dark, self-explanatory page that makes clear nothing is
    /// being saved. No shortcut tiles (which would leak browsing) — just the search box and the
    /// privacy explanation, matching Safari/Chrome incognito. First-party, no user strings injected.
    private static func privateNewTabHTML() -> String {
        let engine = AppSettings.searchEngine
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
        <style>
          :root{color-scheme:dark;--bg:#161020;--field:#241a33;--text:#F3EEFA;--sub:#A99CC2;
            --accent:#B79CF0;--border:#33264a;}
          *{box-sizing:border-box;-webkit-tap-highlight-color:transparent;}
          html,body{margin:0;height:100%;font-family:-apple-system,system-ui,sans-serif;
            background:var(--bg);color:var(--text);}
          .wrap{max-width:560px;margin:0 auto;padding:max(48px,10vh) 24px 40px;text-align:center;}
          .glyph{font-size:40px;margin-bottom:14px;}
          h1{font-size:22px;font-weight:800;margin:0 0 10px;letter-spacing:-.3px;}
          p{font-size:15px;line-height:1.5;color:var(--sub);margin:0 auto 28px;max-width:420px;}
          form.search{display:flex;align-items:center;gap:10px;background:var(--field);
            border:1px solid var(--border);border-radius:16px;padding:0 14px;height:52px;text-align:left;}
          form.search svg{width:20px;height:20px;fill:var(--sub);flex:none;}
          form.search input{flex:1;border:0;background:transparent;font-size:17px;color:var(--text);outline:none;}
        </style></head><body>
          <div class="wrap">
            <div class="glyph">🕶️</div>
            <h1>Private Browsing</h1>
            <p>Pages you view in private tabs won't appear in your history, and cookies and site
               data are cleared when you close them. Downloads and bookmarks you save are kept.</p>
            <form class="search" action="\(engine.formAction)" method="GET" autocomplete="off">
              <svg viewBox="0 0 24 24"><path d="M21 20l-5.6-5.6a7 7 0 10-1.4 1.4L20 21zM5 10a5 5 0 1110 0 5 5 0 01-10 0z"/></svg>
              <input name="\(engine.formQueryParam)" placeholder="Search privately" autocapitalize="off" autocorrect="off" spellcheck="false">
            </form>
          </div>
        </body></html>
        """
    }
}
