//
//  FreeProxyView.swift
//  BrownBear
//
//  "Browse free proxies" (Settings → Proxy → Browse free proxies). Loads a public free-proxy list
//  (FreeProxyService), lets the user filter by country and tap one to activate it — behind a hard security
//  warning and an explicit confirmation, because free public proxies are run by strangers and can read,
//  log, or tamper with anything not end-to-end encrypted. Activating one promotes it to a saved BBProxy in
//  ProxyManager and turns the proxy on. iOS 17+ only (the underlying proxy API).
//

import SwiftUI

struct FreeProxyView: View {

    @ObservedObject private var manager = ProxyManager.shared

    @State private var all: [FreeProxy] = []
    @State private var countries: [FreeProxyCountry] = []
    @State private var selectedCountry: String?          // nil = All
    @State private var loading = false
    @State private var loadError: String?
    @State private var pendingActivation: FreeProxy?     // non-nil drives the confirm alert
    @State private var didActivate = false

    /// The hard caution shown at the top and repeated in the activation confirm.
    private static let warning =
        "Free public proxies are run by strangers. Anything you send through one can be read, logged, or "
        + "changed by whoever runs it, and it can break HTTPS security. Never sign in, enter passwords, or "
        + "send payment or personal details while a free proxy is on. These servers are unvetted, often "
        + "offline, and may be malicious. BrownBear neither controls nor endorses any proxy listed here — "
        + "use it only for low-risk browsing, and prefer a trusted VPN for real privacy."

    private var visible: [FreeProxy] { FreeProxyService.filter(all, countryCode: selectedCountry) }

    var body: some View {
        Form {
            Section {
                Label {
                    Text(Self.warning)
                } icon: {
                    Image(systemName: "exclamationmark.shield.fill").foregroundStyle(BBTheme.Color.destructive)
                }
                .font(.caption)
                .foregroundStyle(BBTheme.Color.textSecondary)
            }

            if !ProxyManager.isSupported {
                Section {
                    Label("Proxies require iOS 17 or later.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(BBTheme.Color.textSecondary)
                }
            }

            if !countries.isEmpty {
                Section("Country") {
                    Picker("Country", selection: $selectedCountry) {
                        Text("All (\(all.count))").tag(String?.none)
                        ForEach(countries, id: \.code) { country in
                            Text("\(country.flag) \(country.name) (\(country.count))")
                                .tag(Optional(country.code))
                        }
                    }
                }
            }

            Section {
                if loading && all.isEmpty {
                    HStack {
                        ProgressView()
                        Text("Loading free proxies…").foregroundStyle(BBTheme.Color.textSecondary)
                    }
                } else if let loadError, all.isEmpty {
                    Label(loadError, systemImage: "wifi.exclamationmark")
                        .font(.caption).foregroundStyle(BBTheme.Color.destructive)
                } else if visible.isEmpty {
                    Text("No proxies for this filter. Pull to refresh.")
                        .foregroundStyle(BBTheme.Color.textSecondary)
                } else {
                    ForEach(visible) { proxy in
                        Button { pendingActivation = proxy } label: { row(proxy) }
                            .disabled(!ProxyManager.isSupported)
                    }
                }
            } header: {
                Text(visible.isEmpty ? "Proxies" : "Proxies (\(visible.count)) · tap to use")
            } footer: {
                if didActivate {
                    Text("Proxy activated. Reload your open pages to route them through it.")
                        .foregroundStyle(BBTheme.Color.secure)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(BBTheme.backgroundGradient)
        .tint(BBTheme.Color.accent)
        .navigationTitle("Free Proxies")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await reload(force: true) }
        .task { if all.isEmpty { await reload(force: false) } }
        .alert("Use this free proxy?", isPresented: activationBinding, presenting: pendingActivation) { proxy in
            Button("Activate", role: .destructive) { activate(proxy) }
            Button("Cancel", role: .cancel) { }
        } message: { proxy in
            Text("\(proxy.flag) \(proxy.hostPort) · \(proxy.kind.title)\n\n" + Self.warning)
        }
    }

    @ViewBuilder
    private func row(_ proxy: FreeProxy) -> some View {
        HStack(spacing: 10) {
            Text(proxy.flag)
            VStack(alignment: .leading, spacing: 2) {
                Text(proxy.hostPort).foregroundStyle(BBTheme.Color.textPrimary)
                Text("\(proxy.kind.title) · \(proxy.countryLabel)")
                    .font(.caption).foregroundStyle(BBTheme.Color.textSecondary)
            }
            Spacer()
            if manager.enabled, let active = manager.active,
               active.host == proxy.host, active.port == proxy.port, active.kind == proxy.kind {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(BBTheme.Color.secure)
            }
        }
    }

    // MARK: - Actions

    private var activationBinding: Binding<Bool> {
        Binding(get: { pendingActivation != nil }, set: { if !$0 { pendingActivation = nil } })
    }

    private func reload(force: Bool) async {
        loading = true
        loadError = nil
        do {
            let list = try await FreeProxyService.shared.load(forceRefresh: force)
            all = list
            countries = FreeProxyService.countries(in: list)
            if let selectedCountry, !countries.contains(where: { $0.code == selectedCountry }) {
                self.selectedCountry = nil       // the filtered country vanished from the refreshed list
            }
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        loading = false
    }

    private func activate(_ proxy: FreeProxy) {
        guard ProxyManager.isSupported else { return }
        let label = "Free · \(proxy.countryCode ?? proxy.host)"
        var bbProxy = proxy.asBBProxy(label: label)
        // Re-activating the same free proxy must be idempotent: reuse an existing identical (host/port/kind,
        // credential-free) saved entry's id so we update it in place instead of appending a duplicate.
        if let existing = manager.saved.first(where: {
            $0.host == proxy.host && $0.port == proxy.port && $0.kind == proxy.kind && !$0.hasCredentials
        }) {
            bbProxy.id = existing.id
        }
        let stored = manager.upsert(bbProxy)
        manager.setActive(stored.id, enabled: true)
        pendingActivation = nil
        didActivate = true
    }
}
