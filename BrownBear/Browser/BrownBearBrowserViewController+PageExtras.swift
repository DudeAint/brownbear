//
//  BrownBearBrowserViewController+PageExtras.swift
//  BrownBear
//
//  Reader-mode + downloads-toast helpers, split out of the main browser controller to keep it under
//  the SwiftLint file-length limit. The three entry points the rest of the controller calls
//  (presentReader / presentDownloadStartedToast / presentDownloads) are `internal` for that reason.
//

import UIKit
import WebKit

extension BrownBearBrowserViewController {

    /// A brief, non-modal confirmation that a download began (fired post-confirm via the manager's
    /// onDownloadStarted). Tapping it opens the Downloads list; otherwise it fades after a moment.
    func presentDownloadStartedToast() {
        var config = UIButton.Configuration.filled()
        config.title = "Download started — tap to view"
        config.baseBackgroundColor = BrownBearTheme.Palette.accent
        config.baseForegroundColor = .white
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
        var title = AttributeContainer()
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        config.attributedTitle = AttributedString("Download started — tap to view", attributes: title)
        let toast = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
            self?.presentDownloads()
        })
        toast.alpha = 0
        toast.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toast)
        NSLayoutConstraint.activate([
            toast.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: toolbar.topAnchor, constant: -12)
        ])
        UIView.animate(withDuration: 0.25, animations: { toast.alpha = 1 }) { _ in
            UIView.animate(withDuration: 0.3, delay: 2.2, options: []) {
                toast.alpha = 0
            } completion: { _ in toast.removeFromSuperview() }
        }
    }

    func presentDownloads() {
        guard presentedViewController == nil else { return }
        present(DownloadsView.makeHostingController(), animated: true)
    }

    /// Brief confirmation that the active page was saved to the reading list (the ••• menu has already
    /// dismissed, so without this the action gives no feedback). Same capsule treatment as the download toast.
    func presentReadingListToast() {
        var config = UIButton.Configuration.filled()
        config.baseBackgroundColor = BrownBearTheme.Palette.accent
        config.baseForegroundColor = .white
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
        var title = AttributeContainer()
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        config.attributedTitle = AttributedString("Added to Reading List", attributes: title)
        let toast = UIButton(configuration: config)
        toast.isUserInteractionEnabled = false
        toast.alpha = 0
        toast.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toast)
        NSLayoutConstraint.activate([
            toast.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: toolbar.topAnchor, constant: -12)
        ])
        UIView.animate(withDuration: 0.25, animations: { toast.alpha = 1 }) { _ in
            UIView.animate(withDuration: 0.3, delay: 1.6, options: []) {
                toast.alpha = 0
            } completion: { _ in toast.removeFromSuperview() }
        }
    }

    /// The bundled clean-room article extractor, loaded once.
    private static let readabilityScript: String = {
        guard let url = Bundle.main.url(forResource: "brownbear-readability", withExtension: "js")
                ?? Bundle.main.url(forResource: "brownbear-readability", withExtension: "js", subdirectory: "JS"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return source
    }()

    /// Extract the active page's article (in the page world) and present the reader, or explain that
    /// the page isn't article-like. Uses the ObjC result-returning eval so no Swift WebKit overlay links.
    func presentReader() {
        guard let webView = tabManager.activeTab?.webView, !Self.readabilityScript.isEmpty else { return }
        BBEvaluateJavaScriptForResult(webView, Self.readabilityScript, .page) { [weak self] result, _ in
            guard let self else { return }
            guard let dict = result as? [String: Any],
                  let content = dict["content"] as? String, !content.isEmpty else {
                self.presentReaderUnavailable()
                return
            }
            let fallbackTitle = self.tabManager.activeTab?.state.displayTitle ?? "Article"
            let article = ReaderViewController.Article(
                title: (dict["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackTitle,
                byline: (dict["byline"] as? String) ?? "",
                content: content)
            ReaderViewController.present(article, from: self)
        }
    }

    private func presentReaderUnavailable() {
        let alert = UIAlertController(title: "Reader unavailable",
                                     message: "This page doesn't look like an article.",
                                     preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    // MARK: - Full-page screenshot

    /// Capture the ENTIRE scrollable page (not just the visible area) as a PDF and offer it via the share
    /// sheet — the same artifact iOS Safari's full-page screenshot produces, so it saves to Files, AirDrops,
    /// prints, etc. `createPDF` renders the whole content; its completion lands on the main thread.
    func captureFullPageScreenshot() {
        guard let tab = tabManager.activeTab else { return }
        let title = tab.state.displayTitle
        // Via the ObjC bridge, NOT WKWebView.createPDF's Swift Result API — that links the Swift WebKit
        // overlay, which aborts a 16.4-deployment app at launch (same reason the eval calls are bridged).
        BBCreatePDF(tab.webView) { [weak self] data, _ in
            guard let self, let data else { return }
            self.shareFullPagePDF(data, title: title)
        }
    }

    private func shareFullPagePDF(_ data: Data, title: String) {
        // A filesystem-safe file name from the page title so the share sheet shows something recognisable.
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = title.components(separatedBy: illegal).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? "Page" : String(cleaned.prefix(60))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(base + ".pdf")
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        share.popoverPresentationController?.sourceView = toolbar
        share.popoverPresentationController?.sourceRect = toolbar.bounds
        present(share, animated: true)
    }
}
