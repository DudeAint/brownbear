//
//  ReaderViewController.swift
//  BrownBear
//
//  A distraction-free reading view. Renders the article HTML extracted by brownbear-readability.js in
//  a themed web view with JavaScript DISABLED — the extractor already strips scripts/handlers, and
//  turning JS off is belt-and-braces so nothing from the page can run here. Title/byline are page-
//  derived, so they're HTML-escaped before injection.
//

import UIKit
import WebKit

final class ReaderViewController: UIViewController {

    struct Article {
        let title: String
        let byline: String
        let content: String   // sanitized HTML from the extractor
    }

    private let article: Article
    private var webView: WKWebView!

    init(article: Article) {
        self.article = article
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Reader"
        view.backgroundColor = BrownBearTheme.Palette.background
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done,
                                                           target: self, action: #selector(done))

        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        webView = WKWebView(frame: .zero, configuration: config)
        webView.backgroundColor = BrownBearTheme.Palette.background
        webView.isOpaque = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: guide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        webView.loadHTMLString(Self.html(for: article), baseURL: nil)
    }

    @objc private func done() { dismiss(animated: true) }

    /// Present the reader as a page sheet wrapped in a navigation controller (for the title + Done).
    static func present(_ article: Article, from presenter: UIViewController) {
        let reader = ReaderViewController(article: article)
        let nav = UINavigationController(rootViewController: reader)
        nav.modalPresentationStyle = .pageSheet
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 24
        }
        presenter.present(nav, animated: true)
    }

    private static func htmlEscape(_ string: String) -> String {
        string.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func html(for article: Article) -> String {
        let title = htmlEscape(article.title)
        let byline = article.byline.isEmpty ? "" : "<p class=\"byline\">\(htmlEscape(article.byline))</p>"
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
        <style>
          :root{color-scheme:light dark;--bg:#FBF8F4;--text:#1A140E;--sub:#6B6058;--accent:#C8741F;--rule:#E7DFD4;}
          @media (prefers-color-scheme:dark){:root{--bg:#16120D;--text:#ECE4D8;--sub:#A99C8C;--accent:#FFB454;--rule:#2E261C;}}
          *{box-sizing:border-box;}
          html,body{margin:0;background:var(--bg);color:var(--text);
            font:18px/1.65 -apple-system,Georgia,serif;-webkit-text-size-adjust:100%;}
          .wrap{max-width:700px;margin:0 auto;padding:28px 22px 64px;}
          h1{font:700 28px/1.25 -apple-system,system-ui,sans-serif;margin:0 0 8px;letter-spacing:-.4px;}
          .byline{color:var(--sub);font:14px/1.4 -apple-system,system-ui,sans-serif;margin:0 0 24px;
            padding-bottom:18px;border-bottom:1px solid var(--rule);}
          p{margin:0 0 18px;}
          a{color:var(--accent);}
          img,video{max-width:100%;height:auto;border-radius:8px;}
          pre,code{font-family:ui-monospace,Menlo,monospace;font-size:15px;}
          pre{background:rgba(127,127,127,.12);padding:12px;border-radius:8px;overflow:auto;}
          blockquote{margin:0 0 18px;padding-left:16px;border-left:3px solid var(--accent);color:var(--sub);}
          h2,h3{font-family:-apple-system,system-ui,sans-serif;line-height:1.3;margin:28px 0 10px;}
        </style></head><body>
          <div class="wrap">
            <h1>\(title)</h1>
            \(byline)
            \(article.content)
          </div>
        </body></html>
        """
    }
}
