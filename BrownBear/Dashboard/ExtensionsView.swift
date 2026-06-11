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
    }

    private func recommendedRow(_ rec: RecommendedExtension) -> some View {
        HStack(spacing: 12) {
            Text(rec.emoji)
                .font(.title2)
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
            .labelsHidden().tint(BBTheme.Color.accent)
        }
        .padding(.vertical, 4)
        .swipeActions {
            Button(role: .destructive) { Task { await model.remove(ext) } } label: {
                Label("Remove", systemImage: "trash")
            }
        }
        .contextMenu { pageActions(for: ext) }
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
/// id, which the existing `installFromStore` flow accepts directly.
struct RecommendedExtension: Identifiable {
    let id: String
    let name: String
    let category: String
    let emoji: String
    let blurb: String
    let openSource: Bool
}

extension ExtensionsView {
    /// Category display order for the recommended sections (small, non-intrusive labels).
    static let recommendedCategories = ["Userscripts", "Ad blocking", "Appearance"]

    /// The curated set. Store ids should be device-verified; an install that fails surfaces the normal
    /// error alert, so a stale id is non-fatal. (ScriptCat / uBO-full can be added once their store
    /// ids are confirmed, or installed via the "From a web store…" option.)
    static let recommended: [RecommendedExtension] = [
        RecommendedExtension(id: "dhdgffkkebhmkfjojejmpbldmpobfkfo", name: "Tampermonkey",
                             category: "Userscripts", emoji: "🐵",
                             blurb: "The most popular userscript manager — run scripts that customize any site.",
                             openSource: false),
        RecommendedExtension(id: "jinjaccalgkegednnccohejagnlnfdag", name: "Violentmonkey",
                             category: "Userscripts", emoji: "🐒",
                             blurb: "Open-source userscript manager with a clean, privacy-minded design.",
                             openSource: true),
        RecommendedExtension(id: "ddkjiahejlhfcafbddmgiahcphecmpfh", name: "uBlock Origin Lite",
                             category: "Ad blocking", emoji: "🛡️",
                             blurb: "Efficient, open-source content blocker — blocks ads and trackers with low overhead.",
                             openSource: true),
        RecommendedExtension(id: "eimadpbcbfnmbkopoojfekhnkhdbieeh", name: "Dark Reader",
                             category: "Appearance", emoji: "🌙",
                             blurb: "Open-source dark mode for every website, with per-site controls.",
                             openSource: true)
    ]
}
