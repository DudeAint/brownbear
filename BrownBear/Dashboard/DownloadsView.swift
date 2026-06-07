//
//  DownloadsView.swift
//  BrownBear
//
//  The downloads list, presented as a sheet from the browser menu. Shows each file's progress, and
//  for finished files a Share/Open action; swipe to delete (also removes the file on disk). Observes
//  the shared DownloadManager so progress updates live.
//

import SwiftUI
import UIKit

struct DownloadsView: View {

    let onClose: () -> Void

    @ObservedObject private var manager = DownloadManager.shared

    var body: some View {
        NavigationStack {
            Group {
                if manager.downloads.isEmpty {
                    DashboardEmptyState(
                        systemImage: "arrow.down.circle",
                        title: "No downloads",
                        message: "Files you download — PDFs, archives, anything the browser can't "
                            + "open inline — appear here.")
                } else {
                    List {
                        ForEach(manager.downloads) { item in
                            DownloadRowView(item: item)
                                .listRowBackground(BBTheme.Color.card)
                        }
                        .onDelete(perform: delete)
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(BBTheme.backgroundGradient)
            .navigationTitle("Downloads")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done", action: onClose).fontWeight(.semibold)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Clear finished") { manager.clearFinished() }
                        .disabled(!manager.downloads.contains(where: \.isFinished))
                }
            }
        }
        .tint(BBTheme.Color.accent)
    }

    private func delete(_ offsets: IndexSet) {
        let ids = offsets.map { manager.downloads[$0].id }
        for id in ids { manager.remove(id: id) }
    }
}

private struct DownloadRowView: View {
    let item: DownloadItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(BBTheme.Color.accent)
                .frame(width: 32, height: 32)
                .background(BBTheme.Color.accent.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.fileName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(BBTheme.Color.textPrimary)
                    .lineLimit(1)
                if case .downloading = item.state {
                    ProgressView(value: item.fractionCompleted)
                        .tint(BBTheme.Color.accent)
                }
                Text(item.statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if item.isFinished {
                ShareLink(item: item.localURL) {
                    Image(systemName: "square.and.arrow.up").foregroundStyle(BBTheme.Color.accent)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var icon: String {
        switch item.state {
        case .downloading: return "arrow.down.circle"
        case .finished: return "doc.fill"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private var statusColor: Color {
        switch item.state {
        case .failed: return BBTheme.Color.destructive
        case .finished: return BBTheme.Color.secure
        case .downloading: return BBTheme.Color.textSecondary
        }
    }
}

// MARK: - UIKit presentation

extension DownloadsView {
    /// Wrap the list in a hosting controller wired to dismiss itself.
    static func makeHostingController() -> UIViewController {
        var hosting: UIHostingController<DownloadsView>?
        let view = DownloadsView(onClose: { hosting?.dismiss(animated: true) })
        let controller = UIHostingController(rootView: view)
        controller.modalPresentationStyle = .pageSheet
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 24
        }
        hosting = controller
        return controller
    }
}
