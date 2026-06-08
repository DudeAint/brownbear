//
//  SettingsView.swift
//  BrownBear
//
//  The app Settings screen (a dashboard tab). Holds preferences that affect the whole browser —
//  the default search engine and a one-tap clear-browsing-data — backed by UserDefaults via the
//  same keys AppSettings reads, so changes take effect immediately (next omnibox submit / NTP).
//

import SwiftUI
import WebKit

struct SettingsView: View {

    @AppStorage(AppSettings.Key.searchEngine) private var searchEngineRaw = SearchEngine.google.rawValue
    @AppStorage(AppSettings.Key.autoUpdateScripts) private var autoUpdateScripts = true
    @AppStorage(AppSettings.Key.hideBarsOnScroll) private var hideBarsOnScroll = true
    @AppStorage(AppSettings.Key.addressBarPosition) private var addressBarPositionRaw = AddressBarPosition.top.rawValue
    @State private var isClearing = false
    @State private var didClear = false
    @State private var confirmingClear = false

    var body: some View {
        Form {
            Section("Search") {
                Picker("Search engine", selection: $searchEngineRaw) {
                    ForEach(SearchEngine.allCases) { engine in
                        Text(engine.title).tag(engine.rawValue)
                    }
                }
            }

            Section("Appearance") {
                Picker("Address bar", selection: $addressBarPositionRaw) {
                    ForEach(AddressBarPosition.allCases) { pos in
                        Text(pos.title).tag(pos.rawValue)
                    }
                }
                .onChange(of: addressBarPositionRaw) { _ in
                    NotificationCenter.default.post(name: .brownBearChromeLayoutChanged, object: nil)
                }
                Toggle("Hide bar while scrolling", isOn: $hideBarsOnScroll)
                Text("The address bar slides away as you scroll down a page and returns when you scroll up. "
                    + "Set it at the top or, Safari-style, at the bottom (where the toolbar hides with it).")
                    .font(.caption)
                    .foregroundStyle(BBTheme.Color.textSecondary)
            }

            Section("Userscripts") {
                Toggle("Update scripts automatically", isOn: $autoUpdateScripts)
                Text("Checks each script's @updateURL/@downloadURL for a newer @version and reinstalls it.")
                    .font(.caption)
                    .foregroundStyle(BBTheme.Color.textSecondary)
            }

            Section("Privacy") {
                Button(role: .destructive) { confirmingClear = true } label: {
                    HStack {
                        Label("Clear browsing data", systemImage: "trash")
                        Spacer()
                        if isClearing { ProgressView() }
                    }
                }
                .disabled(isClearing)
                if didClear {
                    Text("Cleared cookies, cache, website data, and history.")
                        .font(.caption)
                        .foregroundStyle(BBTheme.Color.textSecondary)
                }
            }

            Section {
                LabeledContent("Version", value: appVersion)
                    .foregroundStyle(BBTheme.Color.textSecondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(BBTheme.backgroundGradient)
        .tint(BBTheme.Color.accent)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Clear browsing data?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { clearBrowsingData() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This clears cookies, cache, website data, and browsing history. Bookmarks and "
                + "downloaded files are kept.")
        }
    }

    private func clearBrowsingData() {
        isClearing = true
        didClear = false
        Task {
            await WKWebsiteDataStore.default().removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                modifiedSince: .distantPast)
            await BrownBearServices.shared.historyStore.clear()
            isClearing = false
            didClear = true
        }
    }

    private var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }
}
