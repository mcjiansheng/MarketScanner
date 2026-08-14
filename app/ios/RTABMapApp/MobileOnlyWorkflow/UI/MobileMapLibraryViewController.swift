import UIKit
import UniformTypeIdentifiers

/// Responsive browser for the unified, immutable on-device map library.
/// Registry listing is lightweight and asynchronous; the exact package is
/// fully validated only after selection by `MobileScanSetupViewController`.
final class MobileMapLibraryViewController: UIViewController,
    UITableViewDataSource,
    UITableViewDelegate {

    enum Purpose {
        case manageLibrary
        case selectForScan
    }

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private let activityLabel = UILabel()
    private let importButton = UIButton(type: .system)
    private let libraryQueue = DispatchQueue(
        label: "MarketScanner.MapLibrary.UI",
        qos: .userInitiated)
    private let coordinator = MobileOnlyWorkflowCoordinator.shared
    private let purpose: Purpose

    private var maps: [MobileMapLibrary.MapEntry] = []
    private var hasLoaded = false
    private var loadGeneration = UUID()
    private var packagePicker: ExistingPriorMapPackagePicker?
    private var preparedImportController: MobileMapImportViewController?
    private var preparedImportMenu: UIAlertController?
    private var observerTokens: [MobileOnlyWorkflowCoordinator.ObserverToken] = []

    init(purpose: Purpose = .manageLibrary) {
        self.purpose = purpose
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = purpose == .selectForScan ? "选择门店地图" : "门店地图"
        navigationItem.prompt = purpose == .selectForScan
            ? "选择后才会验证并加载该地图"
            : nil
        view.backgroundColor = .systemBackground
        if purpose == .manageLibrary {
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .add,
                target: self,
                action: #selector(importMap))
        }
        if navigationController?.viewControllers.first === self {
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .close,
                target: self,
                action: #selector(close))
        }

        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(
            UITableViewCell.self,
            forCellReuseIdentifier: "unused-default-cell")
        tableView.refreshControl = UIRefreshControl()
        tableView.refreshControl?.addTarget(
            self, action: #selector(refreshRequested), for: .valueChanged)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)

        importButton.setTitle("导入新地图", for: .normal)
        importButton.setImage(UIImage(systemName: "plus.circle.fill"), for: .normal)
        importButton.titleLabel?.font = UIFont.preferredFont(
            forTextStyle: .headline)
        importButton.titleLabel?.adjustsFontForContentSizeCategory = true
        importButton.backgroundColor = .secondarySystemBackground
        importButton.layer.cornerRadius = 12
        importButton.contentEdgeInsets = UIEdgeInsets(
            top: 12, left: 16, bottom: 12, right: 16)
        importButton.addTarget(
            self, action: #selector(importMap), for: .touchUpInside)
        importButton.translatesAutoresizingMaskIntoConstraints = false
        importButton.isHidden = purpose != .selectForScan
        view.addSubview(importButton)

        activityLabel.font = UIFont.preferredFont(forTextStyle: .subheadline)
        activityLabel.adjustsFontForContentSizeCategory = true
        activityLabel.textColor = .secondaryLabel
        activityLabel.numberOfLines = 0
        let activityRow = UIStackView(arrangedSubviews: [
            activityIndicator, activityLabel,
        ])
        activityRow.axis = .horizontal
        activityRow.spacing = 10
        activityRow.alignment = .center
        activityRow.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(activityRow)

        var constraints = [
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            activityRow.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityRow.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            activityRow.leadingAnchor.constraint(
                greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            activityRow.trailingAnchor.constraint(
                lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ]
        if purpose == .selectForScan {
            constraints.append(contentsOf: [
                tableView.bottomAnchor.constraint(
                    equalTo: importButton.topAnchor, constant: -8),
                importButton.leadingAnchor.constraint(
                    equalTo: view.safeAreaLayoutGuide.leadingAnchor,
                    constant: 20),
                importButton.trailingAnchor.constraint(
                    equalTo: view.safeAreaLayoutGuide.trailingAnchor,
                    constant: -20),
                importButton.bottomAnchor.constraint(
                    equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                    constant: -12),
                importButton.heightAnchor.constraint(
                    greaterThanOrEqualToConstant: 50),
            ])
        } else {
            constraints.append(
                tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor))
        }
        NSLayoutConstraint.activate(constraints)

        observerTokens.append(coordinator.addCompileObserver {
            [weak self] result in
            guard let self = self, case .success(let map) = result else {
                return
            }
            self.upsert(map)
        })
        reloadRegistry()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Defer cold UIKit/FileProvider work until the library page has
        // painted. This removes it from both the "导入新地图" tap and the
        // subsequent XLSX/CSV/JSON action without touching workflow state.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.prepareImportFlowIfIdle()
        }
    }

    deinit {
        for token in observerTokens {
            coordinator.removeObserver(token)
        }
    }

    private func upsert(_ map: MobileMapLibrary.MapEntry) {
        maps.removeAll {
            $0.priorMapID == map.priorMapID
                && $0.packageSHA256 == map.packageSHA256
        }
        maps.insert(map, at: 0)
        hasLoaded = true
        tableView.reloadData()
    }

    private func setBusy(_ busy: Bool, message: String = "") {
        activityLabel.text = message
        activityLabel.isHidden = !busy
        if busy {
            activityIndicator.startAnimating()
        } else {
            activityIndicator.stopAnimating()
        }
        navigationItem.rightBarButtonItem?.isEnabled = !busy
        importButton.isEnabled = !busy
        tableView.isUserInteractionEnabled = !busy
    }

    private func reloadRegistry(fullVerification: Bool = false) {
        let generation = UUID()
        loadGeneration = generation
        setBusy(
            true,
            message: fullVerification
                ? "正在后台完整校验地图库…"
                : "正在读取地图库…")
        libraryQueue.async { [weak self] in
            let result = Result {
                fullVerification
                    ? try MobileMapLibrary.listMaps()
                    : try MobileMapLibrary.listRegisteredMaps()
            }
            DispatchQueue.main.async {
                guard let self = self,
                      self.loadGeneration == generation else { return }
                self.tableView.refreshControl?.endRefreshing()
                self.setBusy(false)
                switch result {
                case .success(let entries):
                    self.maps = entries
                    self.hasLoaded = true
                    self.tableView.reloadData()
                case .failure(let error):
                    self.maps = []
                    self.tableView.reloadData()
                    self.presentLibraryError(error)
                }
            }
        }
    }

    @objc private func refreshRequested() {
        reloadRegistry(fullVerification: true)
    }

    private func presentLibraryError(_ error: Error) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(
            title: "地图库不可用",
            message: error.localizedDescription,
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(
            title: "后台重建索引",
            style: .default
        ) { [weak self] _ in
            self?.rebuildRegistry()
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    private func rebuildRegistry() {
        let generation = UUID()
        loadGeneration = generation
        setBusy(true, message: "正在后台重建并校验地图库索引…")
        libraryQueue.async { [weak self] in
            let result = Result { try MobileMapLibrary.rebuildRegistry() }
            DispatchQueue.main.async {
                guard let self = self,
                      self.loadGeneration == generation else { return }
                switch result {
                case .success:
                    self.reloadRegistry(fullVerification: false)
                case .failure(let error):
                    self.setBusy(false)
                    self.presentLibraryError(error)
                }
            }
        }
    }

    @objc private func importMap() {
        let alert = preparedImportMenu ?? makeImportMenu()
        preparedImportMenu = nil
        present(alert, animated: true)
    }

    private func makeImportMenu() -> UIAlertController {
        let alert = UIAlertController(
            title: "添加门店地图",
            message: "两种来源都会安装到同一地图库，并使用同一套起点配置和扫描启动流程。",
            preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(
            title: "导入 XLSX / CSV / JSON",
            style: .default
        ) { [weak self] _ in
            guard let self else { return }
            let controller = self.preparedImportController
                ?? MobileMapImportViewController()
            self.preparedImportController = nil
            controller.prepareForPresentation()
            self.navigationController?.pushViewController(
                controller, animated: true)
        })
        alert.addAction(UIAlertAction(
            title: "导入已有 PC 地图包",
            style: .default
        ) { [weak self] _ in
            self?.beginExistingPackageImport()
        })
        alert.addAction(UIAlertAction(
            title: "取消",
            style: .cancel
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.prepareImportFlowIfIdle() }
        })
        if let popover = alert.popoverPresentationController {
            if let barButtonItem = navigationItem.rightBarButtonItem {
                popover.barButtonItem = barButtonItem
            } else {
                popover.sourceView = importButton
                popover.sourceRect = importButton.bounds
            }
        }
        alert.loadViewIfNeeded()
        return alert
    }

    private func prepareImportFlowIfIdle() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.prepareImportFlowIfIdle()
            }
            return
        }
        guard coordinator.state == .idle,
              navigationController?.topViewController === self,
              presentedViewController == nil else {
            return
        }
        // Split the cold objects across separate main-run-loop turns so the
        // already visible library page can process touches and rendering
        // between UIKit/FileProvider initialization steps.
        if preparedImportMenu == nil {
            preparedImportMenu = makeImportMenu()
            DispatchQueue.main.async { [weak self] in
                self?.prepareImportFlowIfIdle()
            }
            return
        }
        if preparedImportController == nil {
            let controller = MobileMapImportViewController()
            controller.loadViewIfNeeded()
            preparedImportController = controller
            DispatchQueue.main.async { [weak self] in
                self?.prepareImportFlowIfIdle()
            }
            return
        }
        preparedImportController?.prepareForPresentation()
    }

    private func beginExistingPackageImport() {
        setBusy(true, message: "请选择 PriorMap 地图包文件夹…")
        let picker = ExistingPriorMapPackagePicker(
            progress: { [weak self] _, message in
                self?.activityLabel.text = message
            },
            completion: { [weak self] result in
                guard let self = self else { return }
                self.packagePicker = nil
                self.setBusy(false)
                switch result {
                case .success(let entry):
                    self.upsert(entry)
                    self.presentImportedPackage(entry)
                case .failure(let error):
                    self.presentSimpleNotice(
                        title: "地图包导入失败",
                        message: error.localizedDescription)
                }
            },
            cancelled: { [weak self] in
                self?.packagePicker = nil
                self?.setBusy(false)
            })
        packagePicker = picker
        picker.present(from: self)
    }

    private func presentImportedPackage(_ map: MobileMapLibrary.MapEntry) {
        let message = """
        \(map.name)
        地图 ID：\(map.priorMapID)
        包 SHA：\(map.packageSHA256.prefix(16))…
        \(map.floorCount) 层 · \(map.elementCount) 个有效元素

        地图已进入统一地图库，后续配置和扫描逻辑与手机编译地图完全相同。
        """
        let alert = UIAlertController(
            title: "已有地图包已就绪",
            message: message,
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(
            title: purpose == .selectForScan ? "使用此地图" : "开始扫描",
            style: .default
        ) { [weak self] _ in
            let setup = MobileScanSetupViewController(selectedMap: map)
            self?.navigationController?.pushViewController(
                setup, animated: true)
        })
        alert.addAction(UIAlertAction(title: "完成", style: .cancel))
        present(alert, animated: true)
    }

    private func presentSimpleNotice(title: String, message: String) {
        let alert = UIAlertController(
            title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "知道了", style: .default))
        present(alert, animated: true)
    }

    @objc private func close() {
        dismiss(animated: true)
    }

    // MARK: - UITableViewDataSource

    func tableView(
        _ tableView: UITableView,
        numberOfRowsInSection section: Int
    ) -> Int {
        return maps.isEmpty ? 1 : maps.count
    }

    func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        if maps.isEmpty {
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            if hasLoaded {
                cell.textLabel?.text = purpose == .selectForScan
                    ? "暂无地图，请点击下方“导入新地图”"
                    : "暂无地图，请点击右上角 + 导入"
            } else {
                cell.textLabel?.text = "正在读取地图库…"
            }
            cell.textLabel?.textColor = .secondaryLabel
            cell.selectionStyle = .none
            return cell
        }
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let map = maps[indexPath.row]
        cell.textLabel?.text = "\(map.name)（\(map.floorCount) 层）"
        cell.detailTextLabel?.text =
            "\(map.elementCount) 元素 · SHA \(map.packageSHA256.prefix(12))"
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    // MARK: - UITableViewDelegate

    func tableView(
        _ tableView: UITableView,
        didSelectRowAt indexPath: IndexPath
    ) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard maps.indices.contains(indexPath.row) else { return }
        let setup = MobileScanSetupViewController(
            selectedMap: maps[indexPath.row])
        navigationController?.pushViewController(setup, animated: true)
    }
}

/// Security-scoped folder picker for a formal PC-generated prior-map package.
/// Copy/validation/registration all run off the main thread.
private final class ExistingPriorMapPackagePicker: NSObject,
    UIDocumentPickerDelegate {

    private let progress: (Double, String) -> Void
    private let completion: (Result<MobileMapLibrary.MapEntry, Error>) -> Void
    private let cancelled: () -> Void
    private let queue = DispatchQueue(
        label: "MarketScanner.ExistingPriorMapPackageImport",
        qos: .userInitiated)

    init(
        progress: @escaping (Double, String) -> Void,
        completion: @escaping (Result<MobileMapLibrary.MapEntry, Error>) -> Void,
        cancelled: @escaping () -> Void
    ) {
        self.progress = progress
        self.completion = completion
        self.cancelled = cancelled
    }

    func present(from viewController: UIViewController) {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.folder],
            asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        viewController.present(picker, animated: true)
    }

    func documentPicker(
        _ controller: UIDocumentPickerViewController,
        didPickDocumentsAt urls: [URL]
    ) {
        guard let url = urls.first else {
            cancelled()
            return
        }
        progress(0, "正在打开地图包…")
        queue.async { [weak self] in
            guard let self = self else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
            let result = Result {
                try MobileMapLibrary.installVerifiedPackage(
                    from: url,
                    progress: { fraction, message in
                        DispatchQueue.main.async {
                            self.progress(fraction, message)
                        }
                    })
            }
            DispatchQueue.main.async {
                self.completion(result)
            }
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        cancelled()
    }
}
