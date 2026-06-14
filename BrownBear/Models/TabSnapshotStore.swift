//
//  TabSnapshotStore.swift
//  BrownBear
//
//  Persists tab thumbnail snapshots to disk so the tab grid can show a real preview for tabs restored
//  after the app was closed (without this, a restored-but-not-yet-loaded tab shows a blank placeholder).
//  Keyed by the tab's stable id, downscaled + JPEG-encoded so files stay small and decode lazily. Lives in
//  Application Support (NOT Caches): an app UPDATE wipes Caches, which would blank every tab's preview on
//  the first launch after each update — the user's "tabs lost how they were" report. Application Support
//  survives updates; `prune` caps growth (Caches' purge-on-pressure no longer does), and the directory is
//  excluded from iCloud backup since the thumbnails are regenerable + per-device. Private tabs are never
//  persisted (incognito leaves no trace).
//

import UIKit

@MainActor
enum TabSnapshotStore {

    /// Cap the long edge so a Retina-sized page snapshot doesn't bloat the cache; the grid card is small.
    private static let maxDimension: CGFloat = 480

    private static var directory: URL? {
        let fileManager = FileManager.default
        guard let base = try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                              appropriateFor: nil, create: true) else { return nil }
        var dir = base.appendingPathComponent("BrownBear/TabSnapshots", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        // Regenerable, per-device thumbnails — keep them out of the user's iCloud backup.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir
    }

    private static func fileURL(id: String) -> URL? {
        directory?.appendingPathComponent(id + ".jpg")
    }

    /// Save a downscaled JPEG of `image` for `id`. Best-effort — a failed save just means no preview.
    static func save(_ image: UIImage, id: String) {
        guard let url = fileURL(id: id),
              let data = downscaled(image, maxDimension: maxDimension).jpegData(compressionQuality: 0.6) else {
            return
        }
        try? data.write(to: url, options: .atomic)
    }

    /// Load the saved snapshot for `id`, or nil if none. `UIImage(data:)` defers the actual decode until
    /// the image is first drawn (when the grid card appears), so this stays cheap to call at launch.
    static func load(id: String) -> UIImage? {
        guard let url = fileURL(id: id), let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    /// Delete saved snapshots whose id isn't in `keep` (closed/gone tabs), so the cache can't grow forever.
    static func prune(keeping keep: Set<String>) {
        guard let dir = directory,
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return }
        for file in files where file.pathExtension == "jpg" {
            let id = file.deletingPathExtension().lastPathComponent
            if !keep.contains(id) { try? FileManager.default.removeItem(at: file) }
        }
    }

    private static func downscaled(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxDimension, longest > 0 else { return image }
        let scale = maxDimension / longest
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return UIGraphicsImageRenderer(size: target).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
