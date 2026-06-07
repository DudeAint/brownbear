//
//  ScriptEditorScreen.swift
//  BrownBear
//
//  The in-app code editor. Hosts the Runestone editor, parses the metadata live so the user sees
//  the script's name/validity as they type, and validates on save (a script with no metadata block
//  or no @name cannot be saved).
//

import SwiftUI

struct ScriptEditorScreen: View {

    @ObservedObject var model: DashboardViewModel
    /// nil → creating a new script.
    let existing: UserScript?

    @Environment(\.dismiss) private var dismiss
    @State private var source: String
    @State private var saveError: String?
    @State private var confirmingDiscard = false

    private let parser = ScriptMetadataParser()
    private let originalSource: String

    init(model: DashboardViewModel, existing: UserScript?) {
        self.model = model
        self.existing = existing
        let initial = existing?.source ?? Self.template
        self.originalSource = initial
        _source = State(initialValue: initial)
    }

    private var parsedMetadata: ScriptMetadata? { try? parser.parse(source) }

    /// Whether the user has edited the source since opening — gates the discard guard.
    private var isDirty: Bool { source != originalSource }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                metadataHeader
                Divider().overlay(BBTheme.Color.separator)
                CodeEditorView(text: $source)
            }
            .background(BBTheme.Color.background)
            .navigationTitle(existing == nil ? "New Script" : "Edit Script")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { attemptCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(parsedMetadata == nil)
                }
            }
            .interactiveDismissDisabled(isDirty)
            .alert("Couldn’t save", isPresented: .constant(saveError != nil)) {
                Button("OK") { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
            .confirmationDialog("Discard changes?", isPresented: $confirmingDiscard,
                                titleVisibility: .visible) {
                Button("Discard", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) { }
            } message: {
                Text("Your edits to this script haven't been saved.")
            }
        }
    }

    /// Cancel, but guard against silently losing unsaved edits.
    private func attemptCancel() {
        if isDirty { confirmingDiscard = true } else { dismiss() }
    }

    private var metadataHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: parsedMetadata == nil ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                .foregroundStyle(parsedMetadata == nil ? BBTheme.Color.destructive : BBTheme.Color.secure)
            VStack(alignment: .leading, spacing: 2) {
                Text(parsedMetadata?.displayName ?? "Invalid metadata block")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(BBTheme.Color.textPrimary)
                if let meta = parsedMetadata {
                    Text("\(meta.matches.count + meta.includes.count) match rules · \(meta.effectiveGrants.count) grants"
                         + (meta.runsInBackground ? " · background" : ""))
                        .font(.caption)
                        .foregroundStyle(BBTheme.Color.textSecondary)
                } else {
                    Text("Add a // ==UserScript== block with at least @name")
                        .font(.caption)
                        .foregroundStyle(BBTheme.Color.textSecondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(BBTheme.Color.chrome)
    }

    private func save() {
        guard parsedMetadata != nil else {
            saveError = "The script needs a valid metadata block with @name."
            return
        }
        Task {
            let success: Bool
            if let existing {
                success = await model.save(scriptID: existing.id, source: source)
            } else {
                success = await model.install(source: source) != nil
            }
            if success {
                dismiss()
            } else {
                saveError = model.errorMessage ?? "Unknown error."
            }
        }
    }

    private static let template = """
    // ==UserScript==
    // @name        New Script
    // @namespace   https://brownbear.app
    // @version     1.0.0
    // @description Describe what this script does
    // @match       *://*/*
    // @grant       none
    // @run-at      document-end
    // ==/UserScript==

    (function () {
      'use strict';
      console.log('Hello from BrownBear');
    })();
    """
}
