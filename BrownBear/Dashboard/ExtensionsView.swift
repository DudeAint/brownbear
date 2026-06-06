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
    @Published var errorMessage: String?

    private var store: WebExtensionStore { BrownBearServices.shared.webExtensionStore }
    private var storage: WebExtensionStorage { BrownBearServices.shared.webExtensionStorage }

    func load() async { extensions = await store.all() }

    func install(data: Data) async {
        do {
            _ = try await store.install(archive: data)
            await load()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func setEnabled(_ ext: WebExtension, _ enabled: Bool) async {
        await store.setEnabled(id: ext.id, enabled)
        await load()
    }

    func remove(_ ext: WebExtension) async {
        await store.remove(id: ext.id)
        await storage.clearAll(extensionID: ext.id)
        await load()
    }
}

struct ExtensionsView: View {

    @StateObject private var model = ExtensionsViewModel()
    @State private var importing = false

    private var allowedTypes: [UTType] {
        [.zip, UTType(filenameExtension: "crx") ?? .data]
    }

    var body: some View {
        Group {
            if model.extensions.isEmpty {
                DashboardEmptyState(
                    systemImage: "puzzlepiece.extension.fill",
                    title: "No extensions",
                    message: "Install a Chrome/Firefox-style extension (.crx or .zip). Its content scripts run on matching pages with a chrome.* API surface.",
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
        .background(BBTheme.backgroundGradient)
        .navigationTitle("Extensions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { importing = true } label: { Image(systemName: "plus") }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: allowedTypes) { result in
            handleImport(result)
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
                Text("v\(ext.version)  ·  \(ext.manifest?.contentScripts.count ?? 0) content scripts")
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
