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
    func tabGridDidRequestNewTab(_ controller: BrownBearTabGridController)
    func tabGridDidRequestDismiss(_ controller: BrownBearTabGridController)
}

final class BrownBearTabGridController: UIViewController {

    weak var gridDelegate: BrownBearTabGridControllerDelegate?

    private let tabManager: TabManager
    private let header = UIView()
    private let titleLabel = UILabel()
    private let doneButton = UIButton(type: .system)
    private let closeAllButton = UIButton(type: .system)
    private let newTabButton = UIButton(type: .system)

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, UUID>!

    init(tabManager: TabManager) {
        self.tabManager = tabManager
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
        snapshot.appendItems(tabManager.tabs.map(\.id), toSection: 0)
        dataSource.apply(snapshot, animatingDifferences: animatingDifferences)
    }

    private func updateTitle() {
        let count = tabManager.count
        titleLabel.text = count == 1 ? "1 Tab" : "\(count) Tabs"
        closeAllButton.isHidden = tabManager.isEmpty
    }

    // MARK: - Mutations

    private func closeTab(id: UUID) {
        tabManager.closeTab(id: id)
        applySnapshot(animatingDifferences: true)
        updateTitle()
        if tabManager.isEmpty {
            // Closing the last tab from the grid returns to a fresh tab in the browser.
            gridDelegate?.tabGridDidRequestNewTab(self)
        }
    }

    // MARK: - Actions

    @objc private func tapDone() {
        if tabManager.isEmpty {
            gridDelegate?.tabGridDidRequestNewTab(self)
        } else {
            gridDelegate?.tabGridDidRequestDismiss(self)
        }
    }

    @objc private func tapNewTab() {
        gridDelegate?.tabGridDidRequestNewTab(self)
    }

    @objc private func tapCloseAll() {
        let alert = UIAlertController(title: "Close all tabs?",
                                     message: "This closes every open tab.",
                                     preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Close All", style: .destructive) { [weak self] _ in
            guard let self else { return }
            self.tabManager.closeAll()
            self.applySnapshot(animatingDifferences: true)
            self.updateTitle()
            self.gridDelegate?.tabGridDidRequestNewTab(self)
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
}
