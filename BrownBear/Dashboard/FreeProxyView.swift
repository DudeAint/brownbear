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

    @State private var all: [FreeProxy] = []             // raw merged candidates (fallback + per-country counts)
    @State private var verified: [VerifiedProxy] = []    // liveness-checked, streamed in, sorted by latency
    @State private var countries: [FreeProxyCountry] = []
    @State private var selectedCountry: String?          // nil = All
    @State private var loading = false                   // fetching the candidate lists
    @State private var verifying = false                 // liveness sweep in flight
    @State private var loadError: String?
    @State private var pendingActivation: FreeProxy?     // non-nil drives the confirm alert
    @State private var didActivate = false
    @State private var verifyTask: Task<Void, Never>?    // the streaming verifier, cancelled on reload/dismiss
    @State private var verifyDidComplete = false         // the sweep ran to completion (drives the fallback note)

    /// The hard caution shown at the top and repeated in the activation confirm.
    private static let warning =
        "Free public proxies are run by strangers. Anything you send through one can be read, logged, or "
        + "changed by whoever runs it, and it can break HTTPS security. Never sign in, enter passwords, or "
        + "send payment or personal details while a free proxy is on. These servers are unvetted, often "
        + "offline, and may be malicious. BrownBear neither controls nor endorses any proxy listed here — "
        + "use it only for low-risk browsing, and prefer a trusted VPN for real privacy."

    /// On iOS 17+ we show only liveness-VERIFIED proxies (so the user never picks a dead one); we fall back
    /// to the raw merged list when proxy support is missing, or when the sweep finished having confirmed
    /// none (an unchecked list beats a blank screen). While the sweep is still running we stay in verified
    /// mode so the "Checking…" progress shows instead of flashing the raw list.
    private var usingVerified: Bool {
        guard ProxyManager.isSupported else { return false }
        return !verified.isEmpty || verifying
    }

    private var visibleVerified: [VerifiedProxy] {
        guard let code = selectedCountry, !code.isEmpty else { return verified }
        return verified.filter { $0.proxy.groupingCode == code }
    }

    private var visibleRaw: [FreeProxy] { FreeProxyService.filter(all, countryCode: selectedCountry) }

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
                proxyListContent
            } header: {
                Text(proxyListHeader)
            } footer: {
                proxyListFooter
            }
        }
        .scrollContentBackground(.hidden)
        .background(BBTheme.backgroundGradient)
        .tint(BBTheme.Color.accent)
        .navigationTitle("Free Proxies")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await reload(force: true) }
        .task { if all.isEmpty { await reload(force: false) } }
        .onDisappear { verifyTask?.cancel() }
        .alert("Use this free proxy?", isPresented: activationBinding, presenting: pendingActivation) { proxy in
            Button("Activate", role: .destructive) { activate(proxy) }
            Button("Cancel", role: .cancel) { }
        } message: { proxy in
            Text("\(proxy.flag) \(proxy.hostPort) · \(proxy.kind.title)\n\n" + Self.warning)
        }
    }

    /// The proxy rows (or the loading / progress / empty states), branching between the liveness-verified
    /// list and the raw fallback. Kept out of `body` so each state reads clearly.
    @ViewBuilder
    private var proxyListContent: some View {
        if loading && all.isEmpty {
            HStack {
                ProgressView()
                Text("Loading free proxies…").foregroundStyle(BBTheme.Color.textSecondary)
            }
        } else if let loadError, all.isEmpty {
            Label(loadError, systemImage: "wifi.exclamationmark")
                .font(.caption).foregroundStyle(BBTheme.Color.destructive)
        } else if usingVerified {
            if visibleVerified.isEmpty {
                HStack(spacing: 8) {
                    if verifying { ProgressView() }
                    Text(verifying ? "Checking proxies…" : "No working proxies for this filter.")
                        .foregroundStyle(BBTheme.Color.textSecondary)
                }
            } else {
                ForEach(visibleVerified) { item in
                    Button { pendingActivation = item.proxy } label: { row(item.proxy, latencyMs: item.latencyMs) }
                        .disabled(!ProxyManager.isSupported)
                }
            }
        } else if visibleRaw.isEmpty {
            Text("No proxies for this filter. Pull to refresh.")
                .foregroundStyle(BBTheme.Color.textSecondary)
        } else {
            ForEach(visibleRaw) { proxy in
                Button { pendingActivation = proxy } label: { row(proxy, latencyMs: nil) }
                    .disabled(!ProxyManager.isSupported)
            }
        }
    }

    private var proxyListHeader: String {
        if usingVerified {
            if verifying { return "Checking proxies… (\(verified.count) live)" }
            return visibleVerified.isEmpty ? "Proxies" : "Working proxies (\(visibleVerified.count)) · tap to use"
        }
        return visibleRaw.isEmpty ? "Proxies" : "Proxies (\(visibleRaw.count))"
    }

    @ViewBuilder
    private var proxyListFooter: some View {
        if didActivate {
            Text("Proxy activated. Reload your open pages to route them through it.")
                .foregroundStyle(BBTheme.Color.secure)
        } else if verifying {
            Text("Testing each proxy by connecting through it — only ones that respond are shown, fastest first.")
                .foregroundStyle(BBTheme.Color.textSecondary)
        } else if verifyDidComplete && verified.isEmpty && !visibleRaw.isEmpty {
            Text("Couldn't confirm any of these as working right now — they're shown unchecked. "
                + "Pull to refresh to test again.")
                .foregroundStyle(BBTheme.Color.textSecondary)
        }
    }

    @ViewBuilder
    private func row(_ proxy: FreeProxy, latencyMs: Int?) -> some View {
        HStack(spacing: 10) {
            Text(proxy.flag)
            VStack(alignment: .leading, spacing: 2) {
                Text(proxy.hostPort).foregroundStyle(BBTheme.Color.textPrimary)
                HStack(spacing: 6) {
                    Text("\(proxy.kind.title) · \(proxy.countryLabel)")
                        .font(.caption).foregroundStyle(BBTheme.Color.textSecondary)
                    if let latencyMs {
                        Label("\(latencyMs) ms", systemImage: "bolt.fill")
                            .font(.caption2).labelStyle(.titleAndIcon)
                            .foregroundStyle(Self.latencyColor(latencyMs))
                    }
                }
            }
            Spacer()
            if manager.enabled, let active = manager.active,
               active.host == proxy.host, active.port == proxy.port, active.kind == proxy.kind {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(BBTheme.Color.secure)
            }
        }
    }

    /// Green for a snappy proxy, the accent for usable, muted for sluggish — an at-a-glance quality cue.
    private static func latencyColor(_ ms: Int) -> Color {
        if ms < 600 { return BBTheme.Color.secure }
        if ms < 1500 { return BBTheme.Color.accent }
        return BBTheme.Color.textSecondary
    }

    // MARK: - Actions

    private var activationBinding: Binding<Bool> {
        Binding(get: { pendingActivation != nil }, set: { if !$0 { pendingActivation = nil } })
    }

    private func reload(force: Bool) async {
        verifyTask?.cancel()
        verifyTask = nil
        verifying = false
        verifyDidComplete = false
        verified = []
        loading = true
        loadError = nil
        do {
            let list = try await FreeProxyService.shared.load(forceRefresh: force)
            all = list
            countries = FreeProxyService.countries(in: list)
            if let selectedCountry, !countries.contains(where: { $0.code == selectedCountry }) {
                self.selectedCountry = nil       // the filtered country vanished from the refreshed list
            }
            loading = false
            startVerification(list)
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            loading = false
        }
    }

    /// Kick off the streaming liveness check: probe candidates in the background and append each proxy that
    /// answers (fastest first), so the list fills in with confirmed-working proxies. iOS 17+ only — on older
    /// systems there's no proxy API to test through, so we leave the raw list as-is.
    private func startVerification(_ candidates: [FreeProxy]) {
        guard ProxyManager.isSupported, !candidates.isEmpty else { return }
        verifying = true
        // `@MainActor` so the streamed results land on the main thread — the consumer mutates @State on
        // every yield, so it must stay main-isolated regardless of where this method was invoked from.
        verifyTask = Task { @MainActor in
            for await (proxy, latencyMs) in FreeProxyService.verifiedStream(candidates) {
                if Task.isCancelled { break }
                guard !verified.contains(where: { $0.id == proxy.id }) else { continue }
                verified.append(VerifiedProxy(proxy: proxy, latencyMs: latencyMs))
                verified.sort { $0.latencyMs < $1.latencyMs }
            }
            verifying = false
            verifyDidComplete = true
        }
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

/// A free proxy that just passed a live connectivity probe, paired with its measured round-trip latency
/// (ms). `id` is the proxy's host:port so SwiftUI can diff the streamed-in list stably.
private struct VerifiedProxy: Identifiable {
    let proxy: FreeProxy
    let latencyMs: Int
    var id: String { proxy.id }
}
