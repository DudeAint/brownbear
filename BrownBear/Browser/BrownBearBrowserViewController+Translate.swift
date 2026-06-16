//
//  BrownBearBrowserViewController+Translate.swift
//  BrownBear
//
//  In-page translation: the "Translate Page" menu action. Injects the page engine (brownbear-translate.js),
//  collects the page's translatable text nodes, detects the source language on-device (NaturalLanguage),
//  and — when the page isn't already in the user's language — translates it with Apple's on-device
//  Translation framework (iOS 18+), writing each batch back onto the page's own text nodes as it completes.
//  A slim bar lets the user flip between the translation and the original, or dismiss it (restoring the page).
//  Apple-only by product decision: on iOS < 18 the action explains that translation needs iOS 18.
//

import UIKit
import WebKit

extension BrownBearBrowserViewController {

    /// The bundled in-page translation engine, loaded once.
    static let translateEngineScript: String = {
        guard let url = Bundle.main.url(forResource: "brownbear-translate", withExtension: "js")
                ?? Bundle.main.url(forResource: "brownbear-translate", withExtension: "js", subdirectory: "JS"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return source
    }()

    /// Entry point from the menu. Gates iOS 18, then injects the engine and collects the page's text.
    func presentTranslatePage() {
        guard #available(iOS 18.0, *) else {
            presentTranslateInfo(title: "Translation needs iOS 18",
                                  message: "On-device page translation is available on iOS 18 and later.")
            return
        }
        guard let webView = tabManager.activeTab?.webView, !Self.translateEngineScript.isEmpty else { return }
        // Install the engine (idempotent) and return the collected nodes in one round-trip.
        let collect = Self.translateEngineScript + "\n;JSON.stringify(window.__bbTranslate.collect());"
        BBEvaluateJavaScriptForResult(webView, collect, .page) { [weak self, weak webView] result, _ in
            guard let self, let webView else { return }
            let units = Self.parseUnits(result)
            guard !units.isEmpty else {
                self.presentTranslateInfo(title: "Nothing to translate",
                                          message: "This page has no translatable text.")
                return
            }
            self.beginTranslation(units: units, webView: webView)
        }
    }

    @available(iOS 18.0, *)
    private func beginTranslation(units: [TranslationUnit], webView: WKWebView) {
        let source = PageTranslator.detectLanguage(of: PageTranslator.languageSample(from: units))
        let target = Self.deviceTargetLanguage()
        guard PageTranslator.needsTranslation(source: source, target: target) else {
            presentTranslateInfo(title: "Already in your language",
                                 message: "This page already appears to be in your language.")
            return
        }
        let translator = ApplePageTranslator(parent: self)
        Task { @MainActor in
            guard await ApplePageTranslator.canTranslate(from: source, to: target) else {
                self.presentTranslateInfo(title: "Language not available",
                                          message: "On-device translation for this page's language isn't available yet.")
                return
            }
            do {
                try await translator.translate(units: units, source: source, target: target) { [weak self, weak webView] batch in
                    guard let webView else { return }
                    self?.applyTranslations(batch, to: webView)
                }
                self.showTranslateBar(target: target, webView: webView)
            } catch {
                self.presentTranslateInfo(title: "Couldn't translate",
                                          message: "The page couldn't be translated. Please try again.")
            }
        }
    }

    /// Write a completed batch of translations onto the page's text nodes via the engine's apply().
    func applyTranslations(_ batch: [String: String], to webView: WKWebView) {
        let items = batch.map { ["id": $0.key, "text": $0.value] }
        guard let data = try? JSONSerialization.data(withJSONObject: items),
              let json = String(data: data, encoding: .utf8) else { return }
        BBEvaluateJavaScript(webView, "window.__bbTranslate && window.__bbTranslate.apply(\(json));", .page)
    }

    /// Show the slim translate bar (toggle translation/original, dismiss → restore). Replaces any existing one.
    func showTranslateBar(target: String, webView: WKWebView) {
        translateBar?.removeFromSuperview()
        let bar = TranslateBar(languageCode: target, webView: webView)
        translateBar = bar
        bar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
    }

    /// Remove the translate bar and restore the page to its original text (called when a tab navigates away
    /// or the user dismisses translation). Safe to call when no translation is active.
    func dismissTranslation() {
        guard let bar = translateBar else { return }
        bar.restoreAndRemove()
        translateBar = nil
    }

    // MARK: - Helpers

    /// The user's target language for translation — the device's top preferred language, primary subtag.
    static func deviceTargetLanguage() -> String {
        let preferred = Locale.preferredLanguages.first ?? Locale.current.identifier
        return PageTranslator.primaryLanguage(of: preferred) ?? "en"
    }

    /// Parse the engine's collect() JSON ([{id,text}]) into TranslationUnits.
    static func parseUnits(_ result: Any?) -> [TranslationUnit] {
        guard let json = result as? String, let data = json.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return arr.compactMap { dict in
            guard let id = dict["id"] as? String, let text = dict["text"] as? String else { return nil }
            return TranslationUnit(id: id, text: text)
        }
    }

    private func presentTranslateInfo(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

/// The slim bar shown while a page is translated: a label, a Translation/Original toggle, and a close button.
/// Self-contained — it drives the page engine directly (showOriginal/showTranslated/reset) and removes itself
/// on close, so the controller needs only to hold a weak reference for replacement/navigation cleanup.
@MainActor
final class TranslateBar: UIView {

    private weak var webView: WKWebView?
    private let toggle = UISegmentedControl(items: ["Translation", "Original"])

    init(languageCode: String, webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        backgroundColor = BrownBearTheme.Palette.chrome
        layer.borderWidth = 0.5
        layer.borderColor = BrownBearTheme.Palette.borderSubtle.cgColor

        let label = UILabel()
        let langName = Locale.current.localizedString(forLanguageCode: languageCode) ?? languageCode.uppercased()
        label.text = "Translated to \(langName)"
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = BrownBearTheme.Palette.textSecondary
        label.adjustsFontForContentSizeCategory = true

        toggle.selectedSegmentIndex = 0
        toggle.addTarget(self, action: #selector(toggleChanged), for: .valueChanged)

        let close = UIButton(type: .system)
        close.setImage(UIImage(systemName: "xmark"), for: .normal)
        close.tintColor = BrownBearTheme.Palette.textSecondary
        close.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        close.setContentHuggingPriority(.required, for: .horizontal)

        let stack = UIStackView(arrangedSubviews: [label, toggle, close])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func toggleChanged() {
        guard let webView else { return }
        let call = toggle.selectedSegmentIndex == 0 ? "showTranslated" : "showOriginal"
        BBEvaluateJavaScript(webView, "window.__bbTranslate && window.__bbTranslate.\(call)();", .page)
    }

    @objc private func closeTapped() { restoreAndRemove() }

    /// Restore the page to its original text and remove the bar.
    func restoreAndRemove() {
        if let webView { BBEvaluateJavaScript(webView, "window.__bbTranslate && window.__bbTranslate.reset();", .page) }
        removeFromSuperview()
    }
}
