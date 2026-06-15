//
//  ProxyView.swift
//  BrownBear
//
//  The Proxy settings screen (Settings → Proxy). One active proxy at a time, no per-tab profiles: enter or
//  paste a proxy, check it, save it, and toggle it on — when on, all browsing routes through it (iOS 17+).
//  A saved list lets you keep and switch between connections. Mirrors the app's Settings aesthetic.
//

import SwiftUI

struct ProxyView: View {

    @ObservedObject private var manager = ProxyManager.shared

    // The editable form (a new proxy, or the loaded saved one).
    @State private var kind: BBProxy.Kind = .socks5
    @State private var proxyText: String = ""        // "user:pass@host:port" or a full URL, pasteable
    @State private var changeIPText: String = ""
    @State private var label: String = ""
    @State private var editingID: UUID?              // the saved proxy being edited, if any

    @State private var checking = false
    @State private var rotating = false
    @State private var checkMessage: String?
    @State private var checkOK = false

    var body: some View {
        Form {
            if !ProxyManager.isSupported {
                Section {
                    Label("Proxies require iOS 17 or later.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(BBTheme.Color.textSecondary)
                }
            }

            Section("Proxy") {
                Toggle("Route browsing through a proxy", isOn: enabledBinding)
                    .tint(BBTheme.Color.toggleOn)
                    .disabled(!ProxyManager.isSupported || manager.active == nil)
                if let active = manager.active, manager.enabled {
                    Label("Active: \(active.displayName) — \(active.kind.title)", systemImage: "network")
                        .font(.caption)
                        .foregroundStyle(BBTheme.Color.textSecondary)
                }
                Text("All normal tabs share one proxy. Turn this off for a direct connection. Private tabs "
                    + "use it too while it's on. Reload open pages after changing.")
                    .font(.caption)
                    .foregroundStyle(BBTheme.Color.textSecondary)
            }

            Section("Proxy details") {
                Picker("Type", selection: $kind) {
                    ForEach(BBProxy.Kind.allCases) { Text($0.title).tag($0) }
                }
                TextField("protocol://login:password@host:port", text: $proxyText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                TextField("URL for IP change (optional)", text: $changeIPText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Label (optional)", text: $label)

                HStack {
                    if hasChangeIPURL {
                        Button { rotate() } label: {
                            HStack { Text("Change IP"); if rotating { ProgressView().padding(.leading, 4) } }
                        }
                        .buttonStyle(.bordered)
                        .disabled(busy || !ProxyManager.isSupported || !formParses)
                    }
                    Button { check() } label: {
                        HStack { Text("Check proxy"); if checking { ProgressView().padding(.leading, 4) } }
                    }
                    .buttonStyle(.bordered)
                    .disabled(busy || !ProxyManager.isSupported || !formParses)
                    Spacer()
                    Button("Save") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!formParses)
                }
                if let checkMessage {
                    Label(checkMessage, systemImage: checkOK ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .font(.caption)
                        .foregroundStyle(checkOK ? BBTheme.Color.secure : BBTheme.Color.destructive)
                }
            }

            if !manager.saved.isEmpty {
                Section("Saved proxies (\(manager.saved.count))") {
                    ForEach(manager.saved) { proxy in
                        Button { selectSaved(proxy) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(proxy.displayName).foregroundStyle(BBTheme.Color.textPrimary)
                                    Text("\(proxy.kind.title) · \(proxy.hostPort)")
                                        .font(.caption).foregroundStyle(BBTheme.Color.textSecondary)
                                }
                                Spacer()
                                if manager.activeID == proxy.id {
                                    Image(systemName: "checkmark").foregroundStyle(BBTheme.Color.accent)
                                }
                            }
                        }
                    }
                    .onDelete { offsets in
                        offsets.map { manager.saved[$0] }.forEach { manager.remove($0) }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(BBTheme.backgroundGradient)
        .tint(BBTheme.Color.accent)
        .navigationTitle("Proxy")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadActiveIntoForm)
    }

    // MARK: - Bindings + actions

    private var enabledBinding: Binding<Bool> {
        Binding(get: { manager.enabled }, set: { manager.setEnabled($0) })
    }

    /// Whether the typed/pasted proxy string is well-formed enough to check or save.
    private var formParses: Bool { BBProxy.parse(proxyText, fallbackKind: kind) != nil }

    /// A probe (check or rotate) is in flight — disable the action buttons.
    private var busy: Bool { checking || rotating }

    /// A rotation endpoint has been entered, so the "Change IP" action is meaningful.
    private var hasChangeIPURL: Bool { !changeIPText.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Load the currently-active proxy into the form, so the screen opens showing what's in effect.
    private func loadActiveIntoForm() {
        guard editingID == nil, let active = manager.active else { return }
        fill(from: active)
    }

    private func fill(from proxy: BBProxy) {
        editingID = proxy.id
        kind = proxy.kind
        proxyText = proxy.hasCredentials
            ? "\(proxy.username):\(proxy.password)@\(proxy.hostPort)" : proxy.hostPort
        changeIPText = proxy.changeIPURL
        label = proxy.label
    }

    private func selectSaved(_ proxy: BBProxy) {
        fill(from: proxy)
        manager.setActive(proxy.id, enabled: true)
        checkMessage = nil
    }

    /// Build a BBProxy from the form (preserving the edited id so a re-save updates in place).
    private func formProxy() -> BBProxy? {
        guard var parsed = BBProxy.parse(proxyText, fallbackKind: kind) else { return nil }
        parsed.kind = kind                       // the picker is authoritative over a bare host:port
        if let editingID { parsed.id = editingID }
        parsed.label = label
        parsed.changeIPURL = changeIPText.trimmingCharacters(in: .whitespaces)
        return parsed
    }

    private func save() {
        guard let proxy = formProxy() else { return }
        manager.upsert(proxy)
        manager.setActive(proxy.id, enabled: true)
        editingID = proxy.id
        checkMessage = "Saved and set as the active proxy."
        checkOK = true
    }

    private func check() {
        guard let proxy = formProxy() else { return }
        checking = true
        checkMessage = nil
        Task {
            let result = await manager.check(proxy)
            checking = false
            apply(result, successPrefix: "Connected")
        }
    }

    private func rotate() {
        guard let proxy = formProxy() else { return }
        rotating = true
        checkMessage = nil
        Task {
            let result = await manager.rotateIP(proxy)
            rotating = false
            apply(result, successPrefix: "New IP")
        }
    }

    /// Render a check/rotate result into the status label.
    private func apply(_ result: Result<ProxyCheckResult, String>, successPrefix: String) {
        switch result {
        case .success(let r):
            checkOK = true
            var parts = ["IP \(r.ip)"]
            if let loc = r.location { parts.append(loc) }
            if let tz = r.timezone { parts.append(tz) }
            checkMessage = successPrefix + " · " + parts.joined(separator: " · ")
        case .failure(let message):
            checkOK = false
            checkMessage = message
        }
    }
}
