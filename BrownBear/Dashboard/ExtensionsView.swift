//
//  ExtensionsView.swift
//  BrownBear
//
//  The Extensions tab of the dashboard: install a .crx/.zip browser extension, enable/disable it,
//  and remove it. Content scripts then run on matching pages via the chrome.* runtime (Module 6).
//

import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ExtensionsViewModel: ObservableObject {
    @Published private(set) var extensions: [WebExtension] = []
    @Published private(set) var isInstalling = false
    @Published var errorMessage: String?

    private var store: WebExtensionStore { BrownBearServices.shared.webExtensionStore }
    private var storage: WebExtensionStorage { BrownBearServices.shared.webExtensionStorage }

    func load() async { extensions = await store.all() }

    func install(data: Data) async {
        do {
            _ = try await store.install(archive: data)
            await load()
            notifyChanged()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Fetch and install from a store link — Chrome Web Store, Edge Add-ons, or Firefox (AMO) — or a
    /// bare 32-char Chrome id.
    func installFromStore(_ input: String) async {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isInstalling = true
        defer { isInstalling = false }
        do {
            guard let source = ExtensionStoreSource.detect(fromInput: trimmed) else {
                errorMessage = "Paste a Chrome Web Store, Edge Add-ons, or Firefox link — or a 32-char Chrome id."
                return
            }
            let data = try await source.downloadArchive()
            _ = try await store.install(archive: data, storeID: source.storeID)
            await load()
            notifyChanged()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func setEnabled(_ ext: WebExtension, _ enabled: Bool) async {
        await store.setEnabled(id: ext.id, enabled)
        await load()
        notifyChanged()
    }

    func remove(_ ext: WebExtension) async {
        await store.remove(id: ext.id)
        await storage.clearAll(extensionID: ext.id)
        // Purge the runtime stores too so a reinstalled id starts clean (DNR dynamic/session rules,
        // enabled-ruleset overrides, and registered userScripts).
        await BrownBearServices.shared.webExtensionDNRStore.clearAll(extensionID: ext.id)
        await BrownBearServices.shared.webExtensionUserScriptStore.clearAll(extensionID: ext.id)
        await load()
        notifyChanged()
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: .brownBearExtensionsDidChange, object: nil)
    }
}

struct ExtensionsView: View {

    @StateObject private var model = ExtensionsViewModel()
    @State private var importing = false
    @State private var storePrompting = false
    @State private var storeInput = ""
    /// Mirrors AppSettings.extensionsToolbarHidden so the toggle re-pins/unpins the toolbar button live.
    @AppStorage(AppSettings.Key.extensionsToolbarHidden) private var toolbarHidden = false

    private var allowedTypes: [UTType] {
        [.zip, UTType(filenameExtension: "crx") ?? .data]
    }

    var body: some View {
        List {
            if !model.extensions.isEmpty {
                Section {
                    ForEach(model.extensions) { ext in
                        extensionRow(ext)
                            .listRowBackground(BBTheme.Color.card)
                    }
                } header: {
                    Text("Installed").foregroundStyle(BBTheme.Color.textSecondary)
                }
                toolbarSection
            }
            recommendedSections
        }
        .scrollContentBackground(.hidden)
        .overlay {
            if model.isInstalling {
                ZStack {
                    Color.black.opacity(0.25).ignoresSafeArea()
                    ProgressView("Downloading…")
                        .padding(20)
                        .background(BBTheme.Color.card, in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
        .background(BBTheme.backgroundGradient)
        .navigationTitle("Extensions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button { importing = true } label: { Label("Install from file…", systemImage: "doc.badge.plus") }
                    Button { storePrompting = true } label: { Label("From a web store…", systemImage: "link") }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: allowedTypes) { result in
            handleImport(result)
        }
        .alert("Install from a web store", isPresented: $storePrompting) {
            TextField("Store link or extension ID", text: $storeInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Install") {
                let value = storeInput
                storeInput = ""
                Task { await model.installFromStore(value) }
            }
            Button("Cancel", role: .cancel) { storeInput = "" }
        } message: {
            Text("Paste a Chrome Web Store, Edge Add-ons, or Firefox (AMO) link — or a 32-character Chrome id.")
        }
        .alert("Couldn’t install", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .task { await model.load() }
    }

    // MARK: - Toolbar pin

    /// A toggle to show/hide the quick extensions button in the browser's bottom toolbar. Writing the
    /// shared key (via @AppStorage) and posting the notification re-pins/unpins it live.
    private var toolbarSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { !toolbarHidden },
                set: { newValue in
                    toolbarHidden = !newValue
                    NotificationCenter.default.post(name: .brownBearExtensionsToolbarChanged, object: nil)
                }
            )) {
                Label("Show in toolbar", systemImage: "puzzlepiece.extension")
                    .foregroundStyle(BBTheme.Color.textPrimary)
            }
            .tint(BBTheme.Color.toggleOn)
            .listRowBackground(BBTheme.Color.card)
        } footer: {
            Text("Adds a quick extensions button to the browser's bottom toolbar. Long-press it to hide it again.")
                .font(.caption).foregroundStyle(BBTheme.Color.textSecondary)
        }
    }

    // MARK: - Recommended

    /// Curated one-tap installs, grouped by a small category label, hiding any already installed.
    @ViewBuilder private var recommendedSections: some View {
        let available = Self.recommended.filter { rec in
            !model.extensions.contains {
                $0.id == rec.id || $0.displayName.localizedCaseInsensitiveContains(rec.name)
            }
        }
        ForEach(Self.recommendedCategories, id: \.self) { category in
            let items = available.filter { $0.category == category }
            if !items.isEmpty {
                Section {
                    ForEach(items) { recommendedRow($0) }
                } header: {
                    Text(category).foregroundStyle(BBTheme.Color.textSecondary)
                }
            }
        }
        Section {
            ForEach(Self.stores) { store in storeRow(store) }
        } header: {
            Text("Browse the stores").foregroundStyle(BBTheme.Color.textSecondary)
        } footer: {
            Text("Opens the store in BrownBear, where the Add to BrownBear button installs any extension in one tap.")
                .font(.caption).foregroundStyle(BBTheme.Color.textSecondary)
        }
    }

    /// A row that opens an extension store's homepage in BrownBear (the browser handles the
    /// notification, dismisses this dashboard, and loads it in a new tab).
    private func storeRow(_ store: ExtensionStoreLink) -> some View {
        Button {
            NotificationCenter.default.post(name: .brownBearOpenURL, object: nil,
                                            userInfo: ["url": store.url])
        } label: {
            HStack(spacing: 12) {
                AsyncImage(url: store.iconURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFit().padding(7)
                    } else {
                        Image(systemName: "bag.fill").font(.system(size: 15))
                            .foregroundStyle(BBTheme.Color.textSecondary)
                    }
                }
                .frame(width: 40, height: 40)
                .background(BBTheme.Color.fieldFill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                Text(store.name).font(.body.weight(.semibold)).foregroundStyle(BBTheme.Color.textPrimary)
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(BBTheme.Color.textSecondary)
            }
        }
        .listRowBackground(BBTheme.Color.card)
    }

    private func recommendedRow(_ rec: RecommendedExtension) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: rec.iconURL) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFit().padding(7)
                } else {
                    Image(systemName: "puzzlepiece.extension.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(BBTheme.Color.textSecondary)
                }
            }
            .frame(width: 40, height: 40)
            .background(BBTheme.Color.fieldFill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(rec.name).font(.body.weight(.semibold)).foregroundStyle(BBTheme.Color.textPrimary)
                    if rec.openSource {
                        Text("Open source")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(BBTheme.Color.secure)
                    }
                }
                Text(rec.blurb)
                    .font(.caption)
                    .foregroundStyle(BBTheme.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button {
                Task { await model.installFromStore(rec.id) }
            } label: {
                Text("Get").font(.subheadline.weight(.bold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(BBTheme.Color.accent)
            .disabled(model.isInstalling)
        }
        .padding(.vertical, 2)
        .listRowBackground(BBTheme.Color.card)
    }

    private func extensionRow(_ ext: WebExtension) -> some View {
        HStack(spacing: 12) {
            ExtensionIconView(ext: ext)
            VStack(alignment: .leading, spacing: 3) {
                Text(ext.displayName).font(.body.weight(.semibold)).foregroundStyle(BBTheme.Color.textPrimary)
                Text(subtitle(for: ext))
                    .font(.caption).foregroundStyle(BBTheme.Color.textSecondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { ext.enabled },
                set: { newValue in Task { await model.setEnabled(ext, newValue) } }
            ))
            .labelsHidden().tint(BBTheme.Color.toggleOn)
        }
        .padding(.vertical, 4)
        .swipeActions {
            Button(role: .destructive) { Task { await model.remove(ext) } } label: {
                Label("Remove", systemImage: "trash")
            }
        }
        .contextMenu {
            pageActions(for: ext)
            Divider()
            // Long-press to uninstall (in addition to the swipe action) — the discoverable gesture the
            // owner asked for. Destructive role styles it red and groups it at the bottom.
            Button(role: .destructive) { Task { await model.remove(ext) } } label: {
                Label("Uninstall \(ext.displayName)", systemImage: "trash")
            }
        }
    }

    /// Open-popup / open-options actions, shown when the extension declares those pages.
    @ViewBuilder
    private func pageActions(for ext: WebExtension) -> some View {
        if ext.manifest?.action?.defaultPopup != nil {
            Button { openPage(ext, .popup) } label: { Label("Open popup", systemImage: "macwindow") }
        }
        if ext.manifest?.optionsPage != nil {
            Button { openPage(ext, .options) } label: { Label("Options", systemImage: "gearshape") }
        }
    }

    private func openPage(_ ext: WebExtension, _ kind: WebExtensionPageViewController.Kind) {
        let controller = WebExtensionPageViewController(ext: ext, kind: kind)
        TopViewControllerPresenter.present(controller.wrappedForPresentation())
    }

    private func subtitle(for ext: WebExtension) -> String {
        let manifest = ext.manifest
        var parts = ["v\(ext.version)"]
        let scripts = manifest?.contentScripts.count ?? 0
        if scripts > 0 { parts.append("\(scripts) content script\(scripts == 1 ? "" : "s")") }
        if manifest?.background != nil { parts.append("background") }
        let rulesets = manifest?.declarativeNetRequest.count ?? 0
        if rulesets > 0 { parts.append("\(rulesets) blocking ruleset\(rulesets == 1 ? "" : "s")") }
        return parts.joined(separator: "  ·  ")
    }

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let needsStop = url.startAccessingSecurityScopedResource()
            defer { if needsStop { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                model.errorMessage = "Couldn’t read the selected file."
                return
            }
            Task { await model.install(data: data) }
        case .failure(let error):
            model.errorMessage = error.localizedDescription
        }
    }
}

/// Loads an extension's own icon — its action/toolbar icon, else the largest manifest icon — from the
/// extension package, falling back to the generic puzzle glyph. This is the same icon the "•••" menu
/// shows; the dashboard previously only ever showed the puzzle placeholder.
struct ExtensionIconView: View {
    let ext: WebExtension
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Image(systemName: "puzzlepiece.extension.fill")
                    .foregroundStyle(BBTheme.Color.accent)
            }
        }
        .frame(width: 28, height: 28)
        .task(id: ext.id) {
            guard let path = WebExtensionIconResolver.bestIconPath(ext.manifest) else { return }
            if let data = await BrownBearServices.shared.webExtensionStore.file(extensionID: ext.id, path: path),
               let loaded = UIImage(data: data) {
                image = loaded
            }
        }
    }
}

// MARK: - Recommended extensions (curated one-tap installs)

/// A curated extension the Extensions tab offers to install in one tap. `id` is the Chrome Web Store
/// id (which `installFromStore` accepts directly); `iconDomain` is the project's site, used to fetch a
/// real icon via Google's favicon service so the row shows the extension's actual logo, not an emoji.
struct RecommendedExtension: Identifiable {
    let id: String
    let name: String
    let category: String
    let iconDomain: String
    let blurb: String
    let openSource: Bool

    var iconURL: URL? { URL(string: "https://www.google.com/s2/favicons?domain=\(iconDomain)&sz=64") }
}

/// A link to an extension store's homepage, opened in BrownBear so the in-page installer can take over.
struct ExtensionStoreLink: Identifiable {
    let id: String
    let name: String
    let iconDomain: String
    let urlString: String

    var url: URL { URL(string: urlString) ?? URL(string: "https://chromewebstore.google.com/")! }
    var iconURL: URL? { URL(string: "https://www.google.com/s2/favicons?domain=\(iconDomain)&sz=64") }
}

extension ExtensionsView {
    /// Category display order for the recommended sections (small, non-intrusive labels).
    static let recommendedCategories = ["Userscripts", "Ad blocking & privacy", "Productivity", "Media", "Appearance"]

    /// Direct links to the three extension stores (Chrome, Edge, Firefox) for browsing anything not listed.
    static let stores: [ExtensionStoreLink] = [
        ExtensionStoreLink(id: "chrome", name: "Chrome Web Store", iconDomain: "chromewebstore.google.com",
                           urlString: "https://chromewebstore.google.com/category/extensions"),
        ExtensionStoreLink(id: "edge", name: "Edge Add-ons", iconDomain: "microsoftedge.microsoft.com",
                           urlString: "https://microsoftedge.microsoft.com/addons/category/Productivity"),
        ExtensionStoreLink(id: "firefox", name: "Firefox Add-ons", iconDomain: "addons.mozilla.org",
                           urlString: "https://addons.mozilla.org/firefox/extensions/")
    ]

    /// The curated set — popular, useful extensions across categories. Store ids should be
    /// device-verified; an install that fails surfaces the normal error alert, so a stale id is
    /// non-fatal (and the store links above cover anything not listed).
    static let recommended: [RecommendedExtension] = [
        // Userscripts
        RecommendedExtension(id: "dhdgffkkebhmkfjojejmpbldmpobfkfo", name: "Tampermonkey",
                             category: "Userscripts", iconDomain: "tampermonkey.net",
                             blurb: "The most popular userscript manager. Run scripts that customize any site.",
                             openSource: false),
        RecommendedExtension(id: "jinjaccalgkegednnccohejagnlnfdag", name: "Violentmonkey",
                             category: "Userscripts", iconDomain: "violentmonkey.github.io",
                             blurb: "Open-source userscript manager with a clean, privacy-minded design.",
                             openSource: true),
        RecommendedExtension(id: "ndcooeababalnlpkfedmmbbbgkljhpjf", name: "ScriptCat",
                             category: "Userscripts", iconDomain: "scriptcat.org",
                             blurb: "Open-source script manager that also runs scripts in the background, on a schedule.",
                             openSource: true),
        RecommendedExtension(id: "clngdbkpkpeebahjckkjfobafhncgmne", name: "Stylus",
                             category: "Userscripts", iconDomain: "github.com",
                             blurb: "Open-source user-styles manager. Restyle any site with custom CSS themes.",
                             openSource: true),
        // Ad blocking & privacy
        RecommendedExtension(id: "ddkjiahejlhfcafbddmgiahcphecmpfh", name: "uBlock Origin Lite",
                             category: "Ad blocking & privacy", iconDomain: "ublockorigin.com",
                             blurb: "Efficient, open-source content blocker. Blocks ads and trackers with low overhead.",
                             openSource: true),
        RecommendedExtension(id: "bgnkhhnnamicmpeenaelnjfhikgbkllg", name: "AdGuard AdBlocker",
                             category: "Ad blocking & privacy", iconDomain: "adguard.com",
                             blurb: "Blocks ads, pop-ups, and trackers across the web with rich filtering.",
                             openSource: true),
        RecommendedExtension(id: "pkehgijcmpdhfbdbbnkijodmdjhbjlgp", name: "Privacy Badger",
                             category: "Ad blocking & privacy", iconDomain: "eff.org",
                             blurb: "The EFF's open-source tracker blocker. Learns and stops hidden trackers.",
                             openSource: true),
        RecommendedExtension(id: "lckanjgmijmafbedllaakclkaicjfmnk", name: "ClearURLs",
                             category: "Ad blocking & privacy", iconDomain: "clearurls.xyz",
                             blurb: "Open-source. Strips tracking parameters from links automatically.",
                             openSource: true),
        RecommendedExtension(id: "mnjggcdmjocbbbhaepdhchncahnbgone", name: "SponsorBlock",
                             category: "Ad blocking & privacy", iconDomain: "sponsor.ajay.app",
                             blurb: "Open-source. Skips sponsored segments in YouTube videos automatically.",
                             openSource: true),
        // Productivity
        RecommendedExtension(id: "nngceckbapebfimnlniiiahkandclblb", name: "Bitwarden",
                             category: "Productivity", iconDomain: "bitwarden.com",
                             blurb: "Open-source password manager. Autofill logins securely across sites.",
                             openSource: true),
        RecommendedExtension(id: "aapbdbdomjkkjkaonfhkkikfgjllcleb", name: "Google Translate",
                             category: "Productivity", iconDomain: "translate.google.com",
                             blurb: "Translate selected text or a whole page in a click.",
                             openSource: false),
        RecommendedExtension(id: "kbfnbcaeplbcioakkpcpgfkobkghlhen", name: "Grammarly",
                             category: "Productivity", iconDomain: "grammarly.com",
                             blurb: "Spelling and grammar checking as you type, in any text field.",
                             openSource: false),
        RecommendedExtension(id: "gppongmhjkpfnbhagpmjfkannfbllamg", name: "Wappalyzer",
                             category: "Productivity", iconDomain: "wappalyzer.com",
                             blurb: "Reveals the technologies, frameworks, and tools a website is built with.",
                             openSource: false),
        RecommendedExtension(id: "chphlpgkkbolifaimnlloiipkdnihall", name: "OneTab",
                             category: "Productivity", iconDomain: "one-tab.com",
                             blurb: "Collapse all your tabs into one list to save memory and clear clutter.",
                             openSource: false),
        RecommendedExtension(id: "khncfooichmfjbepaaaebmommgaepoid", name: "Unhook",
                             category: "Productivity", iconDomain: "unhook.app",
                             blurb: "Open-source. Hide the YouTube feed, Shorts, comments, and recommendations to stay focused.",
                             openSource: true),
        RecommendedExtension(id: "dneaehbmnbhcippjikoajpoabadpodje", name: "Old Reddit Redirect",
                             category: "Productivity", iconDomain: "github.com",
                             blurb: "Open-source. Always sends reddit.com to the cleaner, faster old.reddit.com layout.",
                             openSource: true),
        RecommendedExtension(id: "oldceeleldhonbafppcapldpdifcinji", name: "LanguageTool",
                             category: "Productivity", iconDomain: "languagetool.org",
                             blurb: "Open-source. Multilingual grammar, spelling, and style checking in any text field.",
                             openSource: true),
        // Media
        RecommendedExtension(id: "nffaoalbilbmmfgbnbgppjihopabppdk", name: "Video Speed Controller",
                             category: "Media", iconDomain: "github.com",
                             blurb: "Open-source. Speed up, slow down, and step through any HTML5 video.",
                             openSource: true),
        RecommendedExtension(id: "ponfpcnoihfmfllpaingbgckeeldkhle", name: "Enhancer for YouTube",
                             category: "Media", iconDomain: "mrfdev.com",
                             blurb: "Cinema mode, custom speed, volume control, and ad controls for YouTube.",
                             openSource: false),
        RecommendedExtension(id: "lpcaedmchfhocbbapmcbpinfpgnhiddi", name: "Google Keep",
                             category: "Media", iconDomain: "keep.google.com",
                             blurb: "Save pages, images, and quotes to Keep notes as you browse.",
                             openSource: false),
        RecommendedExtension(id: "gebbhagfogifgggkldgodflihgfeippi", name: "Return YouTube Dislike",
                             category: "Media", iconDomain: "returnyoutubedislike.com",
                             blurb: "Open-source. Brings the dislike count back to YouTube using crowd estimates.",
                             openSource: true),
        RecommendedExtension(id: "enamippconapkdmgfgjchkhakpfinmaj", name: "DeArrow",
                             category: "Media", iconDomain: "dearrow.ajay.app",
                             blurb: "Open-source, by SponsorBlock's maker. Replaces clickbait titles and thumbnails on YouTube.",
                             openSource: true),
        // Appearance
        RecommendedExtension(id: "eimadpbcbfnmbkopoojfekhnkhdbieeh", name: "Dark Reader",
                             category: "Appearance", iconDomain: "darkreader.org",
                             blurb: "Open-source dark mode for every website, with per-site controls.",
                             openSource: true),
        RecommendedExtension(id: "laookkfknpbbblfpciffpaejjkokdgca", name: "Momentum",
                             category: "Appearance", iconDomain: "momentumdash.com",
                             blurb: "A calm, beautiful new-tab dashboard with photos, focus, and to-dos.",
                             openSource: false)
    ]

}
