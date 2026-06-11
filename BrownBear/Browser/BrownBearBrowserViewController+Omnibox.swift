//
//  BrownBearBrowserViewController+Omnibox.swift
//  BrownBear
//
//  Omnibox behavior for the browser: resolving typed text into a destination, reload/stop, and the
//  live autocomplete dropdown (top sites on focus, history + the typed action as you type). Split
//  out of BrownBearBrowserViewController to keep that file lean; the shared members it touches
//  (omnibox, omniboxSuggestions, suggestionTask, tabManager, presentError) are internal for that
//  reason — a Swift extension in another file can only reach internal (or higher) members.
//

import UIKit

// MARK: - OmniboxViewDelegate

extension BrownBearBrowserViewController: OmniboxViewDelegate {

    func omnibox(_ omnibox: OmniboxView, didSubmit text: String) {
        do {
            let classifier = OmniboxInputClassifier(searchTemplate: AppSettings.searchEngine.template)
            let destination = try classifier.destination(for: text)
            let tab = tabManager.activeTab ?? tabManager.createTab()
            tab.delegate = self
            tab.load(destination.resolvedURL)
        } catch {
            presentError(error)
        }
    }

    func omniboxDidTapReloadStop(_ omnibox: OmniboxView) {
        guard let tab = tabManager.activeTab else { return }
        if tab.state.isLoading { tab.stopLoading() } else { tab.reload() }
    }

    func omniboxDidBeginEditing(_ omnibox: OmniboxView) {
        // Show top sites immediately on focus, before the user types.
        suggestionTask?.cancel()
        suggestionTask = Task { @MainActor in
            let top = await BrownBearServices.shared.historyStore.topSites(limit: 6)
            guard !Task.isCancelled else { return }
            omniboxSuggestions.update(OmniboxSuggestionEngine.topSites(top))
        }
    }

    func omnibox(_ omnibox: OmniboxView, didChangeText text: String) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        suggestionTask?.cancel()
        guard !query.isEmpty else {
            // Back to empty — fall through to the top-sites state.
            omniboxDidBeginEditing(omnibox)
            return
        }
        let template = AppSettings.searchEngine.template
        suggestionTask = Task { @MainActor in
            let matches = await BrownBearServices.shared.historyStore.search(query, limit: 6)
            guard !Task.isCancelled else { return }
            omniboxSuggestions.update(OmniboxSuggestionEngine.compose(rawQuery: query,
                                                                      historyMatches: matches,
                                                                      searchTemplate: template))
        }
    }

    func omniboxDidEndEditing(_ omnibox: OmniboxView) {
        suggestionTask?.cancel()
        omniboxSuggestions.dismiss()
    }

    func omniboxDidTapSiteInfo(_ omnibox: OmniboxView) {
        presentSiteShields()
    }
}

// MARK: - OmniboxSuggestionsViewDelegate

extension BrownBearBrowserViewController: OmniboxSuggestionsViewDelegate {
    func suggestionsView(_ view: OmniboxSuggestionsView, didSelect suggestion: OmniboxSuggestion) {
        omnibox.endEditing()
        omniboxSuggestions.dismiss()
        let tab = tabManager.activeTab ?? tabManager.createTab()
        tab.delegate = self
        tab.load(suggestion.url)
    }

    /// A tap on the exposed page area below the suggestions card — resign the omnibox so the keyboard
    /// drops (and `omniboxDidEndEditing` clears the card), revealing the page the user tapped toward.
    func suggestionsViewDidRequestDismiss(_ view: OmniboxSuggestionsView) {
        omnibox.endEditing()
    }
}
