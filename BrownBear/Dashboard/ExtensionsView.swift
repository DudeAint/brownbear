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

    /// Fetch a CRX straight from the Chrome Web Store (link or 32-char id) and install it.
    func installFromStore(_ input: String) async {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isInstalling = true
        defer { isInstalling = false }
        do {
            let data = try await ChromeWebStore.downloadCRX(forInput: trimmed)
            _ = try await store.install(archive: data, storeID: ChromeWebStore.extensionID(from: trimmed))
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
        Group {
            if model.extensions.isEmpty {
                DashboardEmptyState(
                    systemImage: "puzzlepiece.extension.fill",
                    title: "No extensions",
                    message: """
                    Install a Chrome/Firefox-style extension from a .crx/.zip file or straight from \
                    the Chrome Web Store. Content scripts, background workers, and declarativeNetRequest \
                    blocking all run with a chrome.* API surface.
                    """,
                    action: { importing = true },
                    actionTitle: "Install extension"
                )
            } else {
                List {
                    ForEach(model.extensions) { ext in
                        extensionRow(ext)
                            .listRowBackground(BBTheme.Color.card)
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
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
                    Button { storePrompting = true } label: { Label("From Chrome Web Store…", systemImage: "link") }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: allowedTypes) { result in
            handleImport(result)
        }
        .alert("Install from Chrome Web Store", isPresented: $storePrompting) {
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
            Text("Paste a chromewebstore.google.com link or a 32-character extension ID.")
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

    private func extensionRow(_ ext: WebExtension) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "puzzlepiece.extension.fill")
                .foregroundStyle(BBTheme.Color.accent)
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
