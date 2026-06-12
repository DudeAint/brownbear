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
        .task {
            await model.load()
            await model.checkForScriptUpdates(auto: true)
        }
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

    /// The compact header shown on an empty Scripts tab, above the recommended userscripts: a glyph, a
    /// one-line explainer, and the explicit "Add a script" affordance (the toolbar "+" also adds one).
    private var emptyScriptsIntro: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(BBTheme.Color.accent.opacity(0.7))
            Text("No userscripts yet").font(.headline).foregroundStyle(BBTheme.Color.textPrimary)
            Text("Install a recommended script below, or add your own from the + button.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(BBTheme.Color.textSecondary)
            Button { addingScript = true } label: {
                Text("Add a script").fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .tint(BBTheme.Color.accent)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    private var scriptsTab: some View {
        NavigationStack {
            Group {
                if model.scripts.isEmpty {
                    // No scripts yet: a compact get-started hint, then the curated userscripts to install
                    // in a tap — so the empty Scripts tab is a starting point, not a dead end.
                    List {
                        Section {
                            emptyScriptsIntro
                        }
                        .listRowBackground(Color.clear)
                        RecommendedScriptsSections()
                    }
                    .scrollContentBackground(.hidden)
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
                        // The curated userscripts live with the userscripts (not the Extensions tab); hide
                        // them while searching so a query only narrows the installed list.
                        if model.scriptSearch.isEmpty {
                            RecommendedScriptsSections(installedNames: model.scripts.map(\.displayName))
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
                        Divider()
                        Button {
                            Task { await model.checkForScriptUpdates(auto: false) }
                        } label: { Label("Check for updates", systemImage: "arrow.triangle.2.circlepath") }
                            .disabled(model.isCheckingUpdates)
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .alert("Script updates", isPresented: Binding(
                get: { model.updateMessage != nil },
                set: { if !$0 { model.updateMessage = nil } }
            )) {
                Button("OK") { model.updateMessage = nil }
            } message: {
                Text(model.updateMessage ?? "")
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
