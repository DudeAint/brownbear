//
//  ScriptInstallViewController.swift
//  BrownBear
//
//  The userscript install card — programmatic UIKit (no SwiftUI). Shown by the browser when a
//  `*.user.js` link is opened and by the dashboard's "Import from URL". It fetches + parses the
//  script (never executing it), lays out its identity, the sites it runs on, the permissions it
//  requests, and a source preview, then installs on confirmation. Replaces the old SwiftUI card.
//
//  Ships two reusable UIKit primitives the dashboard migration also uses: `BBChipView` (a pill) and
//  `BBFlowView` (a self-sizing wrapping row of chips).
//

import UIKit

/// A hand-off target shown in the install sheet's "Install with" picker — a userscript-manager extension
/// that claims this `.user.js`. `route` opens the manager's own install/confirm flow.
struct ScriptInstallTarget {
    let name: String
    let route: @MainActor () -> Void
}

@MainActor
final class ScriptInstallViewController: UIViewController {

    // MARK: - State

    private enum State {
        case loading
        case ready(UserScriptInstaller.Preview)
        case installing
        case installed(name: String, wasUpdate: Bool)
        case failed(String)
    }

    private var state: State = .loading { didSet { renderState() } }

    private let url: URL?
    private let presetSource: String?
    private let installer = UserScriptInstaller.shared
    private let onFinished: (() -> Void)?
    private let onViewSource: ((URL) -> Void)?
    /// Userscript-manager extensions that also claim this URL — shown as "Open in <name>" in the picker.
    private let managerTargets: [ScriptInstallTarget]
    /// Whether to offer BrownBear's own install alongside the managers (false in always-extension mode
    /// when several managers are present, so the sheet picks among extensions only).
    private let showNativeInstall: Bool

    // MARK: - Init

    init(url: URL, managerTargets: [ScriptInstallTarget] = [], showNativeInstall: Bool = true,
         onFinished: (() -> Void)? = nil, onViewSource: ((URL) -> Void)? = nil) {
        self.url = url
        self.presetSource = nil
        self.managerTargets = managerTargets
        self.showNativeInstall = showNativeInstall
        self.onFinished = onFinished
        self.onViewSource = onViewSource
        super.init(nibName: nil, bundle: nil)
    }

    init(source: String, url: URL? = nil, onFinished: (() -> Void)? = nil) {
        self.url = url
        self.presetSource = source
        self.managerTargets = []
        self.showNativeInstall = true
        self.onFinished = onFinished
        self.onViewSource = nil
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - Views

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let actionBar = UIStackView()
    private let urlFootnote = UILabel()
    private let centerStatusStack = UIStackView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let statusTitle = UILabel()
    private let statusSubtitle = UILabel()
    // Built only in the no-manager path (the manager-picker path puts Install in the "Install with" card and
    // omits the bottom-bar button) — so it's an Optional, not a lazy var that would allocate a never-shown
    // button the first time the property is touched on the picker path.
    private var installButton: UIButton?
    private var sourceTextView: UITextView?
    private var sourceExpanded = false

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BrownBearTheme.Palette.background
        title = "Install Script"
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(close))
        buildLayout()
        renderState()
        Task { await load() }
    }

    @objc private func close() {
        dismiss(animated: true) { [onFinished] in onFinished?() }
    }

    // MARK: - Data

    private func load() async {
        state = .loading
        do {
            let preview: UserScriptInstaller.Preview
            if let presetSource {
                preview = try await installer.makePreview(source: presetSource, url: url)
            } else if let url {
                preview = try await installer.preview(url: url)
            } else {
                throw BrownBearError.metadataParseFailed("there's nothing to install")
            }
            state = .ready(preview)
        } catch {
            state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func install(_ preview: UserScriptInstaller.Preview) async {
        let wasUpdate = preview.isUpdate
        state = .installing
        do {
            let script = try await installer.install(preview)
            state = .installed(name: script.displayName, wasUpdate: wasUpdate)
        } catch {
            state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    // MARK: - Layout scaffold

    private func buildLayout() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        view.addSubview(scrollView)

        contentStack.axis = .vertical
        contentStack.spacing = 16
        contentStack.alignment = .fill
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)

        actionBar.axis = .horizontal
        actionBar.spacing = 12
        actionBar.distribution = .fill
        actionBar.alignment = .fill
        actionBar.translatesAutoresizingMaskIntoConstraints = false
        let actionBarBackground = UIView()
        actionBarBackground.backgroundColor = BrownBearTheme.Palette.chrome
        actionBarBackground.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(actionBarBackground)

        urlFootnote.font = .systemFont(ofSize: 11)
        urlFootnote.textColor = BrownBearTheme.Palette.textSecondary
        urlFootnote.lineBreakMode = .byTruncatingMiddle
        urlFootnote.translatesAutoresizingMaskIntoConstraints = false

        let barStack = UIStackView(arrangedSubviews: [urlFootnote, actionBar])
        barStack.axis = .vertical
        barStack.spacing = 8
        barStack.translatesAutoresizingMaskIntoConstraints = false
        actionBarBackground.addSubview(barStack)

        // Center status (loading / failed / installed).
        centerStatusStack.axis = .vertical
        centerStatusStack.spacing = 12
        centerStatusStack.alignment = .center
        centerStatusStack.translatesAutoresizingMaskIntoConstraints = false
        statusTitle.font = .systemFont(ofSize: 17, weight: .semibold)
        statusTitle.textColor = BrownBearTheme.Palette.textPrimary
        statusTitle.textAlignment = .center
        statusSubtitle.font = .systemFont(ofSize: 14)
        statusSubtitle.textColor = BrownBearTheme.Palette.textSecondary
        statusSubtitle.textAlignment = .center
        statusSubtitle.numberOfLines = 0
        spinner.color = BrownBearTheme.Palette.accent
        centerStatusStack.addArrangedSubview(spinner)
        centerStatusStack.addArrangedSubview(statusTitle)
        centerStatusStack.addArrangedSubview(statusSubtitle)
        view.addSubview(centerStatusStack)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: guide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: actionBarBackground.topAnchor),

            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 16),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -16),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -16),

            actionBarBackground.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            actionBarBackground.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            actionBarBackground.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            barStack.topAnchor.constraint(equalTo: actionBarBackground.topAnchor, constant: 10),
            barStack.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -8),
            barStack.leadingAnchor.constraint(equalTo: actionBarBackground.leadingAnchor, constant: 16),
            barStack.trailingAnchor.constraint(equalTo: actionBarBackground.trailingAnchor, constant: -16),

            centerStatusStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            centerStatusStack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            centerStatusStack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            centerStatusStack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32)
        ])
        self.actionBarBackground = actionBarBackground
    }

    private var actionBarBackground = UIView()

    // MARK: - Render

    private func renderState() {
        guard isViewLoaded else { return }
        switch state {
        case .loading:
            showStatus(spinner: true, title: "Reading script…", subtitle: url?.host)
        case .installing:
            showStatus(spinner: true, title: "Installing…", subtitle: nil)
        case .failed(let message):
            showStatus(spinner: false, title: "Couldn’t read the script", subtitle: message, isError: true)
        case .installed(let name, let wasUpdate):
            showStatus(spinner: false, title: wasUpdate ? "Updated" : "Installed", subtitle: name, isSuccess: true)
        case .ready(let preview):
            showPreview(preview)
        }
    }

    private func showStatus(spinner showSpinner: Bool, title: String, subtitle: String?,
                            isError: Bool = false, isSuccess: Bool = false) {
        scrollView.isHidden = true
        actionBarBackground.isHidden = !(isError || isSuccess)
        centerStatusStack.isHidden = false
        if showSpinner { spinner.startAnimating() } else { spinner.stopAnimating() }
        spinner.isHidden = !showSpinner
        statusTitle.text = title
        statusSubtitle.text = subtitle
        statusSubtitle.isHidden = (subtitle == nil)

        // Reconfigure the action bar for terminal states.
        actionBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        urlFootnote.isHidden = true
        if isError {
            actionBar.addArrangedSubview(makeBorderedButton(title: "Close", action: #selector(close)))
            actionBar.addArrangedSubview(makeFilledButton(title: "Retry", action: #selector(retry)))
        } else if isSuccess {
            actionBar.addArrangedSubview(makeFilledButton(title: "Done", action: #selector(close)))
        }
    }

    private func showPreview(_ preview: UserScriptInstaller.Preview) {
        centerStatusStack.isHidden = true
        spinner.stopAnimating()
        scrollView.isHidden = false
        actionBarBackground.isHidden = false

        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let meta = preview.metadata

        contentStack.addArrangedSubview(makeHero(preview))
        if let description = meta.descriptionText, !description.isEmpty {
            contentStack.addArrangedSubview(makeBodyLabel(description))
        }
        if !managerTargets.isEmpty {
            contentStack.addArrangedSubview(makeInstallTargetsCard(preview))
        }
        contentStack.addArrangedSubview(makeStatStrip(preview))
        contentStack.addArrangedSubview(makeRunsOnCard(preview))
        contentStack.addArrangedSubview(makePermissionsCard(preview))
        if !meta.connects.isEmpty {
            let connectChips = meta.connects.map {
                BBChipView(text: $0, systemImage: "arrow.up.right", tint: BrownBearTheme.Palette.secure)
            }
            contentStack.addArrangedSubview(makeChipCard(title: "Network access", systemImage: "network", chips: connectChips))
        }
        let bundled = preview.metadata.requires.count + preview.metadata.resources.count
        if bundled > 0 {
            var chips: [BBChipView] = []
            if !meta.requires.isEmpty { chips.append(BBChipView(text: "\(meta.requires.count) @require", systemImage: "link")) }
            if !meta.resources.isEmpty { chips.append(BBChipView(text: "\(meta.resources.count) @resource", systemImage: "doc")) }
            contentStack.addArrangedSubview(makeChipCard(title: "Bundled assets", systemImage: "shippingbox.fill", chips: chips))
        }
        contentStack.addArrangedSubview(makeSourceCard(preview))

        // Action bar.
        actionBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        actionBar.addArrangedSubview(makeBorderedButton(title: "Cancel", action: #selector(close)))
        if preview.sourceURL != nil, onViewSource != nil {
            let viewSource = makeBorderedButton(symbol: "doc.plaintext", action: #selector(viewSourceTapped))
            actionBar.addArrangedSubview(viewSource)
        }
        // With manager targets the install/hand-off choices live in the "Install with" card, so the bar
        // is just Cancel (+ View source); without, it carries the primary Install button.
        if managerTargets.isEmpty {
            let button = makeFilledButton(title: preview.isUpdate ? "Update" : "Install", action: #selector(installTapped))
            installButton = button
            actionBar.addArrangedSubview(button)
        }

        if let sourceURL = preview.sourceURL {
            urlFootnote.text = sourceURL.absoluteString
            urlFootnote.isHidden = false
        } else {
            urlFootnote.isHidden = true
        }
        readyPreview = preview
    }

    private var readyPreview: UserScriptInstaller.Preview?

    // MARK: - Actions

    @objc private func retry() { Task { await load() } }

    @objc private func installTapped() {
        guard let preview = readyPreview else { return }
        Task { await install(preview) }
    }

    @objc private func viewSourceTapped() {
        guard let sourceURL = readyPreview?.sourceURL, let onViewSource else { return }
        dismiss(animated: true) { onViewSource(sourceURL) }
    }

    @objc private func toggleSource() {
        sourceExpanded.toggle()
        sourceTextView?.isHidden = !sourceExpanded
    }

}

// MARK: - Section builders (extension keeps the main type body small)

extension ScriptInstallViewController {

    private func makeHero(_ preview: UserScriptInstaller.Preview) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: "scroll.fill"))
        icon.tintColor = .white
        icon.contentMode = .center
        icon.backgroundColor = BrownBearTheme.Palette.accent
        icon.layer.cornerRadius = 14
        icon.layer.cornerCurve = .continuous
        icon.clipsToBounds = true
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 56), icon.heightAnchor.constraint(equalToConstant: 56)])

        // Swap in the script's own @icon once it loads; keep the brand glyph as the fallback.
        if let iconURL = preview.metadata.iconURL {
            Task { @MainActor in
                if let image = await ScriptIconLoader.shared.icon(forURLString: iconURL) {
                    icon.image = image
                    icon.contentMode = .scaleAspectFill
                    icon.backgroundColor = .clear
                }
            }
        }

        let name = UILabel()
        name.text = preview.metadata.displayName
        name.font = .systemFont(ofSize: 20, weight: .bold)
        name.textColor = BrownBearTheme.Palette.textPrimary
        name.numberOfLines = 2

        let subtitle = UILabel()
        var parts: [String] = []
        if let v = preview.metadata.version, !v.isEmpty { parts.append("v\(v)") }
        if let a = preview.metadata.author, !a.isEmpty { parts.append(a) }
        subtitle.text = parts.joined(separator: "  ·  ")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = BrownBearTheme.Palette.textSecondary

        let textStack = UIStackView(arrangedSubviews: [name, subtitle])
        textStack.axis = .vertical
        textStack.spacing = 4
        if preview.isUpdate {
            let from = preview.existingVersion.map { "v\($0)" } ?? "installed"
            let to = preview.metadata.version.map { "v\($0)" } ?? "new"
            let badge = BBChipView(text: "Update \(from) → \(to)",
                                   systemImage: "arrow.triangle.2.circlepath",
                                   tint: BrownBearTheme.Palette.secure)
            textStack.addArrangedSubview(badge)
        }

        let hero = UIStackView(arrangedSubviews: [icon, textStack])
        hero.axis = .horizontal
        hero.spacing = 14
        hero.alignment = .top
        return hero
    }

    private func makeStatStrip(_ preview: UserScriptInstaller.Preview) -> UIView {
        let stat: (String, String) -> UIView = { value, label in
            let v = UILabel()
            v.text = value; v.font = .systemFont(ofSize: 15, weight: .bold)
            v.textColor = BrownBearTheme.Palette.textPrimary; v.textAlignment = .center
            let l = UILabel()
            l.text = label; l.font = .systemFont(ofSize: 11)
            l.textColor = BrownBearTheme.Palette.textSecondary; l.textAlignment = .center
            let s = UIStackView(arrangedSubviews: [v, l]); s.axis = .vertical; s.spacing = 2; s.alignment = .center
            let card = UIView(); card.backgroundColor = BrownBearTheme.Palette.cell; card.layer.cornerRadius = 12; card.layer.cornerCurve = .continuous
            s.translatesAutoresizingMaskIntoConstraints = false; card.addSubview(s)
            NSLayoutConstraint.activate([
                s.topAnchor.constraint(equalTo: card.topAnchor, constant: 10), s.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
                s.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 8), s.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8)
            ])
            return card
        }
        let runAt: String
        switch preview.metadata.runAt {
        case .documentStart: runAt = "start"
        case .documentEnd: runAt = "end"
        case .documentIdle: runAt = "idle"
        }
        let row = UIStackView(arrangedSubviews: [stat("\(preview.lineCount)", "lines"), stat(byteString(preview.byteCount), "size"), stat(runAt, "runs at")])
        row.axis = .horizontal; row.spacing = 10; row.distribution = .fillEqually
        return row
    }

    private func makeRunsOnCard(_ preview: UserScriptInstaller.Preview) -> UIView {
        let patterns = preview.metadata.matches + preview.metadata.includes
        if preview.runsOnNoPages {
            return makeNoteCard(title: "Runs on", systemImage: "globe",
                                note: "No @match — this script won’t run on any page until you add one.",
                                tint: BrownBearTheme.Palette.destructive)
        }
        if patterns.isEmpty && preview.metadata.runsInBackground {
            return makeNoteCard(title: "Runs on", systemImage: "globe",
                                note: "Runs in the background (schedule/@background), not on pages.",
                                tint: BrownBearTheme.Palette.textSecondary)
        }
        return makeChipCard(title: "Runs on", systemImage: "globe",
                            chips: patterns.map { BBChipView(text: $0, tint: BrownBearTheme.Palette.accent) })
    }

    private func makePermissionsCard(_ preview: UserScriptInstaller.Preview) -> UIView {
        if preview.metadata.grantsNone {
            return makeNoteCard(title: "Permissions", systemImage: "key.fill",
                                note: "@grant none — runs with no privileged GM APIs.", tint: BrownBearTheme.Palette.textSecondary)
        }
        if preview.metadata.grants.isEmpty {
            return makeNoteCard(title: "Permissions", systemImage: "key.fill",
                                note: "No special permissions requested.", tint: BrownBearTheme.Palette.textSecondary)
        }
        return makeChipCard(title: "Permissions", systemImage: "key.fill",
                            chips: preview.metadata.grants.map { BBChipView(text: $0, systemImage: "key", tint: BrownBearTheme.Palette.accent) })
    }

    private func makeSourceCard(_ preview: UserScriptInstaller.Preview) -> UIView {
        let card = cardContainer()
        let header = sectionHeader(title: "Source", systemImage: "chevron.left.forwardslash.chevron.right")
        let toggle = UIButton(type: .system)
        toggle.setTitle("Show source (\(preview.lineCount) lines)", for: .normal)
        toggle.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        toggle.tintColor = BrownBearTheme.Palette.accent
        toggle.contentHorizontalAlignment = .leading
        toggle.addTarget(self, action: #selector(toggleSource), for: .touchUpInside)

        let text = UITextView()
        text.text = preview.source
        text.isEditable = false
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.textColor = BrownBearTheme.Palette.textSecondary
        text.backgroundColor = .clear
        text.isHidden = true
        text.translatesAutoresizingMaskIntoConstraints = false
        text.heightAnchor.constraint(equalToConstant: 220).isActive = true
        sourceTextView = text
        sourceExpanded = false

        let stack = UIStackView(arrangedSubviews: [header, toggle, text])
        stack.axis = .vertical; stack.spacing = 8
        embed(stack, in: card)
        return card
    }

    // MARK: - Card primitives

    private func makeChipCard(title: String, systemImage: String, chips: [BBChipView]) -> UIView {
        let card = cardContainer()
        let header = sectionHeader(title: title, systemImage: systemImage)
        let flow = BBFlowView()
        flow.setChips(chips)
        let stack = UIStackView(arrangedSubviews: [header, flow])
        stack.axis = .vertical; stack.spacing = 10
        embed(stack, in: card)
        return card
    }

    private func makeNoteCard(title: String, systemImage: String, note: String, tint: UIColor) -> UIView {
        let card = cardContainer()
        let header = sectionHeader(title: title, systemImage: systemImage)
        let label = UILabel()
        label.text = note; label.font = .systemFont(ofSize: 13); label.textColor = tint; label.numberOfLines = 0
        let stack = UIStackView(arrangedSubviews: [header, label])
        stack.axis = .vertical; stack.spacing = 8
        embed(stack, in: card)
        return card
    }

    private func cardContainer() -> UIView {
        let card = UIView()
        card.backgroundColor = BrownBearTheme.Palette.cell
        card.layer.cornerRadius = BrownBearTheme.Metrics.cellCornerRadius
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 0.5
        card.layer.borderColor = BrownBearTheme.Palette.separator.cgColor
        return card
    }

    private func embed(_ subview: UIView, in card: UIView) {
        subview.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(subview)
        NSLayoutConstraint.activate([
            subview.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            subview.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
            subview.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            subview.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14)
        ])
    }

    private func sectionHeader(title: String, systemImage: String) -> UIView {
        let image = UIImageView(image: UIImage(systemName: systemImage))
        image.tintColor = BrownBearTheme.Palette.textSecondary
        image.contentMode = .scaleAspectFit
        image.setContentHuggingPriority(.required, for: .horizontal)
        let label = UILabel()
        label.text = title.uppercased()
        label.font = .systemFont(ofSize: 12, weight: .bold)
        label.textColor = BrownBearTheme.Palette.textSecondary
        let stack = UIStackView(arrangedSubviews: [image, label])
        stack.axis = .horizontal; stack.spacing = 6; stack.alignment = .center
        return stack
    }

    private func makeBodyLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text; label.font = .systemFont(ofSize: 14); label.textColor = BrownBearTheme.Palette.textSecondary; label.numberOfLines = 0
        return label
    }

    // MARK: - Buttons

    private func makeFilledButton(title: String, action: Selector? = nil) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.baseBackgroundColor = BrownBearTheme.Palette.accent
        config.baseForegroundColor = .white
        config.cornerStyle = .large
        config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
        let button = UIButton(configuration: config)
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        if let action { button.addTarget(self, action: action, for: .touchUpInside) }
        return button
    }

    private func makeBorderedButton(title: String? = nil, symbol: String? = nil, action: Selector) -> UIButton {
        var config = UIButton.Configuration.gray()
        config.title = title
        if let symbol { config.image = UIImage(systemName: symbol) }
        config.baseForegroundColor = BrownBearTheme.Palette.textSecondary
        config.cornerStyle = .large
        config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
        let button = UIButton(configuration: config)
        button.addTarget(self, action: action, for: .touchUpInside)
        if title == nil { button.setContentHuggingPriority(.required, for: .horizontal) }
        return button
    }

    /// The "Install with" picker card: a full-width button per install target. BrownBear's own install is
    /// the primary (filled) action; each userscript-manager extension is an "Open in <name>" hand-off.
    private func makeInstallTargetsCard(_ preview: UserScriptInstaller.Preview) -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 10

        let heading = UILabel()
        heading.text = "Install with"
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        heading.textColor = BrownBearTheme.Palette.textSecondary
        stack.addArrangedSubview(heading)

        if showNativeInstall {
            let title = preview.isUpdate ? "Update in BrownBear" : "Install in BrownBear"
            stack.addArrangedSubview(makeTargetButton(title: title, systemImage: "scroll.fill", filled: true) { [weak self] in
                self?.installTapped()
            })
        }
        for target in managerTargets {
            stack.addArrangedSubview(makeTargetButton(title: "Open in \(target.name)",
                                                      systemImage: "puzzlepiece.extension.fill", filled: false) { [weak self] in
                self?.dismiss(animated: true) { target.route() }
            })
        }
        return stack
    }

    private func makeTargetButton(title: String, systemImage: String, filled: Bool,
                                  handler: @escaping @MainActor () -> Void) -> UIButton {
        var config = filled ? UIButton.Configuration.filled() : UIButton.Configuration.gray()
        config.title = title
        config.image = UIImage(systemName: systemImage)
        config.imagePadding = 8
        config.cornerStyle = .large
        config.contentInsets = NSDirectionalEdgeInsets(top: 13, leading: 16, bottom: 13, trailing: 16)
        if filled {
            config.baseBackgroundColor = BrownBearTheme.Palette.accent
            config.baseForegroundColor = .white
        } else {
            config.baseForegroundColor = BrownBearTheme.Palette.textPrimary
        }
        let button = UIButton(configuration: config, primaryAction: UIAction { _ in handler() })
        button.contentHorizontalAlignment = .leading
        return button
    }

    private func byteString(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.0f KB", kb) }
        return String(format: "%.1f MB", kb / 1024)
    }

    // MARK: - Presentation

    /// Wrap in a navigation controller with grabber + medium/large detents, ready to present.
    func wrappedForPresentation() -> UIViewController {
        let nav = UINavigationController(rootViewController: self)
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 24
        }
        return nav
    }
}

// MARK: - Reusable UIKit primitives

/// A pill/chip: capsule background, optional leading SF Symbol, tinted text.
final class BBChipView: UIView {
    init(text: String, systemImage: String? = nil, tint: UIColor = BrownBearTheme.Palette.accent) {
        super.init(frame: .zero)
        backgroundColor = tint.withAlphaComponent(0.14)
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = tint
        let arranged: [UIView]
        if let systemImage {
            let image = UIImageView(image: UIImage(systemName: systemImage,
                                                   withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .semibold)))
            image.tintColor = tint
            image.contentMode = .scaleAspectFit
            arranged = [image, label]
        } else {
            arranged = [label]
        }
        let stack = UIStackView(arrangedSubviews: arranged)
        stack.axis = .horizontal; stack.spacing = 4; stack.alignment = .center
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }
}

/// A self-sizing view that lays its subviews out left-to-right, wrapping to new rows, and reports
/// the resulting height back to Auto Layout. Used for chip rows.
final class BBFlowView: UIView {
    var horizontalSpacing: CGFloat = 6
    var verticalSpacing: CGFloat = 6
    private var chips: [UIView] = []
    private lazy var heightConstraint: NSLayoutConstraint = {
        let c = heightAnchor.constraint(equalToConstant: 0)
        c.priority = .defaultHigh
        c.isActive = true
        return c
    }()

    func setChips(_ views: [UIView]) {
        chips.forEach { $0.removeFromSuperview() }
        chips = views
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let maxWidth = bounds.width
        guard maxWidth > 0 else { return }
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for chip in chips {
            let size = chip.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
            if x > 0 && x + size.width > maxWidth {
                x = 0; y += rowHeight + verticalSpacing; rowHeight = 0
            }
            chip.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
        let total = y + rowHeight
        if abs(heightConstraint.constant - total) > 0.5 { heightConstraint.constant = total }
    }
}
