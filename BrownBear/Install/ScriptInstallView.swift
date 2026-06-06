//
//  ScriptInstallView.swift
//  BrownBear
//
//  The userscript install card — the polished, Tampermonkey-style "here's what this script does,
//  tap to install" surface. Shown by the browser when you open a `*.user.js` link and by the
//  dashboard's "Import from URL". It fetches + parses the script, lays out its identity, the sites
//  it runs on, the permissions it asks for, and a source preview, then installs on confirmation.
//

import SwiftUI
import UIKit

/// A URL wrapped for SwiftUI's `.sheet(item:)`, keyed by its string so re-importing the same link
/// re-presents the sheet.
struct IdentifiableURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

@MainActor
final class ScriptInstallViewModel: ObservableObject {

    enum State: Equatable {
        case loading
        case ready(UserScriptInstaller.Preview)
        case installing
        case installed(name: String, wasUpdate: Bool)
        case failed(String)
    }

    @Published private(set) var state: State = .loading

    let url: URL?
    private let presetSource: String?
    private let installer = UserScriptInstaller.shared

    /// Install by fetching a URL.
    init(url: URL) {
        self.url = url
        self.presetSource = nil
    }

    /// Install from source we already have (e.g. the page the user is already viewing).
    init(source: String, url: URL? = nil) {
        self.url = url
        self.presetSource = source
    }

    func load() async {
        state = .loading
        do {
            let preview: UserScriptInstaller.Preview
            if let presetSource {
                preview = try await installer.makePreview(source: presetSource, url: url)
            } else if let url {
                preview = try await installer.preview(url: url)
            } else {
                throw BrownBearError.metadataParseFailed("there's nothing to install")
            }
            state = .ready(preview)
        } catch {
            state = .failed(Self.message(error))
        }
    }

    func install() async {
        guard case .ready(let preview) = state else { return }
        let wasUpdate = preview.isUpdate
        state = .installing
        do {
            let script = try await installer.install(preview)
            state = .installed(name: script.displayName, wasUpdate: wasUpdate)
        } catch {
            state = .failed(Self.message(error))
        }
    }

    private static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

// MARK: - View

struct ScriptInstallView: View {

    @StateObject private var model: ScriptInstallViewModel
    @State private var showSource = false
    private let onClose: () -> Void
    private let onViewSource: ((URL) -> Void)?

    init(url: URL, onClose: @escaping () -> Void, onViewSource: ((URL) -> Void)? = nil) {
        _model = StateObject(wrappedValue: ScriptInstallViewModel(url: url))
        self.onClose = onClose
        self.onViewSource = onViewSource
    }

    init(source: String, url: URL? = nil, onClose: @escaping () -> Void, onViewSource: ((URL) -> Void)? = nil) {
        _model = StateObject(wrappedValue: ScriptInstallViewModel(source: source, url: url))
        self.onClose = onClose
        self.onViewSource = onViewSource
    }

    var body: some View {
        NavigationStack {
            ZStack {
                BBTheme.backgroundGradient
                content
            }
            .navigationTitle("Install Script")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Close", action: onClose).foregroundStyle(BBTheme.Color.textSecondary)
                }
            }
        }
        .task { await model.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            statusView(systemImage: nil, title: "Reading script…", subtitle: model.url?.host)
        case .failed(let message):
            failureView(message)
        case .installed(let name, let wasUpdate):
            successView(name: name, wasUpdate: wasUpdate)
        case .ready(let preview):
            previewScroll(preview, installing: false)
        case .installing:
            // Keep the last preview visible under a spinner if we have it; otherwise a bare spinner.
            ProgressView("Installing…")
                .tint(BBTheme.Color.accent)
                .foregroundStyle(BBTheme.Color.textPrimary)
        }
    }

    // MARK: Ready / preview

    private func previewScroll(_ preview: UserScriptInstaller.Preview, installing: Bool) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    hero(preview)
                    if let description = preview.metadata.descriptionText, !description.isEmpty {
                        Text(description)
                            .font(.subheadline)
                            .foregroundStyle(BBTheme.Color.textSecondary)
                    }
                    statStrip(preview)
                    runsOnCard(preview)
                    permissionsCard(preview)
                    networkCard(preview)
                    bundledCard(preview)
                    sourceCard(preview)
                }
                .padding(16)
                .padding(.bottom, 8)
            }
            actionBar(preview)
        }
    }

    private func hero(_ preview: UserScriptInstaller.Preview) -> some View {
        HStack(spacing: 14) {
            icon(preview)
            VStack(alignment: .leading, spacing: 4) {
                Text(preview.metadata.displayName)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(BBTheme.Color.textPrimary)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    if let version = preview.metadata.version, !version.isEmpty {
                        BBPill("v\(version)", systemImage: "number")
                    }
                    if let author = preview.metadata.author, !author.isEmpty {
                        Label(author, systemImage: "person.fill")
                            .font(.caption).foregroundStyle(BBTheme.Color.textSecondary)
                            .lineLimit(1)
                    }
                }
                if preview.isUpdate {
                    BBPill(updateLabel(preview), systemImage: "arrow.triangle.2.circlepath", tint: BBTheme.Color.secure)
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func icon(_ preview: UserScriptInstaller.Preview) -> some View {
        let side: CGFloat = 56
        if let iconURL = preview.metadata.iconURL.flatMap(URL.init(string:)),
           let scheme = iconURL.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            AsyncImage(url: iconURL) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    brandIcon
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            brandIcon.frame(width: side, height: side)
        }
    }

    private var brandIcon: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(LinearGradient(colors: [BBTheme.Color.accent, BBTheme.Color.brandBrown],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(Image(systemName: "scroll.fill").font(.title2).foregroundStyle(.white))
    }

    private func statStrip(_ preview: UserScriptInstaller.Preview) -> some View {
        HStack(spacing: 10) {
            stat(value: "\(preview.lineCount)", label: "lines")
            stat(value: byteString(preview.byteCount), label: "size")
            stat(value: runAtLabel(preview.metadata.runAt), label: "runs at")
        }
    }

    private func stat(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.subheadline.weight(.bold)).foregroundStyle(BBTheme.Color.textPrimary)
            Text(label).font(.caption2).foregroundStyle(BBTheme.Color.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(BBTheme.Color.card)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func runsOnCard(_ preview: UserScriptInstaller.Preview) -> some View {
        let patterns = preview.metadata.matches + preview.metadata.includes
        return section(title: "Runs on", systemImage: "globe") {
            if preview.runsOnNoPages {
                Label("No @match — this script won't run on any page until you add one.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(BBTheme.Color.destructive)
            } else if patterns.isEmpty && preview.metadata.runsInBackground {
                Label("Runs in the background (schedule/@background), not on pages.",
                      systemImage: "clock.arrow.circlepath")
                    .font(.caption).foregroundStyle(BBTheme.Color.textSecondary)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(patterns, id: \.self) { pattern in
                        BBPill(pattern, tint: BBTheme.Color.accent)
                    }
                }
                if !preview.metadata.excludes.isEmpty || !preview.metadata.excludeMatches.isEmpty {
                    Text("Excludes \(preview.metadata.excludes.count + preview.metadata.excludeMatches.count) pattern(s)")
                        .font(.caption2).foregroundStyle(BBTheme.Color.textSecondary)
                }
            }
        }
    }

    private func permissionsCard(_ preview: UserScriptInstaller.Preview) -> some View {
        section(title: "Permissions", systemImage: "key.fill") {
            if preview.metadata.grantsNone {
                Label("@grant none — runs with no privileged GM APIs.",
                      systemImage: "lock.open")
                    .font(.caption).foregroundStyle(BBTheme.Color.textSecondary)
            } else if preview.metadata.grants.isEmpty {
                Text("No special permissions requested.")
                    .font(.caption).foregroundStyle(BBTheme.Color.textSecondary)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(preview.metadata.grants, id: \.self) { grant in
                        BBPill(grant, systemImage: grantIcon(grant), tint: grantTint(grant))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func networkCard(_ preview: UserScriptInstaller.Preview) -> some View {
        if !preview.metadata.connects.isEmpty {
            section(title: "Network access", systemImage: "network") {
                FlowLayout(spacing: 6) {
                    ForEach(preview.metadata.connects, id: \.self) { host in
                        BBPill(host, systemImage: "arrow.up.right", tint: BBTheme.Color.secure)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func bundledCard(_ preview: UserScriptInstaller.Preview) -> some View {
        let requires = preview.metadata.requires.count
        let resources = preview.metadata.resources.count
        if requires > 0 || resources > 0 {
            section(title: "Bundled assets", systemImage: "shippingbox.fill") {
                HStack(spacing: 8) {
                    if requires > 0 { BBPill("\(requires) @require", systemImage: "link") }
                    if resources > 0 { BBPill("\(resources) @resource", systemImage: "doc") }
                }
            }
        }
    }

    private func sourceCard(_ preview: UserScriptInstaller.Preview) -> some View {
        section(title: "Source", systemImage: "chevron.left.forwardslash.chevron.right") {
            DisclosureGroup(isExpanded: $showSource) {
                ScrollView {
                    Text(preview.source)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(BBTheme.Color.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(.top, 6)
                }
                .frame(maxHeight: 220)
            } label: {
                Text(showSource ? "Hide source" : "Show source (\(preview.lineCount) lines)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(BBTheme.Color.accent)
            }
            .tint(BBTheme.Color.accent)
        }
    }

    private func actionBar(_ preview: UserScriptInstaller.Preview) -> some View {
        VStack(spacing: 8) {
            if let url = preview.sourceURL {
                Text(url.absoluteString)
                    .font(.caption2).foregroundStyle(BBTheme.Color.textSecondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            HStack(spacing: 12) {
                Button(action: onClose) {
                    Text("Cancel").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).tint(BBTheme.Color.textSecondary)

                if let url = preview.sourceURL, let onViewSource {
                    Button { onViewSource(url) } label: {
                        Image(systemName: "doc.plaintext")
                    }
                    .buttonStyle(.bordered).tint(BBTheme.Color.textSecondary)
                }

                Button {
                    Task { await model.install() }
                } label: {
                    Text(preview.isUpdate ? "Update" : "Install")
                        .fontWeight(.semibold).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(BBTheme.Color.accent)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial)
    }

    // MARK: Status / failure / success

    private func statusView(systemImage: String?, title: String, subtitle: String?) -> some View {
        VStack(spacing: 14) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 44)).foregroundStyle(BBTheme.Color.accent)
            } else {
                ProgressView().tint(BBTheme.Color.accent).scaleEffect(1.3)
            }
            Text(title).font(.headline).foregroundStyle(BBTheme.Color.textPrimary)
            if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(BBTheme.Color.textSecondary) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failureView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44)).foregroundStyle(BBTheme.Color.destructive)
            Text("Couldn’t read the script").font(.headline).foregroundStyle(BBTheme.Color.textPrimary)
            Text(message)
                .font(.subheadline).multilineTextAlignment(.center)
                .foregroundStyle(BBTheme.Color.textSecondary).padding(.horizontal, 32)
            HStack(spacing: 12) {
                Button("Close", action: onClose).buttonStyle(.bordered).tint(BBTheme.Color.textSecondary)
                Button("Retry") { Task { await model.load() } }
                    .buttonStyle(.borderedProminent).tint(BBTheme.Color.accent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }

    private func successView(name: String, wasUpdate: Bool) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56)).foregroundStyle(BBTheme.Color.secure)
            Text(wasUpdate ? "Updated" : "Installed").font(.title2.weight(.bold))
                .foregroundStyle(BBTheme.Color.textPrimary)
            Text(name).font(.subheadline).foregroundStyle(BBTheme.Color.textSecondary)
            Button("Done", action: onClose)
                .buttonStyle(.borderedProminent).tint(BBTheme.Color.accent).padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }

    // MARK: Building blocks

    private func section<Content: View>(title: String, systemImage: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        BBCard {
            VStack(alignment: .leading, spacing: 10) {
                Label(title, systemImage: systemImage)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(BBTheme.Color.textSecondary)
                    .textCase(.uppercase)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Formatting

    private func updateLabel(_ preview: UserScriptInstaller.Preview) -> String {
        let from = preview.existingVersion.map { "v\($0)" } ?? "installed"
        let to = preview.metadata.version.map { "v\($0)" } ?? "new"
        return "Update \(from) → \(to)"
    }

    private func runAtLabel(_ runAt: RunAt) -> String {
        switch runAt {
        case .documentStart: return "start"
        case .documentEnd: return "end"
        case .documentIdle: return "idle"
        }
    }

    private func byteString(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.0f KB", kb) }
        return String(format: "%.1f MB", kb / 1024)
    }

    private func grantIcon(_ grant: String) -> String {
        let lower = grant.lowercased()
        if lower.contains("xmlhttprequest") { return "network" }
        if lower.contains("setvalue") || lower.contains("getvalue") || lower.contains("value") { return "externaldrive" }
        if lower.contains("clipboard") { return "doc.on.clipboard" }
        if lower.contains("opentab") || lower.contains("tab") { return "rectangle.stack" }
        if lower.contains("notification") { return "bell" }
        if lower.contains("style") || lower.contains("element") { return "paintbrush" }
        return "key"
    }

    private func grantTint(_ grant: String) -> Color {
        let lower = grant.lowercased()
        // Network/clipboard reach outside the page — flag them in the "caution" color.
        if lower.contains("xmlhttprequest") || lower.contains("clipboard") || lower.contains("download") {
            return BBTheme.Color.secure
        }
        return BBTheme.Color.accent
    }
}

// MARK: - UIKit presentation

extension ScriptInstallView {
    /// Wrap the install sheet in a hosting controller with grabber + medium/large detents, wired to
    /// dismiss itself. `onViewSource` lets the browser fall back to showing the raw file.
    static func makeHostingController(url: URL,
                                      onViewSource: ((URL) -> Void)? = nil,
                                      onFinished: (() -> Void)? = nil) -> UIViewController {
        var hosting: UIHostingController<ScriptInstallView>?
        let view = ScriptInstallView(
            url: url,
            onClose: { hosting?.dismiss(animated: true); onFinished?() },
            onViewSource: onViewSource.map { handler in { sourceURL in hosting?.dismiss(animated: true); handler(sourceURL) } })
        let controller = UIHostingController(rootView: view)
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 24
        }
        hosting = controller
        return controller
    }
}
