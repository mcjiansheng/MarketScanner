import UIKit
import UniformTypeIdentifiers

/// Historical-scan processing screen (V1R2 Gate 0 §4.2 / Gate A): lists
/// finalized sessions discovered on device, lets the user pick one, then
/// drives snapshot → fast/deep processing → trajectory → tags → result
/// package → streaming XLSX through the coordinator.
///
/// V1R2 §4.2 fixes:
/// - `discoverFinalizedSessions()` returns fully constructed
///   `[SessionCandidate]` values (session / segment / database /
///   metadata) instead of bare URLs.
/// - Cells use the `.subtitle` style so `detailTextLabel` is real.
/// - The prior map bound to the session metadata selects the map; the
///   first library entry is never picked blindly.
final class MobileProcessingViewController: UIViewController,
    UITableViewDataSource,
    UITableViewDelegate,
    UIDocumentPickerDelegate {

    struct SessionCandidate {
        let sessionDirectory: URL
        let segmentDirectory: URL
        let databaseURL: URL
        let metadata: [String: Any]

        var trackingSessionID: String {
            return metadata["trackingSessionId"] as? String ?? ""
        }

        var storeID: String {
            return metadata["storeId"] as? String ?? ""
        }

        /// B-08: floor identity recorded when the scan was configured;
        /// flows into the processing request so the snapshot eligibility
        /// chain validates it fail-closed.
        var floorID: String {
            return metadata["floorId"] as? String ?? ""
        }

        /// Prior-map identity recorded when the scan was configured.
        var boundPriorMapID: String? {
            return metadata["priorMapId"] as? String
        }

        var boundPriorMapSHA: String? {
            return metadata["priorMapSha256"] as? String
        }
    }

    private let coordinator = MobileOnlyWorkflowCoordinator.shared
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let statusLabel = UILabel()
    private var candidates: [SessionCandidate] = []
    private var processing = false
    private var exporting = false
    private var pendingExportCandidate: SessionCandidate?
    private var observerTokens: [MobileOnlyWorkflowCoordinator.ObserverToken] = []

    private var isBusy: Bool { processing || exporting }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "处理历史扫描"
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close, target: self, action: #selector(close))

        tableView.dataSource = self
        tableView.delegate = self
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)

        statusLabel.numberOfLines = 0
        statusLabel.textColor = .secondaryLabel
        statusLabel.text = ""
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)
        progressView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(progressView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progressView.topAnchor.constraint(equalTo: tableView.bottomAnchor, constant: 8),
            progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            progressView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            statusLabel.topAnchor.constraint(equalTo: progressView.bottomAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            statusLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
        ])

        registerObservers()
    }

    deinit {
        for token in observerTokens {
            coordinator.removeObserver(token)
        }
    }

    private func registerObservers() {
        observerTokens.append(coordinator.addStateObserver { [weak self] state in
            self?.updateStatus(state)
        })
        observerTokens.append(coordinator.addProgressObserver { [weak self] fraction, message in
            self?.progressView.setProgress(Float(fraction), animated: true)
            self?.statusLabel.text = message
        })
        observerTokens.append(coordinator.addProcessingObserver { [weak self] result in
            guard let self = self else { return }
            self.processing = false
            self.updateBusyPresentation()
            switch result {
            case .success(let entry):
                self.progressView.setProgress(1.0, animated: true)
                self.statusLabel.text =
                    "完成：\(entry.manifest["workbook"] as? String ?? "workbook")（SHA \(String(entry.workbookSHA256.prefix(12)))）"
                self.pushResult(entry)
            case .failure(let error):
                self.progressView.setProgress(0.0, animated: true)
                if case .rescanSessionRequired(let detail) = error {
                    self.statusLabel.text = "需要重新扫描整个会话：\(detail)"
                    self.presentNotice(
                        "本会话的快速优化和一次全图优化仍未达到发布门槛，"
                        + "或最终轨迹没有可发布节点。\n\n"
                        + "系统已安全保存 RESCAN_SESSION 记录；本次没有发布 "
                        + "PriceTags、DevicePositions 或普通结果。请重新扫描整个会话。")
                } else {
                    self.statusLabel.text = "处理失败：\(error.localizedDescription)"
                }
            }
            self.tableView.reloadData()
        })
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadCandidates()
    }

    private func reloadCandidates() {
        candidates = Self.discoverFinalizedSessions()
        tableView.reloadData()
    }

    /// Discovers finalized continuous-streaming sessions in Documents and
    /// constructs complete candidates (§4.2): session directory, segment
    /// directory, existing source database and the parsed metadata.
    static func discoverFinalizedSessions() -> [SessionCandidate] {
        guard let documents = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask).first else { return [] }
        guard let names = try? FileManager.default.contentsOfDirectory(
            atPath: documents.path) else { return [] }
        var result: [SessionCandidate] = []
        for name in names where name.hasPrefix("SupermarketSession-") {
            let session = documents.appendingPathComponent(name)
            let segments = try? FileManager.default.contentsOfDirectory(atPath: session.path)
            for segment in (segments ?? []).sorted() where segment.hasPrefix("segment_") {
                let segmentDirectory = session.appendingPathComponent(segment)
                let metadataURL = segmentDirectory.appendingPathComponent("metadata.json")
                guard let data = try? Data(contentsOf: metadataURL) else { continue }
                guard let object = try? StrictJSONDocumentParser.object(
                    from: data,
                    limits: StrictJSONDocumentLimits(maximumBytes: data.count + 1)) as? [String: Any],
                    let finalized = object["finalized"] as? Bool, finalized,
                    let scanMode = object["scanMode"] as? String,
                    scanMode == "continuous_streaming"
                else { continue }
                let databaseURL = segmentDirectory
                    .appendingPathComponent("rtabmap_segment_0001.db")
                guard FileManager.default.fileExists(atPath: databaseURL.path) else { continue }
                result.append(SessionCandidate(
                    sessionDirectory: session,
                    segmentDirectory: segmentDirectory,
                    databaseURL: databaseURL,
                    metadata: object))
            }
        }
        return result.sorted { $0.segmentDirectory.path > $1.segmentDirectory.path }
    }

    @objc private func close() {
        guard !isBusy else { return }
        dismiss(animated: true)
    }

    private func updateStatus(_ state: MobileOnlyWorkflowState) {
        guard processing else { return }
        statusLabel.text = state.displayName
    }

    private func pushResult(_ entry: MobileResultLibrary.ResultEntry) {
        let result = MobileResultViewController()
        result.resultEntry = entry
        navigationController?.pushViewController(result, animated: true)
    }

    // MARK: - UITableViewDataSource

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return max(candidates.count, 1)
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        // `.subtitle` style is required: the default dequeued cell has no
        // detailTextLabel (V1R2 §4.2).
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: "session")
        if candidates.isEmpty {
            cell.textLabel?.text = "没有可处理的 finalized 会话"
            cell.textLabel?.textColor = .secondaryLabel
            cell.detailTextLabel?.text = nil
            cell.selectionStyle = .none
            cell.accessoryView = nil
            return cell
        }
        let candidate = candidates[indexPath.row]
        cell.textLabel?.text = candidate.sessionDirectory.lastPathComponent
        cell.textLabel?.textColor = .label
        let traceCount = (candidate.metadata["captureHealth"] as? [String: Any])?["localizationTraceRecordCount"] as? Int
        let boundMap = candidate.boundPriorMapID ?? "未绑定地图"
        cell.detailTextLabel?.text =
            "finalized · trace \(traceCount ?? 0) · \(boundMap)"
        let exportButton = UIButton(type: .system)
        exportButton.setImage(
            UIImage(systemName: "square.and.arrow.up"),
            for: .normal)
        exportButton.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        exportButton.tag = indexPath.row
        exportButton.isEnabled = !isBusy
        exportButton.accessibilityLabel = "导出原始扫描"
        exportButton.accessibilityHint =
            "无需先处理成功，直接复制并校验完整历史扫描目录"
        exportButton.addTarget(
            self,
            action: #selector(exportButtonTapped(_:)),
            for: .touchUpInside)
        cell.accessoryView = exportButton
        cell.selectionStyle = isBusy ? .none : .default
        return cell
    }

    // MARK: - UITableViewDelegate

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !isBusy, !candidates.isEmpty else { return }
        let candidate = candidates[indexPath.row]

        // The map bound to the session metadata selects the library entry
        // (§4.2): never pick the first map blindly.
        let map: MobileMapLibrary.MapEntry
        do {
            guard let priorMapID = candidate.boundPriorMapID,
                  let priorMapSHA = candidate.boundPriorMapSHA else {
                throw MobileOnlyWorkflowError.mapNotBound(
                    "会话元数据未记录地图身份（旧会话？）")
            }
            map = try MobileMapLibrary.map(priorMapID: priorMapID, packageSHA256: priorMapSHA)
        } catch {
            presentNotice(
                "该会话绑定的地图不在地图库中：\(error.localizedDescription)\n"
                + "请先导入并编译对应门店地图。")
            return
        }

        processing = true
        updateBusyPresentation()
        statusLabel.text = "开始处理…"
        coordinator.beginProcessing(
            finalizedSession: candidate.segmentDirectory,
            sourceDatabase: candidate.databaseURL,
            priorMap: map,
            storeID: candidate.storeID,
            floorID: candidate.floorID,
            trackingSessionID: candidate.trackingSessionID)
    }

    @objc private func exportButtonTapped(_ sender: UIButton) {
        guard !isBusy,
              candidates.indices.contains(sender.tag) else { return }
        pendingExportCandidate = candidates[sender.tag]
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.folder],
            asCopy: false)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        present(picker, animated: true)
    }

    func documentPicker(
        _ controller: UIDocumentPickerViewController,
        didPickDocumentsAt urls: [URL]
    ) {
        guard !isBusy,
              let candidate = pendingExportCandidate,
              let destination = urls.first else {
            pendingExportCandidate = nil
            return
        }
        pendingExportCandidate = nil
        let didStartSecurityScope =
            destination.startAccessingSecurityScopedResource()
        exporting = true
        updateBusyPresentation()
        progressView.setProgress(0.02, animated: false)
        statusLabel.text = "正在准备导出原始历史扫描…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<URL, Error>
            do {
                let exported = try SupermarketScanSession.exportFinalizedCapture(
                    from: candidate.segmentDirectory,
                    localDocumentsDirectory:
                        candidate.sessionDirectory.deletingLastPathComponent(),
                    destinationBaseDirectory: destination,
                    expectedTrackingSessionID: candidate.trackingSessionID,
                    progress: { fraction, message in
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.exporting else { return }
                            self.progressView.setProgress(
                                Float(fraction),
                                animated: true)
                            self.statusLabel.text = message
                        }
                    })
                result = .success(exported)
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async { [weak self] in
                if didStartSecurityScope {
                    destination.stopAccessingSecurityScopedResource()
                }
                guard let self else { return }
                self.exporting = false
                self.updateBusyPresentation()
                switch result {
                case .success(let exported):
                    self.progressView.setProgress(1.0, animated: true)
                    self.statusLabel.text =
                        "导出完成：\(exported.deletingLastPathComponent().lastPathComponent)"
                    self.presentNotice(
                        "完整原始扫描已复制并通过 SHA-256 复核。\n\n"
                        + "导出目录：\(exported.deletingLastPathComponent().lastPathComponent)\n"
                        + "手机中的本地原始扫描仍然保留。")
                case .failure(let error):
                    self.progressView.setProgress(0.0, animated: true)
                    self.statusLabel.text =
                        "导出失败：\(error.localizedDescription)"
                    self.presentNotice(
                        "原始历史扫描导出失败：\n\(error.localizedDescription)\n\n"
                        + "手机中的本地原始扫描没有被删除。")
                }
                self.tableView.reloadData()
            }
        }
    }

    func documentPickerWasCancelled(
        _ controller: UIDocumentPickerViewController
    ) {
        pendingExportCandidate = nil
    }

    private func updateBusyPresentation() {
        navigationItem.leftBarButtonItem?.isEnabled = !isBusy
        navigationController?.isModalInPresentation = isBusy
        tableView.isUserInteractionEnabled = !isBusy
        tableView.reloadData()
    }

    private func presentNotice(_ message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "知道了", style: .default))
        present(alert, animated: true)
    }
}
