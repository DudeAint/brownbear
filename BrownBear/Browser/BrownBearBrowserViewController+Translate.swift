//
//  BrownBearBrowserViewController+Translate.swift
//  BrownBear
//
//  In-page translation: the "Translate Page" menu action. Injects the page engine (brownbear-translate.js),
//  collects the page's translatable text nodes, and translates them with Apple's on-device Translation
//  framework (iOS 18+), writing each batch back onto the page's own text nodes as it completes. A slim bar
//  lets the user pick the TARGET language (re-translating in place), flip between the translation and the
//  original, or dismiss it (restoring the page). Translation is ALWAYS attempted — the source language is
//  left to the framework to auto-detect (source: nil), so it never falsely decides a page is "already in
//  your language". Apple-only by product decision: on iOS < 18 the action explains that translation needs 18.
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

    /// Target languages offered in the bar's picker (BCP-47 → localized name resolved at display time). Covers
    /// Apple's on-device set; an unsupported pick simply surfaces "Couldn't translate" rather than being hidden.
    static let translateTargetLanguages: [String] = [
        "en", "es", "fr", "de", "it", "pt-BR", "zh-Hans", "zh-Hant", "ja", "ko",
        "ru", "ar", "hi", "nl", "pl", "tr", "th", "vi", "id", "uk"
    ]

    /// Entry point from the menu. Gates iOS 18, injects the engine, collects the page's text, then translates
    /// to the user's language (re-targetable from the bar). No source-language pre-check — always translate.
    func presentTranslatePage() {
        guard #available(iOS 18.0, *) else {
            presentTranslateInfo(title: "Translation needs iOS 18",
                                  message: "On-device page translation is available on iOS 18 and later.")
            return
        }
        guard let webView = tabManager.activeTab?.webView, !Self.translateEngineScript.isEmpty else { return }
        let collect = Self.translateEngineScript + "\n;JSON.stringify(window.__bbTranslate.collect());"
        BBEvaluateJavaScriptForResult(webView, collect, .page) { [weak self, weak webView] result, _ in
            guard let self, let webView else { return }
            let units = Self.parseUnits(result)
            guard !units.isEmpty else {
                self.presentTranslateInfo(title: "Nothing to translate",
                                          message: "This page has no translatable text.")
                return
            }
            self.runTranslation(units: units, webView: webView, target: Self.deviceTargetLanguage())
        }
    }

    /// Translate `units` to `target` (source auto-detected) and stream each batch onto the page. Shows/updates
    /// the bar; re-callable from the bar's language picker to retarget the SAME nodes without re-collecting.
    @available(iOS 18.0, *)
    func runTranslation(units: [TranslationUnit], webView: WKWebView, target: String) {
        showTranslateBar(units: units, webView: webView, target: target)
        translateBar?.setTranslating()
        let translator = ApplePageTranslator(parent: self)
        Task { @MainActor in
            do {
                try await translator.translate(units: units, source: nil, target: target) { [weak self, weak webView] batch in
                    guard let webView else { return }
                    self?.applyTranslations(batch, to: webView)
                }
                self.translateBar?.setTranslated(target: target)
            } catch {
                self.translateBar?.setFailed()
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

    /// Show (or update) the translate bar for `units`/`target`. The picker retargets via runTranslation on the
    /// same units; the toggle/close drive the engine directly. Replaces any existing bar.
    @available(iOS 18.0, *)
    func showTranslateBar(units: [TranslationUnit], webView: WKWebView, target: String) {
        if let bar = translateBar { bar.setTarget(target); return }   // already showing → just update the target
        let bar = TranslateBar(target: target, webView: webView, languages: Self.translateTargetLanguages)
        bar.onPickLanguage = { [weak self, weak webView] newTarget in
            guard let self, let webView else { return }
            self.runTranslation(units: units, webView: webView, target: newTarget)
        }
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

    /// The user's default target language — the device's top preferred language, primary subtag.
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

/// The slim bar shown while a page is translated: a target-language picker, a Translation/Original toggle, and
/// a close button. The picker retargets via `onPickLanguage`; the toggle/close drive the page engine directly.
/// Self-contained — it removes itself on close — so the controller only holds a weak reference.
@MainActor
final class TranslateBar: UIView {

    private weak var webView: WKWebView?
    private let languages: [String]
    private var target: String
    private let langButton = UIButton(type: .system)
    private let toggle = UISegmentedControl(items: ["Translation", "Original"])

    /// Called when the user picks a different target language (BCP-47). The controller re-translates in place.
    var onPickLanguage: ((String) -> Void)?

    init(target: String, webView: WKWebView, languages: [String]) {
        self.target = target
        self.webView = webView
        self.languages = languages
        super.init(frame: .zero)
        backgroundColor = BrownBearTheme.Palette.chrome
        layer.borderWidth = 0.5
        layer.borderColor = BrownBearTheme.Palette.borderSubtle.cgColor

        langButton.titleLabel?.font = .preferredFont(forTextStyle: .footnote)
        langButton.titleLabel?.adjustsFontForContentSizeCategory = true
        langButton.tintColor = BrownBearTheme.Palette.textPrimary
        langButton.showsMenuAsPrimaryAction = true
        langButton.menu = makeLanguageMenu()
        langButton.setContentHuggingPriority(.defaultLow, for: .horizontal)

        toggle.selectedSegmentIndex = 0
        toggle.addTarget(self, action: #selector(toggleChanged), for: .valueChanged)
        toggle.setContentHuggingPriority(.required, for: .horizontal)

        let close = UIButton(type: .system)
        close.setImage(UIImage(systemName: "xmark"), for: .normal)
        close.tintColor = BrownBearTheme.Palette.textSecondary
        close.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        close.setContentHuggingPriority(.required, for: .horizontal)

        let stack = UIStackView(arrangedSubviews: [langButton, toggle, close])
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
        setTranslating()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - State

    func setTranslating() { langButton.setTitle("Translating to \(Self.name(target))…", for: .normal) }
    func setTranslated(target: String) {
        self.target = target
        langButton.menu = makeLanguageMenu()   // move the checkmark to the new target
        langButton.setTitle("Translated: \(Self.name(target)) ▾", for: .normal)
    }
    func setFailed() { langButton.setTitle("Couldn't translate — try another ▾", for: .normal) }
    func setTarget(_ target: String) {
        self.target = target
        langButton.menu = makeLanguageMenu()
        setTranslating()
    }

    // MARK: - Picker

    private func makeLanguageMenu() -> UIMenu {
        let actions = languages.map { code in
            UIAction(title: Self.name(code), state: code == target ? .on : .off) { [weak self] _ in
                self?.onPickLanguage?(code)
            }
        }
        return UIMenu(title: "Translate to", children: actions)
    }

    private static func name(_ code: String) -> String {
        Locale.current.localizedString(forIdentifier: code)
            ?? Locale.current.localizedString(forLanguageCode: code)
            ?? code.uppercased()
    }

    // MARK: - Engine

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
