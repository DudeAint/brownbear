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

    private let onClose: () -> Void

    @StateObject private var model = DashboardViewModel()
    @State private var addingScript = false

    init(onClose: @escaping () -> Void = {}) {
        self.onClose = onClose
    }

    var body: some View {
        TabView {
            scriptsTab
                .tabItem { Label("Scripts", systemImage: "doc.text.fill") }
            NavigationStack { LogsView(model: model) }
                .tabItem { Label("Logs", systemImage: "list.bullet.rectangle.fill") }
            NavigationStack { BackgroundMonitorView(model: model) }
                .tabItem { Label("Background", systemImage: "clock.arrow.circlepath") }
        }
        .tint(BBTheme.Color.accent)
        .task { await model.load() }
        .sheet(isPresented: $addingScript) {
            ScriptEditorScreen(model: model, existing: nil)
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
                            ForEach(model.scripts) { script in
                                NavigationLink {
                                    ScriptDetailView(script: script, model: model)
                                } label: {
                                    ScriptRowView(script: script, model: model)
                                }
                                .listRowBackground(BBTheme.Color.card)
                            }
                        } header: {
                            Text("\(model.scripts.count) installed · \(model.enabledCount) enabled")
                                .foregroundStyle(BBTheme.Color.textSecondary)
                        }
                    }
                    .scrollContentBackground(.hidden)
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
        }
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
    static func makeHostingController() -> UIViewController {
        var hosting: UIHostingController<BrownBearDashboardView>?
        let view = BrownBearDashboardView(onClose: { hosting?.dismiss(animated: true) })
        let controller = UIHostingController(rootView: view)
        controller.modalPresentationStyle = .fullScreen
        hosting = controller
        return controller
    }
}
