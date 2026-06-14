//
//  VerticalTabsPanelViewController.swift
//  BrownBear
//
//  The Orion/Kagi-style vertical-tabs side panel — an alternative to the snapshot grid. It slides in
//  over the page from the chosen edge (the page stays visible behind, dimmed), lists the open tabs as
//  rows (favicon + title + ×), and offers search, edit/reorder, close-all, and a new-tab button. It is
//  presented `.overFullScreen` (the page is NOT torn down) and self-animates its slide, so the page
//  peeks through the scrim exactly like the reference. Reads/writes the shared TabManager, so it can
//  never disagree with the browser chrome behind it.
//

import UIKit

@MainActor
protocol VerticalTabsPanelDelegate: AnyObject {
    func verticalTabsPanel(_ panel: VerticalTabsPanelViewController, didSelect tab: Tab)
    func verticalTabsPanel(_ panel: VerticalTabsPanelViewController, didRequestNewTabPrivate isPrivate: Bool)
    func verticalTabsPanelDidRequestDismiss(_ panel: VerticalTabsPanelViewController)
}

final class VerticalTabsPanelViewController: UIViewController {

    weak var panelDelegate: VerticalTabsPanelDelegate?

    private let tabManager: TabManager
    private let side: VerticalTabsSide
    private var showingPrivate: Bool
    private var searchText = ""
    private var didAnimateIn = false

    private let backdrop = UIView()
    private let panel = UIView()
    private let editButton = UIButton(type: .system)
    private let closeAllButton = UIButton(type: .system)
    private let modeControl = UISegmentedControl(items: ["Tabs", "Private"])
    private let searchBar = UISearchBar()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let backButton = UIButton(type: .system)
    private let countLabel = UILabel()
    private let newTabButton = UIButton(type: .system)

    init(tabManager: TabManager, showingPrivate: Bool, side: VerticalTabsSide) {
        self.tabManager = tabManager
        self.showingPrivate = showingPrivate && tabManager.hasPrivateTabs
        self.side = side
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Tab sets

    /// The current mode's tabs, pinned-first (stable sort preserves order within each group).
    private var displayedTabs: [Tab] {
        let set = showingPrivate ? tabManager.privateTabs : tabManager.normalTabs
        return set.sorted { $0.isPinned && !$1.isPinned }
    }

    /// `displayedTabs` narrowed by the live search text (title + host).
    private var visibleTabs: [Tab] {
        displayedTabs.filter {
            Self.tabMatches(title: $0.state.displayTitle, host: $0.state.url?.host, query: searchText)
        }
    }

    /// Pure title/host match for the tab search. `nonisolated static` so it is unit-testable without the
    /// main actor. An empty query matches everything.
    nonisolated static func tabMatches(title: String, host: String?, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return true }
        if title.lowercased().contains(q) { return true }
        if let host, host.lowercased().contains(q) { return true }
        return false
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        buildBackdrop()
        buildPanel()
        buildHeader()
        buildSearch()
        buildTable()
        buildFooter()
        updateChrome()
        backdrop.alpha = 0
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Lay out so the panel's width is known, then park it off-screen on the chosen edge.
        view.layoutIfNeeded()
        if !didAnimateIn { panel.transform = offscreenTransform() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didAnimateIn else { return }
        didAnimateIn = true
        UIView.animate(withDuration: BrownBearTheme.Motion.sheetSpringDuration, delay: 0,
                       usingSpringWithDamping: BrownBearTheme.Motion.sheetSpringDamping,
                       initialSpringVelocity: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            self.panel.transform = .identity
            self.backdrop.alpha = 1
        }
    }

    private func offscreenTransform() -> CGAffineTransform {
        let width = panel.frame.width > 0 ? panel.frame.width : view.bounds.width
        return CGAffineTransform(translationX: side == .right ? width : -width, y: 0)
    }

    /// Animate the panel back off-screen, then actually dismiss. The browser sets the active tab BEFORE
    /// calling this, so the page is already correct as the panel slides away.
    func dismissPanel(completion: (() -> Void)? = nil) {
        UIView.animate(withDuration: BrownBearTheme.Motion.standard, delay: 0,
                       options: [.curveEaseInOut, .beginFromCurrentState]) {
            self.panel.transform = self.offscreenTransform()
            self.backdrop.alpha = 0
        } completion: { _ in
            self.dismiss(animated: false, completion: completion)
        }
    }

    // MARK: - Build

    private func buildBackdrop() {
        backdrop.backgroundColor = BrownBearTheme.Palette.surfaceScrim
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backdrop)
        backdrop.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapBackdrop)))
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: view.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    private func buildPanel() {
        panel.backgroundColor = BrownBearTheme.Palette.surfaceRaised
        panel.layer.cornerRadius = 18
        panel.layer.cornerCurve = .continuous
        panel.layer.maskedCorners = side == .right
            ? [.layerMinXMinYCorner, .layerMinXMaxYCorner]    // round the left (page-facing) edge
            : [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]    // round the right (page-facing) edge
        panel.layer.shadowColor = UIColor.black.cgColor
        panel.layer.shadowOpacity = 0.22
        panel.layer.shadowRadius = 24
        panel.layer.shadowOffset = CGSize(width: side == .right ? -6 : 6, height: 0)
        panel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panel)

        let width = panel.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.82)
        width.priority = .defaultHigh   // yield to the max-width cap on a wide (iPad) screen
        let edge = side == .right
            ? panel.trailingAnchor.constraint(equalTo: view.trailingAnchor)
            : panel.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: view.topAnchor),
            panel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            edge, width,
            panel.widthAnchor.constraint(lessThanOrEqualToConstant: 460)
        ])
    }

    private func buildHeader() {
        editButton.setTitle("Edit", for: .normal)
        editButton.setTitleColor(BrownBearTheme.Palette.accent, for: .normal)
        editButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        editButton.addTarget(self, action: #selector(tapEdit), for: .touchUpInside)
        editButton.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(editButton)

        closeAllButton.setTitle("Close All", for: .normal)
        closeAllButton.setTitleColor(BrownBearTheme.Palette.destructive, for: .normal)
        closeAllButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        closeAllButton.addTarget(self, action: #selector(tapCloseAll), for: .touchUpInside)
        closeAllButton.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(closeAllButton)

        modeControl.selectedSegmentIndex = showingPrivate ? 1 : 0
        modeControl.selectedSegmentTintColor = BrownBearTheme.Palette.accent
        modeControl.setTitleTextAttributes([.foregroundColor: BrownBearTheme.Palette.onAccent], for: .selected)
        modeControl.setTitleTextAttributes([.foregroundColor: BrownBearTheme.Palette.textPrimary], for: .normal)
        modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        modeControl.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(modeControl)

        let guide = panel.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            editButton.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: BrownBearTheme.Space.l),
            editButton.topAnchor.constraint(equalTo: guide.topAnchor, constant: BrownBearTheme.Space.s),
            editButton.heightAnchor.constraint(equalToConstant: 32),
            closeAllButton.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -BrownBearTheme.Space.l),
            closeAllButton.centerYAnchor.constraint(equalTo: editButton.centerYAnchor),
            modeControl.centerXAnchor.constraint(equalTo: panel.centerXAnchor),
            modeControl.centerYAnchor.constraint(equalTo: editButton.centerYAnchor),
            modeControl.widthAnchor.constraint(equalToConstant: 150)
        ])
    }

    private func buildSearch() {
        searchBar.delegate = self
        searchBar.placeholder = "Search tabs"
        searchBar.searchBarStyle = .minimal
        searchBar.autocapitalizationType = .none
        searchBar.autocorrectionType = .no
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(searchBar)
        NSLayoutConstraint.activate([
            searchBar.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: BrownBearTheme.Space.s),
            searchBar.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -BrownBearTheme.Space.s),
            searchBar.topAnchor.constraint(equalTo: editButton.bottomAnchor, constant: BrownBearTheme.Space.s)
        ])
    }

    private func buildTable() {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.rowHeight = 54
        tableView.keyboardDismissMode = .onDrag
        tableView.register(VerticalTabCell.self, forCellReuseIdentifier: VerticalTabCell.reuseID)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: searchBar.bottomAnchor, constant: BrownBearTheme.Space.xs)
        ])
    }

    private func buildFooter() {
        let footer = UIView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(footer)

        let hairline = UIView()
        hairline.backgroundColor = BrownBearTheme.Palette.borderSubtle
        hairline.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(hairline)

        var backConfig = UIButton.Configuration.plain()
        backConfig.title = "Back"
        backConfig.image = UIImage(systemName: "chevron.backward")
        backConfig.imagePadding = 4
        backConfig.contentInsets = .zero
        backButton.configuration = backConfig
        backButton.tintColor = BrownBearTheme.Palette.accent
        backButton.addTarget(self, action: #selector(tapBack), for: .touchUpInside)
        backButton.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(backButton)

        countLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        countLabel.textColor = BrownBearTheme.Palette.textSecondary
        countLabel.textAlignment = .center
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(countLabel)

        let plusConfig = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        newTabButton.setImage(UIImage(systemName: "plus", withConfiguration: plusConfig), for: .normal)
        newTabButton.tintColor = BrownBearTheme.Palette.accent
        newTabButton.addTarget(self, action: #selector(tapNewTab), for: .touchUpInside)
        newTabButton.menu = makeNewTabMenu()
        newTabButton.showsMenuAsPrimaryAction = false
        newTabButton.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(newTabButton)

        let guide = panel.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            footer.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            footer.topAnchor.constraint(equalTo: tableView.bottomAnchor),
            footer.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 52),

            hairline.topAnchor.constraint(equalTo: footer.topAnchor),
            hairline.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            hairline.heightAnchor.constraint(equalToConstant: BrownBearTheme.Metrics.hairline),

            backButton.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: BrownBearTheme.Space.l),
            backButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            countLabel.centerXAnchor.constraint(equalTo: footer.centerXAnchor),
            countLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            newTabButton.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -BrownBearTheme.Space.l),
            newTabButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            newTabButton.widthAnchor.constraint(equalToConstant: 36),
            newTabButton.heightAnchor.constraint(equalToConstant: 36)
        ])
    }

    /// The +'s long-press menu: New Tab / New Private Tab, plus a Recently Closed submenu — parity with
    /// the grid's button, so private tabs and reopen are reachable even without the mode switcher showing.
    private func makeNewTabMenu() -> UIMenu {
        var children: [UIMenuElement] = [
            UIAction(title: "New Tab", image: UIImage(systemName: "plus.square")) { [weak self] _ in
                guard let self else { return }
                self.panelDelegate?.verticalTabsPanel(self, didRequestNewTabPrivate: false)
            },
            UIAction(title: "New Private Tab", image: UIImage(systemName: "eyeglasses")) { [weak self] _ in
                guard let self else { return }
                self.panelDelegate?.verticalTabsPanel(self, didRequestNewTabPrivate: true)
            }
        ]
        let closed = Array(tabManager.recentlyClosed.prefix(10))
        if !closed.isEmpty {
            let items = closed.map { record -> UIAction in
                let label = record.title.isEmpty ? (record.url.host ?? record.url.absoluteString) : record.title
                return UIAction(title: label) { [weak self] _ in
                    guard let self else { return }
                    self.tabManager.createTab(loading: record.url)
                    self.panelDelegate?.verticalTabsPanelDidRequestDismiss(self)
                }
            }
            children.append(UIMenu(title: "Recently Closed",
                                   image: UIImage(systemName: "clock.arrow.circlepath"),
                                   children: items))
        }
        return UIMenu(children: children)
    }

    // MARK: - State sync

    /// Refresh the count label + mode-switcher visibility after any change. The mode switcher only shows
    /// once a private tab exists, so the common (no-private) case stays a clean Edit / Close All header.
    private func updateChrome() {
        let n = displayedTabs.count
        countLabel.text = "\(n) Tab\(n == 1 ? "" : "s")"
        modeControl.isHidden = !tabManager.hasPrivateTabs
        modeControl.selectedSegmentIndex = showingPrivate ? 1 : 0
        closeAllButton.isHidden = displayedTabs.isEmpty
    }

    private func reload() {
        tableView.reloadData()
        updateChrome()
    }

    /// After a close: if everything's gone, hand back a fresh tab; if only this mode emptied, switch to the
    /// populated one. Otherwise just refresh.
    private func reconcileAfterMutation() {
        if tabManager.isEmpty {
            panelDelegate?.verticalTabsPanel(self, didRequestNewTabPrivate: false)
            return
        }
        if displayedTabs.isEmpty {
            showingPrivate.toggle()
        }
        reload()
    }

    private func closeTab(id: UUID) {
        tabManager.closeTab(id: id)
        reconcileAfterMutation()
    }

    // MARK: - Actions

    @objc private func tapBackdrop() { panelDelegate?.verticalTabsPanelDidRequestDismiss(self) }

    @objc private func tapBack() { panelDelegate?.verticalTabsPanelDidRequestDismiss(self) }

    @objc private func tapNewTab() {
        panelDelegate?.verticalTabsPanel(self, didRequestNewTabPrivate: showingPrivate)
    }

    @objc private func tapEdit() {
        let editing = !tableView.isEditing
        tableView.setEditing(editing, animated: true)
        editButton.setTitle(editing ? "Done" : "Edit", for: .normal)
    }

    @objc private func modeChanged() {
        showingPrivate = (modeControl.selectedSegmentIndex == 1)
        reload()
    }

    @objc private func tapCloseAll() {
        let scope = showingPrivate ? "private " : ""
        let alert = UIAlertController(title: "Close all \(scope)tabs?",
                                      message: "This closes every open \(scope)tab.",
                                      preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Close All", style: .destructive) { [weak self] _ in
            guard let self else { return }
            self.tabManager.closeAll(isPrivate: self.showingPrivate)
            self.reconcileAfterMutation()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.popoverPresentationController?.sourceView = closeAllButton
        alert.popoverPresentationController?.sourceRect = closeAllButton.bounds
        present(alert, animated: true)
    }
}

// MARK: - Table data source / delegate

extension VerticalTabsPanelViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        visibleTabs.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: VerticalTabCell.reuseID, for: indexPath)
        let tabs = visibleTabs
        guard let cell = cell as? VerticalTabCell, indexPath.row < tabs.count else { return cell }
        let tab = tabs[indexPath.row]
        cell.configure(title: tab.state.displayTitle,
                       host: tab.state.url?.host,
                       isActive: tab.id == tabManager.activeTabID,
                       isNewTab: tab.state.url == nil)
        cell.onClose = { [weak self] in self?.closeTab(id: tab.id) }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        let tabs = visibleTabs
        guard indexPath.row < tabs.count else { return }
        panelDelegate?.verticalTabsPanel(self, didSelect: tabs[indexPath.row])
    }

    // Swipe-to-close (always available, even outside edit mode).
    func tableView(_ tableView: UITableView,
                   trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
    -> UISwipeActionsConfiguration? {
        let tabs = visibleTabs
        guard indexPath.row < tabs.count else { return nil }
        let id = tabs[indexPath.row].id
        let close = UIContextualAction(style: .destructive, title: "Close") { [weak self] _, _, done in
            self?.closeTab(id: id)
            done(true)
        }
        close.image = UIImage(systemName: "xmark")
        return UISwipeActionsConfiguration(actions: [close])
    }

    // Edit-mode delete (red minus). Uses .delete so edit mode = reorder grip + delete, the standard list.
    func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath)
    -> UITableViewCell.EditingStyle { .delete }

    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle,
                   forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }
        let tabs = visibleTabs
        guard indexPath.row < tabs.count else { return }
        closeTab(id: tabs[indexPath.row].id)
    }

    // Reorder — only meaningful with no active search (a filtered subset can't be reordered unambiguously).
    func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        var ids = displayedTabs.map(\.id)
        guard sourceIndexPath.row < ids.count else { return }
        let moved = ids.remove(at: sourceIndexPath.row)
        ids.insert(moved, at: min(destinationIndexPath.row, ids.count))
        tabManager.reorderTabs(toMatch: ids)
        updateChrome()
    }
}

// MARK: - UISearchBarDelegate

extension VerticalTabsPanelViewController: UISearchBarDelegate {
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        self.searchText = searchText
        reload()
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }
}
