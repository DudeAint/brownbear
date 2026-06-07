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

    /// Which set the grid is showing. Private mode is only reachable once a private tab exists or the
    /// user explicitly switches to it; it persists while the grid is open.
    private var showingPrivate: Bool

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, UUID>!

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
        collectionView.register(TabGridCell.self, forCellWithReuseIdentifier: TabGridCell.reuseID)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)

        // A prominent "+" button floats at the bottom, Chrome-style.
        let plusConfig = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        newTabButton.setImage(UIImage(systemName: "plus", withConfiguration: plusConfig), for: .normal)
        newTabButton.tintColor = .white
        newTabButton.backgroundColor = BrownBearTheme.Palette.accent
        newTabButton.layer.cornerRadius = 28
        newTabButton.layer.shadowColor = UIColor.black.cgColor
        newTabButton.layer.shadowOpacity = 0.25
        newTabButton.layer.shadowRadius = 10
        newTabButton.layer.shadowOffset = CGSize(width: 0, height: 4)
        newTabButton.addTarget(self, action: #selector(tapNewTab), for: .touchUpInside)
        newTabButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(newTabButton)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: header.bottomAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            newTabButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            newTabButton.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -16),
            newTabButton.widthAnchor.constraint(equalToConstant: 56),
            newTabButton.heightAnchor.constraint(equalToConstant: 56)
        ])
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

    private func applySnapshot(animatingDifferences: Bool) {
        var snapshot = NSDiffableDataSourceSnapshot<Int, UUID>()
        snapshot.appendSections([0])
        snapshot.appendItems(displayedTabs.map(\.id), toSection: 0)
        dataSource.apply(snapshot, animatingDifferences: animatingDifferences)
    }

    private func updateTitle() {
        // Show the Normal/Private switcher only once a private tab exists; otherwise a plain count.
        let hasPrivate = tabManager.hasPrivateTabs
        modeControl.isHidden = !hasPrivate
        titleLabel.isHidden = hasPrivate
        let count = displayedTabs.count
        let noun = showingPrivate ? "Private" : "Tab"
        titleLabel.text = count == 1 ? "1 \(noun)" : "\(count) \(noun)s"
        closeAllButton.isHidden = displayedTabs.isEmpty
        applyPrivateAppearance()
    }

    /// Tint the grid a distinct dark shade in private mode so it's unmistakable which mode you're in.
    private func applyPrivateAppearance() {
        let background = showingPrivate
            ? UIColor(red: 0.11, green: 0.09, blue: 0.16, alpha: 1)
            : BrownBearTheme.Palette.background
        view.backgroundColor = background
        header.backgroundColor = background
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
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let tabID = dataSource.itemIdentifier(for: indexPath),
              let tab = tabManager.tab(for: tabID) else { return }
        gridDelegate?.tabGrid(self, didSelect: tab)
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
