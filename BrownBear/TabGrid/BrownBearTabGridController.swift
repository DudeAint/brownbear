//
//  BrownBearTabGridController.swift
//  BrownBear
//
//  The Chromium-style square tab grid. It renders the open tabs as a two-column grid of
//  snapshot cards, supports selecting, closing individual tabs, opening a new tab, and closing
//  all. It reads/writes the shared TabManager and re-applies its own snapshot after each
//  mutation so it always agrees with the browser chrome.
//

import UIKit

@MainActor
protocol BrownBearTabGridControllerDelegate: AnyObject {
    func tabGrid(_ controller: BrownBearTabGridController, didSelect tab: Tab)
    func tabGrid(_ controller: BrownBearTabGridController, didRequestNewTabPrivate isPrivate: Bool)
    func tabGridDidRequestDismiss(_ controller: BrownBearTabGridController)
}

final class BrownBearTabGridController: UIViewController {

    weak var gridDelegate: BrownBearTabGridControllerDelegate?

    private let tabManager: TabManager
    private let header = UIView()
    private let titleLabel = UILabel()
    private let modeControl = UISegmentedControl(items: ["Tabs", "Private"])
    private let doneButton = UIButton(type: .system)
    private let closeAllButton = UIButton(type: .system)
    private let newTabButton = UIButton(type: .system)
    private let searchBar = UISearchBar()

    /// Live tab-search text; filters the visible cards by title + host.
    private var searchText = ""

    /// Set once the user drags the grid or types in tab-search, so the open-time auto-center stops fighting
    /// them. Until then we re-center on the active tab on EVERY layout pass (the present transition lays out
    /// several times, and a single shot during it can land on a not-yet-real content size → stuck at top).
    private var userInteractedWithGrid = false

    /// Which set the grid is showing. Private mode is only reachable once a private tab exists or the
    /// user explicitly switches to it; it persists while the grid is open.
    private var showingPrivate: Bool

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, UUID>!

    /// Snapshot + on-screen frame (window coordinates) of the card the user just tapped, captured at
    /// selection time so the browser's hero transition can expand exactly that card into the full page.
    /// Read once by the browser right after `didSelect`, then it presents/dismisses.
    private(set) var selectedCardImage: UIImage?
    private(set) var selectedCardFrame: CGRect = .zero

    /// The tabs currently displayed, scoped to the active mode.
    private var displayedTabs: [Tab] { showingPrivate ? tabManager.privateTabs : tabManager.normalTabs }

    init(tabManager: TabManager, showingPrivate: Bool = false) {
        self.tabManager = tabManager
        self.showingPrivate = showingPrivate && tabManager.hasPrivateTabs
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BrownBearTheme.Palette.background
        buildHeader()
        buildCollectionView()
        configureDataSource()
        applySnapshot(animatingDifferences: false)
        updateTitle()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        updateItemSize()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        centerOnActiveTab()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // The present transition can finish without firing another layout pass, so run one authoritative
        // center on the next runloop once everything has settled. Still gated on user interaction.
        DispatchQueue.main.async { [weak self] in self?.centerOnActiveTab() }
    }

    /// Keep the grid centered on the active tab UNTIL the user touches it. Re-running on every layout pass
    /// (rather than once) is what makes it reliable: the open transition lays the grid out several times,
    /// and a single early scroll lands on a not-yet-real content size and clamps to the top. scrollToItem
    /// is idempotent, so repeating it once centered costs nothing.
    private func centerOnActiveTab() {
        guard !userInteractedWithGrid,
              collectionView.bounds.height > 0,
              let activeID = tabManager.activeTabID,
              let indexPath = dataSource.indexPath(for: activeID) else { return }
        collectionView.layoutIfNeeded()   // resolve any pending item-size invalidation → real contentSize
        let contentHeight = collectionView.collectionViewLayout.collectionViewContentSize.height
        // If the whole grid already fits, the active card is on screen — nothing to scroll.
        guard contentHeight > collectionView.bounds.height else { return }
        collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
    }

    // MARK: - Header

    private func buildHeader() {
        header.backgroundColor = BrownBearTheme.Palette.background
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)

        titleLabel.font = BrownBearTheme.Typography.sectionTitle()
        titleLabel.textColor = BrownBearTheme.Palette.textPrimary
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(titleLabel)

        // Normal / Private switcher, shown only once a private tab exists so the chrome stays simple
        // for users who never open one.
        modeControl.selectedSegmentIndex = showingPrivate ? 1 : 0
        modeControl.selectedSegmentTintColor = BrownBearTheme.Palette.accent
        // The selected segment sits on the accent fill (near-black in light mode, near-WHITE in dark mode),
        // so its label must use the contrasting on-accent colour or it goes invisible (white-on-white in
        // dark, dark-on-dark in light). Unselected segments use the normal text colour over the control's
        // default fill. Default UISegmentedControl text is `label`, which only contrasts in one mode.
        modeControl.setTitleTextAttributes([.foregroundColor: BrownBearTheme.Palette.onAccent], for: .selected)
        modeControl.setTitleTextAttributes([.foregroundColor: BrownBearTheme.Palette.textPrimary], for: .normal)
        modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        modeControl.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(modeControl)

        closeAllButton.setTitle("Close All", for: .normal)
        closeAllButton.setTitleColor(BrownBearTheme.Palette.destructive, for: .normal)
        closeAllButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        closeAllButton.addTarget(self, action: #selector(tapCloseAll), for: .touchUpInside)
        closeAllButton.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(closeAllButton)

        doneButton.setTitle("Done", for: .normal)
        doneButton.setTitleColor(BrownBearTheme.Palette.accent, for: .normal)
        doneButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        doneButton.addTarget(self, action: #selector(tapDone), for: .touchUpInside)
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(doneButton)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            header.topAnchor.constraint(equalTo: guide.topAnchor),
            header.heightAnchor.constraint(equalToConstant: 48),

            closeAllButton.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            closeAllButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            titleLabel.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            modeControl.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            modeControl.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            modeControl.widthAnchor.constraint(equalToConstant: 184),

            doneButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
            doneButton.centerYAnchor.constraint(equalTo: header.centerYAnchor)
        ])
    }

    // MARK: - Collection view

    private func buildCollectionView() {
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = BrownBearTheme.Metrics.tabGridSpacing
        layout.minimumLineSpacing = BrownBearTheme.Metrics.tabGridSpacing
        let inset = BrownBearTheme.Metrics.tabGridInset
        layout.sectionInset = UIEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.delegate = self
        // Drag-to-reorder (Safari/Files style). Drag & drop coexists with the cells' long-press
        // context menu — UIKit disambiguates hold-still (menu) from lift-and-move (drag) — whereas an
        // interactive-movement long-press recognizer would fight the menu's gesture.
        collectionView.dragInteractionEnabled = true
        collectionView.dragDelegate = self
        collectionView.dropDelegate = self
        collectionView.register(TabGridCell.self, forCellWithReuseIdentifier: TabGridCell.reuseID)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)

        // A prominent "+" button floats at the bottom, Chrome-style.
        let plusConfig = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        newTabButton.setImage(UIImage(systemName: "plus", withConfiguration: plusConfig), for: .normal)
        // On-accent foreground (not hardcoded white): the accent fill is near-white in dark mode, where a
        // white "+" would be invisible. onAccent is white in light mode, near-black in dark mode.
        newTabButton.tintColor = BrownBearTheme.Palette.onAccent
        newTabButton.backgroundColor = BrownBearTheme.Palette.accent
        newTabButton.layer.cornerRadius = 28
        newTabButton.layer.shadowColor = UIColor.black.cgColor
        newTabButton.layer.shadowOpacity = 0.25
        newTabButton.layer.shadowRadius = 10
        newTabButton.layer.shadowOffset = CGSize(width: 0, height: 4)
        newTabButton.addTarget(self, action: #selector(tapNewTab), for: .touchUpInside)
        // Tap = new tab in the current mode; long-press = pick New Tab / New Private Tab, plus a
        // Recently Closed submenu to reopen a tab you closed by accident.
        newTabButton.menu = makeNewTabMenu()
        newTabButton.showsMenuAsPrimaryAction = false
        newTabButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(newTabButton)

        // Tab search (Safari/Firefox tab-tray search): filters the grid by title + host as you type.
        searchBar.delegate = self
        searchBar.placeholder = "Search tabs"
        searchBar.searchBarStyle = .minimal
        searchBar.autocapitalizationType = .none
        searchBar.autocorrectionType = .no
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(searchBar)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            searchBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            searchBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            searchBar.topAnchor.constraint(equalTo: header.bottomAnchor),

            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            newTabButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            newTabButton.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -16),
            newTabButton.widthAnchor.constraint(equalToConstant: 56),
            newTabButton.heightAnchor.constraint(equalToConstant: 56)
        ])
    }

    /// The + button's long-press menu: New Tab / New Private Tab, plus a Recently Closed submenu to
    /// reopen accidentally-closed tabs (built from TabManager's bounded history).
    private func makeNewTabMenu() -> UIMenu {
        var children: [UIMenuElement] = [
            UIAction(title: "New Tab", image: UIImage(systemName: "plus.square")) { [weak self] _ in
                guard let self else { return }
                self.gridDelegate?.tabGrid(self, didRequestNewTabPrivate: false)
            },
            UIAction(title: "New Private Tab", image: UIImage(systemName: "eyeglasses")) { [weak self] _ in
                guard let self else { return }
                self.gridDelegate?.tabGrid(self, didRequestNewTabPrivate: true)
            }
        ]
        let closed = Array(tabManager.recentlyClosed.prefix(10))
        if !closed.isEmpty {
            let items = closed.map { record -> UIAction in
                let label = record.title.isEmpty ? (record.url.host ?? record.url.absoluteString) : record.title
                return UIAction(title: label) { [weak self] _ in
                    guard let self else { return }
                    self.tabManager.createTab(loading: record.url)
                    self.gridDelegate?.tabGridDidRequestDismiss(self)
                }
            }
            children.append(UIMenu(title: "Recently Closed",
                                   image: UIImage(systemName: "clock.arrow.circlepath"),
                                   children: items))
        }
        return UIMenu(children: children)
    }

    private func updateItemSize() {
        guard let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout else { return }
        let columns: CGFloat = 2
        let inset = BrownBearTheme.Metrics.tabGridInset
        let spacing = BrownBearTheme.Metrics.tabGridSpacing
        let available = collectionView.bounds.width - inset * 2 - spacing * (columns - 1)
        guard available > 0 else { return }
        let width = floor(available / columns)
        let snapshotHeight = width / BrownBearTheme.Metrics.tabCardAspect
        let height = snapshotHeight + 34   // title bar
        layout.itemSize = CGSize(width: width, height: height)
    }

    // MARK: - Diffable data source

    private func configureDataSource() {
        dataSource = UICollectionViewDiffableDataSource<Int, UUID>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, tabID in
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: TabGridCell.reuseID, for: indexPath)
            guard let self,
                  let cell = cell as? TabGridCell,
                  let tab = self.tabManager.tab(for: tabID) else { return cell }
            cell.configure(title: tab.state.displayTitle,
                           snapshot: tab.snapshot,
                           isActive: tab.id == self.tabManager.activeTabID)
            cell.onClose = { [weak self] in self?.closeTab(id: tabID) }
            return cell
        }
    }

    /// The tabs actually shown: the current mode's tabs, narrowed by the search text (title + host).
    private var visibleTabs: [Tab] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return displayedTabs }
        return displayedTabs.filter { tab in
            tab.state.displayTitle.lowercased().contains(query)
                || (tab.state.url?.host?.lowercased().contains(query) ?? false)
        }
    }

    private func applySnapshot(animatingDifferences: Bool) {
        var snapshot = NSDiffableDataSourceSnapshot<Int, UUID>()
        snapshot.appendSections([0])
        snapshot.appendItems(visibleTabs.map(\.id), toSection: 0)
        dataSource.apply(snapshot, animatingDifferences: animatingDifferences)
    }

    private func updateTitle() {
        // Always show the Normal/Private switcher so entering private mode is discoverable even before
        // any private tab exists (the count is evident from the grid itself).
        modeControl.isHidden = false
        titleLabel.isHidden = true
        closeAllButton.isHidden = displayedTabs.isEmpty
        applyPrivateAppearance()
    }

    /// Tint the grid a distinct dark shade in private mode so it's unmistakable which mode you're in.
    /// Forcing dark appearance keeps the header controls (switcher, Done, Close All) readable on it.
    private func applyPrivateAppearance() {
        let background = showingPrivate
            ? UIColor(red: 0.11, green: 0.09, blue: 0.16, alpha: 1)
            : BrownBearTheme.Palette.background
        view.backgroundColor = background
        header.backgroundColor = background
        view.overrideUserInterfaceStyle = showingPrivate ? .dark : .unspecified
    }

    // MARK: - Mutations

    private func closeTab(id: UUID) {
        tabManager.closeTab(id: id)
        reconcileAfterMutation()
    }

    /// After any close, re-sync the grid: if all tabs are gone, hand back to a fresh tab; if only the
    /// current mode emptied (but the other still has tabs), switch to the populated mode.
    private func reconcileAfterMutation() {
        if tabManager.isEmpty {
            gridDelegate?.tabGrid(self, didRequestNewTabPrivate: false)
            return
        }
        if displayedTabs.isEmpty {
            showingPrivate.toggle()
            modeControl.selectedSegmentIndex = showingPrivate ? 1 : 0
        }
        applySnapshot(animatingDifferences: true)
        updateTitle()
    }

    // MARK: - Actions

    @objc private func modeChanged() {
        showingPrivate = (modeControl.selectedSegmentIndex == 1)
        applySnapshot(animatingDifferences: true)
        updateTitle()
    }

    @objc private func tapDone() {
        if tabManager.isEmpty {
            gridDelegate?.tabGrid(self, didRequestNewTabPrivate: false)
        } else {
            gridDelegate?.tabGridDidRequestDismiss(self)
        }
    }

    @objc private func tapNewTab() {
        gridDelegate?.tabGrid(self, didRequestNewTabPrivate: showingPrivate)
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
        present(alert, animated: true)
    }
}

// MARK: - UICollectionViewDelegate

extension BrownBearTabGridController: UICollectionViewDelegate {
    // Once the user drags the grid, stop the open-time auto-center so it doesn't fight their scrolling.
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { userInteractedWithGrid = true }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let tabID = dataSource.itemIdentifier(for: indexPath),
              let tab = tabManager.tab(for: tabID) else { return }
        captureSelectedCard(tab: tab, at: indexPath)
        gridDelegate?.tabGrid(self, didSelect: tab)
    }

    /// Capture what the hero transition needs to expand the tapped card into the page: the tab's own page
    /// SNAPSHOT (≈ screen aspect, so it grows to a centered full screen gently) and the card's picture
    /// region frame on screen (where it starts from — excluding the title strip). Empty (→ the transition
    /// falls back to its fade) if the cell isn't on screen or the tab has no snapshot yet.
    private func captureSelectedCard(tab: Tab, at indexPath: IndexPath) {
        guard let snapshot = tab.snapshot,
              let cell = collectionView.cellForItem(at: indexPath) as? TabGridCell,
              let frame = cell.snapshotRegionFrame() else {
            selectedCardImage = nil
            selectedCardFrame = .zero
            return
        }
        selectedCardImage = snapshot
        selectedCardFrame = frame   // window coordinates == transition container
    }

    /// Per-tab long-press menu (Chrome/Safari pattern): act on a tab without first switching to it.
    func collectionView(_ collectionView: UICollectionView,
                        contextMenuConfigurationForItemAt indexPath: IndexPath,
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard let tabID = dataSource.itemIdentifier(for: indexPath),
              let tab = tabManager.tab(for: tabID) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            var actions: [UIMenuElement] = []
            if let url = tab.state.url {
                actions.append(UIAction(title: "Copy Link", image: UIImage(systemName: "link")) { _ in
                    UIPasteboard.general.url = url
                })
                actions.append(UIAction(title: "Share…", image: UIImage(systemName: "square.and.arrow.up")) { _ in
                    self.shareTab(url: url, at: indexPath)
                })
            }
            if self.displayedTabs.count > 1 {
                actions.append(UIAction(title: "Close Other Tabs",
                                        image: UIImage(systemName: "xmark.circle")) { _ in
                    self.tabManager.closeOtherTabs(keeping: tabID)
                    self.reconcileAfterMutation()
                })
            }
            actions.append(UIAction(title: "Close Tab", image: UIImage(systemName: "xmark"),
                                    attributes: .destructive) { _ in
                self.closeTab(id: tabID)
            })
            return UIMenu(children: actions)
        }
    }

    private func shareTab(url: URL, at indexPath: IndexPath) {
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let cell = collectionView.cellForItem(at: indexPath) {
            activity.popoverPresentationController?.sourceView = cell
            activity.popoverPresentationController?.sourceRect = cell.bounds
        }
        present(activity, animated: true)
    }
}

// MARK: - UISearchBarDelegate

extension BrownBearTabGridController: UISearchBarDelegate {
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        userInteractedWithGrid = true   // searching re-lays-out the grid; don't yank it back to the active tab
        self.searchText = searchText
        applySnapshot(animatingDifferences: true)
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }
}

// MARK: - Drag & drop reorder

extension BrownBearTabGridController: UICollectionViewDragDelegate, UICollectionViewDropDelegate {

    func collectionView(_ collectionView: UICollectionView,
                        itemsForBeginning session: UIDragSession,
                        at indexPath: IndexPath) -> [UIDragItem] {
        // Reordering a filtered subset is ambiguous, so drags are disabled while a search is active.
        guard searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let id = dataSource.itemIdentifier(for: indexPath) else { return [] }
        let item = UIDragItem(itemProvider: NSItemProvider(object: id.uuidString as NSString))
        item.localObject = id
        return [item]
    }

    func collectionView(_ collectionView: UICollectionView,
                        dropSessionDidUpdate session: UIDropSession,
                        withDestinationIndexPath destinationIndexPath: IndexPath?)
    -> UICollectionViewDropProposal {
        // Only our own in-grid reorder; reject anything dragged in from outside the app.
        guard session.localDragSession != nil else {
            return UICollectionViewDropProposal(operation: .forbidden)
        }
        return UICollectionViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
    }

    func collectionView(_ collectionView: UICollectionView,
                        performDropWith coordinator: UICollectionViewDropCoordinator) {
        guard coordinator.proposal.operation == .move,
              let item = coordinator.items.first,
              let sourceID = item.dragItem.localObject as? UUID else { return }

        var ids = dataSource.snapshot().itemIdentifiers(inSection: 0)
        guard let from = ids.firstIndex(of: sourceID) else { return }
        let destination = coordinator.destinationIndexPath?.item ?? ids.count
        ids.remove(at: from)
        ids.insert(sourceID, at: min(max(0, destination), ids.count))

        // Commit the new order to the model, then rebuild the grid from that single source of truth.
        tabManager.reorderTabs(toMatch: ids)
        applySnapshot(animatingDifferences: true)

        let landedIndex = ids.firstIndex(of: sourceID) ?? destination
        coordinator.drop(item.dragItem, toItemAt: IndexPath(item: landedIndex, section: 0))
    }
}
