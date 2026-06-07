//
//  KeyboardAccessoryBar.swift
//  BrownBear
//
//  The code editor's keyboard accessory bar: quick-insert keys for the punctuation that's painful to
//  reach on the iOS keyboard while writing JavaScript, plus Find and dismiss-keyboard actions. Pure
//  UIKit; the owner (CodeEditorView) wires the three closures to its Runestone TextView.
//

import UIKit

final class KeyboardAccessoryBar: UIView {

    private let onInsert: (String) -> Void
    private let onFind: () -> Void
    private let onDismiss: () -> Void

    /// Punctuation offered in the scrollable middle section, in tap order. The first is the indent
    /// key (a real tab); the rest are the brackets/operators/quotes JS uses constantly.
    private static let snippets: [(label: String, insert: String)] = [
        ("⇥", "\t"), ("{", "{"), ("}", "}"), ("(", "("), (")", ")"),
        ("[", "["), ("]", "]"), ("<", "<"), (">", ">"), ("=", "="),
        (";", ";"), (":", ":"), ("\"", "\""), ("'", "'"), ("`", "`"),
        ("/", "/"), ("\\", "\\"), ("|", "|"), ("&", "&"), ("$", "$"),
        (".", "."), ("-", "-"), ("_", "_")
    ]

    init(onInsert: @escaping (String) -> Void,
         onFind: @escaping () -> Void,
         onDismiss: @escaping () -> Void) {
        self.onInsert = onInsert
        self.onFind = onFind
        self.onDismiss = onDismiss
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 44))
        autoresizingMask = .flexibleWidth
        backgroundColor = BrownBearTheme.Palette.chrome
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 44)
    }

    private func build() {
        let find = makeSymbolButton("magnifyingglass") { [weak self] in self?.onFind() }
        let dismiss = makeSymbolButton("keyboard.chevron.compact.down") { [weak self] in self?.onDismiss() }

        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        for snippet in Self.snippets {
            stack.addArrangedSubview(makeKeyButton(title: snippet.label, insert: snippet.insert))
        }
        scroll.addSubview(stack)

        let separator = UIView()
        separator.backgroundColor = BrownBearTheme.Palette.borderSubtle
        separator.translatesAutoresizingMaskIntoConstraints = false

        find.translatesAutoresizingMaskIntoConstraints = false
        dismiss.translatesAutoresizingMaskIntoConstraints = false
        [separator, find, dismiss, scroll].forEach(addSubview)

        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: BrownBearTheme.Metrics.hairline),

            find.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            find.centerYAnchor.constraint(equalTo: centerYAnchor),
            find.widthAnchor.constraint(equalToConstant: 40),

            dismiss.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            dismiss.centerYAnchor.constraint(equalTo: centerYAnchor),
            dismiss.widthAnchor.constraint(equalToConstant: 40),

            scroll.leadingAnchor.constraint(equalTo: find.trailingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: dismiss.leadingAnchor, constant: -4),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerYAnchor),
            stack.heightAnchor.constraint(equalToConstant: 34)
        ])
    }

    private func makeKeyButton(title: String, insert: String) -> UIButton {
        var config = UIButton.Configuration.gray()
        config.title = title
        config.baseForegroundColor = BrownBearTheme.Palette.textPrimary
        config.cornerStyle = .medium
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
        let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
            self?.onInsert(insert)
        })
        button.titleLabel?.font = .monospacedSystemFont(ofSize: 17, weight: .medium)
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 38).isActive = true
        return button
    }

    private func makeSymbolButton(_ symbol: String, action: @escaping () -> Void) -> UIButton {
        let config = UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        let button = UIButton(type: .system, primaryAction: UIAction { _ in action() })
        button.setImage(UIImage(systemName: symbol, withConfiguration: config), for: .normal)
        button.tintColor = BrownBearTheme.Palette.accent
        return button
    }
}
