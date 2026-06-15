//
//  ProxyView.swift
//  BrownBear
//
//  The Proxy settings screen (Settings → Proxy). One active proxy at a time, no per-tab profiles: paste a
//  proxy in ANY format (it auto-fills the fields) or fill them by hand, check it, save it, and toggle it on
//  — when on, all browsing routes through it (iOS 17+). A saved list keeps and switches connections.
//  Mirrors the app's Settings aesthetic.
//

import SwiftUI

struct ProxyView: View {

    @ObservedObject private var manager = ProxyManager.shared

    // The smart paste inbox: drop any format here and it fills the fields below.
    @State private var proxyText: String = ""
    // The editable proxy fields — the source of truth for Check / Save / Change IP.
    @State private var kind: BBProxy.Kind = .socks5
    @State private var host: String = ""
    @State private var portText: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
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

            Section("Add a proxy") {
                TextField("Paste any format — we'll fill it in", text: $proxyText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                    .onChange(of: proxyText) { _ in autofillFromPaste() }
                Text("Paste host:port:user:pass, user:pass@host:port, a full URL, or a space-separated line "
                    + "— any common format is detected and split into the fields below.")
                    .font(.caption)
                    .foregroundStyle(BBTheme.Color.textSecondary)
            }

            Section("Proxy details") {
                Picker("Type", selection: $kind) {
                    ForEach(BBProxy.Kind.allCases) { Text($0.title).tag($0) }
                }
                TextField("Host", text: $host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Port", text: $portText)
                    .keyboardType(.numberPad)
                TextField("Username (optional)", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password (optional)", text: $password)
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

    // MARK: - Bindings + derived state

    private var enabledBinding: Binding<Bool> {
        Binding(get: { manager.enabled }, set: { manager.setEnabled($0) })
    }

    /// The Port field as a valid 1...65535 number, or nil.
    private var portValue: Int? {
        let trimmed = portText.trimmingCharacters(in: .whitespaces)
        guard let value = Int(trimmed), (1...65_535).contains(value) else { return nil }
        return value
    }

    /// Whether the fields describe a complete-enough proxy to check or save.
    private var formParses: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty && portValue != nil
    }

    /// A probe (check or rotate) is in flight — disable the action buttons.
    private var busy: Bool { checking || rotating }

    /// A rotation endpoint has been entered, so the "Change IP" action is meaningful.
    private var hasChangeIPURL: Bool { !changeIPText.trimmingCharacters(in: .whitespaces).isEmpty }

    // MARK: - Actions

    /// Parse whatever was pasted and distribute it into the structured fields. Leaves the fields untouched
    /// while the paste box holds something not-yet-parseable, so partial typing never wipes good input.
    private func autofillFromPaste() {
        let trimmed = proxyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let parsed = BBProxy.parse(trimmed, fallbackKind: kind) else { return }
        kind = parsed.kind
        host = parsed.host
        portText = String(parsed.port)
        username = parsed.username
        password = parsed.password
    }

    /// Load the currently-active proxy into the form, so the screen opens showing what's in effect.
    private func loadActiveIntoForm() {
        guard editingID == nil, let active = manager.active else { return }
        fill(from: active)
    }

    private func fill(from proxy: BBProxy) {
        editingID = proxy.id
        kind = proxy.kind
        host = proxy.host
        portText = String(proxy.port)
        username = proxy.username
        password = proxy.password
        changeIPText = proxy.changeIPURL
        label = proxy.label
        proxyText = ""                           // the paste box is just an inbox; the fields now hold it
    }

    private func selectSaved(_ proxy: BBProxy) {
        fill(from: proxy)
        manager.setActive(proxy.id, enabled: true)
        checkMessage = nil
    }

    /// Build a BBProxy from the structured fields (preserving the edited id so a re-save updates in place).
    private func formProxy() -> BBProxy? {
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))   // tolerate a pasted [ipv6] literal
        guard !trimmedHost.isEmpty, let port = portValue else { return nil }
        var proxy = BBProxy(kind: kind, host: trimmedHost, port: port,
                            username: username.trimmingCharacters(in: .whitespaces), password: password)
        if let editingID { proxy.id = editingID }
        proxy.label = label
        proxy.changeIPURL = changeIPText.trimmingCharacters(in: .whitespaces)
        return proxy
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
    private func apply(_ result: ProxyCheckOutcome, successPrefix: String) {
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
