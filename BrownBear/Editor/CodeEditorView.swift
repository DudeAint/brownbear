//
//  CodeEditorView.swift
//  BrownBear
//
//  SwiftUI wrapper around Runestone's TextView — a performant code editor with line numbers, a
//  gutter, current-line highlight, and auto-closing brackets/quotes. Bridges the editor's text to
//  a SwiftUI binding.
//

import Runestone
import SwiftUI
import TreeSitterJavaScriptRunestone

/// A simple auto-closing pair (brackets, quotes) for the editor.
private struct EditorCharacterPair: CharacterPair {
    let leading: String
    let trailing: String
}

struct CodeEditorView: UIViewRepresentable {

    @Binding var text: String

    func makeUIView(context: Context) -> Runestone.TextView {
        let textView = Runestone.TextView()
        textView.editorDelegate = context.coordinator
        textView.backgroundColor = BrownBearTheme.Palette.background
        textView.showLineNumbers = true
        textView.isLineWrappingEnabled = false
        textView.lineSelectionDisplayType = .line
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.spellCheckingType = .no
        textView.keyboardType = .asciiCapable
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 4, bottom: 12, right: 8)
        textView.characterPairs = [
            EditorCharacterPair(leading: "(", trailing: ")"),
            EditorCharacterPair(leading: "{", trailing: "}"),
            EditorCharacterPair(leading: "[", trailing: "]"),
            EditorCharacterPair(leading: "\"", trailing: "\""),
            EditorCharacterPair(leading: "'", trailing: "'"),
            EditorCharacterPair(leading: "`", trailing: "`")
        ]
        // Attach the JavaScript Tree-sitter grammar so the theme's token colors light up. setState
        // parses off the main thread and applies text + theme + language atomically; subsequent
        // `.text =` writes re-highlight against this language mode.
        let state = TextViewState(text: text, theme: BrownBearEditorTheme(), language: .javaScript)
        textView.setState(state)
        return textView
    }

    func updateUIView(_ textView: Runestone.TextView, context: Context) {
        // Avoid clobbering the user's cursor by only writing when the value genuinely differs.
        if textView.text != text {
            textView.text = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: TextViewDelegate {
        private let text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textViewDidChange(_ textView: Runestone.TextView) {
            text.wrappedValue = textView.text
        }
    }
}
