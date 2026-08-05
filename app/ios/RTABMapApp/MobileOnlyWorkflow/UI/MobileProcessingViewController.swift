import UIKit

/// Historical-scan processing screen (V1R1 Gate A): lists finalized
/// sessions discovered on device, lets the user pick one, then drives
/// snapshot -> fast/deep processing -> trajectory -> tags -> result
/// package -> streaming XLSX through the coordinator.
final class MobileProcessingViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    private struct SessionCandidate {
        let directory: URL
        let segmentDirectory: URL
        let databaseURL: URL
        let metadata: [String: Any]
    }

    private let coordinator = MobileOnlyWorkflowCoordinator.shared
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let statusLabel = UILabel()
    private var candidates: [SessionCandidate] = []
    private var processing = false

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "处理历史扫描"
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close, target: self, action: #selector(close))

        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
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

        coordinator.onStateChange = { [weak self] state in
            self?.updateStatus(state)
        }
        coordinator.onProcessingProgress = { [weak self] fraction, message in
            self?.progressView.setProgress(Float(fraction), animated: true)
            self?.statusLabel.text = message
        }
        coordinator.onProcessingFinished = { [weak self] result in
            guard let self = self else { return }
            self.processing = false
            self.progressView.setProgress(result.map { _ in 1.0 } ?? 0.0, animated: true)
            switch result {
            case .success(let entry):
                self.statusLabel.text =
                    "完成：\(entry.manifest["workbook"] as? String ?? "workbook")（SHA \(String(entry.workbookSHA256.prefix(12)))）"
                self.pushResult(entry)
            case .failure(let error):
                self.statusLabel.text = "处理失败：\(error.localizedDescription)"
            }
            self.tableView.reloadData()
        }
    }

    deinit {
        coordinator.onStateChange = nil
        coordinator.onProcessingProgress = nil
        coordinator.onProcessingFinished = nil
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadCandidates()
    }

    private func reloadCandidates() {
        candidates = Self.discoverFinalizedSessions()
        tableView.reloadData()
    }

    /// Discovers finalized continuous-streaming sessions in Documents.
    static func discoverFinalizedSessions() -> [URL] {
        guard let documents = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask).first else { return [] }
        guard let names = try? FileManager.default.contentsOfDirectory(
            atPath: documents.path) else { return [] }
        var result: [URL] = []
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
                result.append(segmentDirectory)
            }
        }
        return result.sorted { $0.path > $1.path }
    }

    @objc private func close() {
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
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        if candidates.isEmpty {
            cell.textLabel?.text = "没有可处理的 finalized 会话"
            cell.textLabel?.textColor = .secondaryLabel
            cell.detailTextLabel?.text = nil
            return cell
        }
        let candidate = candidates[indexPath.row]
        cell.textLabel?.text = candidate.directory.lastPathComponent
        cell.textLabel?.textColor = .label
        let traceCount = (candidate.metadata["captureHealth"] as? [String: Any])?["localizationTraceRecordCount"] as? Int
        cell.detailTextLabel?.text = "finalized · trace \(traceCount ?? 0)"
        cell.accessoryType = processing ? .none : .disclosureIndicator
        return cell
    }

    // MARK: - UITableViewDelegate

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !processing, !candidates.isEmpty else { return }
        let candidate = candidates[indexPath.row]
        guard let map = try? MobileMapLibrary.listMaps().first else {
            presentNotice("请先导入并编译一张门店地图。")
            return
        }
        let trackingSessionID = candidate.metadata["trackingSessionId"] as? String ?? "unknown"
        let storeID = candidate.metadata["storeId"] as? String ?? "default"
        processing = true
        statusLabel.text = "开始处理…"
        coordinator.beginProcessing(
            finalizedSession: candidate.segmentDirectory,
            sourceDatabase: candidate.databaseURL,
            priorMap: map,
            storeID: storeID,
            trackingSessionID: trackingSessionID)
    }

    private func presentNotice(_ message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "知道了", style: .default))
        present(alert, animated: true)
    }
}
