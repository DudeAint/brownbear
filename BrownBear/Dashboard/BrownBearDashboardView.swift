//
//  BrownBearDashboardView.swift
//  BrownBear
//
//  The userscript manager dashboard: three tabs — Scripts (install, toggle, edit), Logs, and
//  Background. Presented over the browser; `onClose` dismisses the hosting controller.
//

import SwiftUI
import UIKit

struct BrownBearDashboardView: View {

    /// The selectable dashboard sections, so callers can deep-link to a specific tab.
    enum DashboardTab: Hashable { case scripts, logs, background, extensions, settings }

    private let onClose: () -> Void

    @StateObject private var model = DashboardViewModel()
    @State private var selection: DashboardTab
    @State private var addingScript = false
    @State private var urlPrompt = false
    @State private var urlText = ""

    init(initialTab: DashboardTab = .scripts, onClose: @escaping () -> Void = {}) {
        self._selection = State(initialValue: initialTab)
        self.onClose = onClose
    }

    var body: some View {
        TabView(selection: $selection) {
            scriptsTab
                .tabItem { Label("Scripts", systemImage: "doc.text.fill") }
                .tag(DashboardTab.scripts)
            NavigationStack { LogsView(model: model).toolbar { dashboardDone() } }
                .tabItem { Label("Logs", systemImage: "list.bullet.rectangle.fill") }
                .tag(DashboardTab.logs)
            NavigationStack { BackgroundMonitorView(model: model).toolbar { dashboardDone() } }
                .tabItem { Label("Background", systemImage: "clock.arrow.circlepath") }
                .tag(DashboardTab.background)
            NavigationStack { ExtensionsView().toolbar { dashboardDone() } }
                .tabItem { Label("Extensions", systemImage: "puzzlepiece.extension.fill") }
                .tag(DashboardTab.extensions)
            NavigationStack { SettingsView().toolbar { dashboardDone() } }
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(DashboardTab.settings)
        }
        .tint(BBTheme.Color.accent)
        .task { await model.load() }
        .sheet(isPresented: $addingScript) {
            ScriptEditorScreen(model: model, existing: nil)
        }
    }

    /// A Done button placed on every dashboard tab so the user can dismiss from any of them
    /// (previously only the Scripts tab had it, so Logs/Background/Extensions felt like dead ends).
    @ToolbarContentBuilder
    private func dashboardDone() -> some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button("Done", action: onClose).fontWeight(.semibold)
        }
    }

    // MARK: - Scripts tab

    private var scriptsTab: some View {
        NavigationStack {
            Group {
                if model.scripts.isEmpty {
                    DashboardEmptyState(
                        systemImage: "doc.text.magnifyingglass",
                        title: "No userscripts yet",
                        message: "Install a script to customize any site, or write a background script that runs on a schedule.",
                        action: { addingScript = true },
                        actionTitle: "Add a script"
                    )
                } else {
                    List {
                        Section {
                            ForEach(model.filteredScripts) { script in
                                NavigationLink {
                                    ScriptDetailView(script: script, model: model)
                                } label: {
                                    ScriptRowView(script: script, model: model)
                                }
                                .listRowBackground(BBTheme.Color.card)
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        Task { await model.delete(script) }
                                    } label: { Label("Delete", systemImage: "trash") }
                                }
                                .contextMenu {
                                    Button {
                                        Task { await model.setEnabled(script, !script.enabled) }
                                    } label: {
                                        Label(script.enabled ? "Disable" : "Enable",
                                              systemImage: script.enabled ? "pause.circle" : "play.circle")
                                    }
                                    Button(role: .destructive) {
                                        Task { await model.delete(script) }
                                    } label: { Label("Delete", systemImage: "trash") }
                                }
                            }
                        } header: {
                            Text("\(model.scripts.count) installed · \(model.enabledCount) enabled")
                                .foregroundStyle(BBTheme.Color.textSecondary)
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .searchable(text: $model.scriptSearch, prompt: "Search scripts")
                    .overlay {
                        if model.filteredScripts.isEmpty {
                            DashboardEmptyState(
                                systemImage: "magnifyingglass",
                                title: "No matches",
                                message: "No installed script matches “\(model.scriptSearch)”.")
                        }
                    }
                }
            }
            .background(BBTheme.backgroundGradient)
            .navigationTitle("Userscripts")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done", action: onClose).fontWeight(.semibold)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button { addingScript = true } label: { Label("New script", systemImage: "plus") }
                        Button { urlPrompt = true } label: { Label("Import from URL…", systemImage: "link") }
                        Button { importFromClipboard() } label: { Label("Import from clipboard", systemImage: "doc.on.clipboard") }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .alert("Couldn’t install", isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )) {
                Button("OK") { model.errorMessage = nil }
            } message: {
                Text(model.errorMessage ?? "")
            }
            .alert("Import from URL", isPresented: $urlPrompt) {
                TextField("https://example.com/script.user.js", text: $urlText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button("Import") { beginURLImport() }
                Button("Cancel", role: .cancel) { urlText = "" }
            } message: {
                Text("Paste a link to a userscript (a .user.js file). You'll see what it does before installing.")
            }
        }
    }

    private func beginURLImport() {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        urlText = ""
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            model.errorMessage = "That doesn't look like a valid http(s) URL."
            return
        }
        // Present the programmatic-UIKit install card; reload the list when it finishes.
        let installer = ScriptInstallViewController(url: url, onFinished: { Task { @MainActor in await model.load() } })
        TopViewControllerPresenter.present(installer.wrappedForPresentation())
    }

    private func importFromClipboard() {
        guard let pasted = UIPasteboard.general.string, !pasted.isEmpty else {
            model.errorMessage = "The clipboard is empty."
            return
        }
        Task { await model.install(source: pasted) }
    }
}

// MARK: - UIKit presentation

extension BrownBearDashboardView {
    /// Wrap the dashboard in a hosting controller wired to dismiss itself.
    static func makeHostingController(initialTab: DashboardTab = .scripts) -> UIViewController {
        var hosting: UIHostingController<BrownBearDashboardView>?
        let view = BrownBearDashboardView(initialTab: initialTab, onClose: { hosting?.dismiss(animated: true) })
        let controller = UIHostingController(rootView: view)
        controller.modalPresentationStyle = .fullScreen
        hosting = controller
        return controller
    }
}
