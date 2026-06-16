//
//  ApplePageTranslator.swift
//  BrownBear
//
//  The Apple on-device translation backend for in-page translation (iOS 18+). Apple's Translation framework
//  vends a `TranslationSession` ONLY through SwiftUI's `.translationTask` modifier — there is no public
//  initializer — so to drive it from our UIKit browser we host a zero-size SwiftUI view carrying that
//  modifier, set its configuration to trigger the task, and run the batch `translations(from:)` API inside
//  the action, streaming each completed chunk back to the caller (which writes it onto the page's text nodes).
//
//  On-device + private: no page text leaves the device, works offline once the language pair is downloaded.
//  Gated to iOS 18 — older systems fall back to no translation (the menu action explains why).
//

import UIKit
import SwiftUI
import Translation

/// Drives Apple's Translation framework from UIKit to translate the page's collected text nodes, streaming
/// results back as each batch completes. One instance per translation run; it attaches a hidden host to a
/// parent view controller for the framework's SwiftUI requirement and removes it when done.
@available(iOS 18.0, *)
@MainActor
final class ApplePageTranslator {

    private weak var parent: UIViewController?
    private var hosting: UIHostingController<TranslationHostView>?
    private let model = TranslationHostModel()

    init(parent: UIViewController) { self.parent = parent }

    /// Translate `units` from `source` (a BCP-47 code, or nil to let the framework detect) into `target`,
    /// invoking `onBatch` with `[nodeId: translatedText]` as each chunk completes — so the page fills in
    /// progressively. Throws if the framework can't service the language pair.
    func translate(units: [TranslationUnit],
                   source: String?,
                   target: String,
                   onBatch: @escaping ([String: String]) -> Void) async throws {
        guard !units.isEmpty else { return }
        let configuration = TranslationSession.Configuration(
            source: source.flatMap { $0.isEmpty ? nil : Locale.Language(identifier: $0) },
            target: Locale.Language(identifier: target))

        attachHost()
        defer { detachHost() }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // The action runs inside SwiftUI's task once the configuration is applied; do all the work there.
            model.onSession = { session in
                do {
                    // Chunk so the page fills in progressively and a huge page doesn't build one giant request.
                    for batch in PageTranslator.batches(units, maxChars: 2000) {
                        let requests = batch.map {
                            TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id)
                        }
                        let responses = try await session.translations(from: requests)
                        var mapped: [String: String] = [:]
                        for response in responses {
                            if let id = response.clientIdentifier { mapped[id] = response.targetText }
                        }
                        if !mapped.isEmpty { onBatch(mapped) }
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            model.configuration = configuration   // triggers .translationTask
        }
    }

    /// Whether the device can translate `source`→`target` at all (installed or downloadable), so the caller
    /// can fail fast with a clear message instead of starting a run that the framework will reject.
    static func canTranslate(from source: String?, to target: String) async -> Bool {
        let availability = LanguageAvailability()
        let src = source.flatMap { $0.isEmpty ? nil : Locale.Language(identifier: $0) }
        let status = await availability.status(from: src, to: Locale.Language(identifier: target))
        switch status {
        case .installed, .supported: return true
        case .unsupported: return false
        @unknown default: return false
        }
    }

    // MARK: - Hidden SwiftUI host

    private func attachHost() {
        guard hosting == nil, let parent else { return }
        let controller = UIHostingController(rootView: TranslationHostView(model: model))
        controller.view.frame = .zero
        controller.view.isUserInteractionEnabled = false
        controller.view.alpha = 0
        parent.addChild(controller)
        parent.view.addSubview(controller.view)
        controller.didMove(toParent: parent)
        hosting = controller
    }

    private func detachHost() {
        guard let controller = hosting else { return }
        controller.willMove(toParent: nil)
        controller.view.removeFromSuperview()
        controller.removeFromParent()
        hosting = nil
    }
}

/// Bridges the imperative translation request to the SwiftUI `.translationTask`: the view observes the
/// configuration; setting it runs `onSession` with the framework's session.
@available(iOS 18.0, *)
@MainActor
final class TranslationHostModel: ObservableObject {
    @Published var configuration: TranslationSession.Configuration?
    var onSession: ((TranslationSession) async -> Void)?
}

@available(iOS 18.0, *)
struct TranslationHostView: View {
    @ObservedObject var model: TranslationHostModel
    var body: some View {
        Color.clear
            .translationTask(model.configuration) { session in
                await model.onSession?(session)
            }
    }
}
