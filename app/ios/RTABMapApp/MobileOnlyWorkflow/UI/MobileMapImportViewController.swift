import UIKit

/// Map import wizard (V1R2 Gate 0 §4.1 / Gate B): picks a file, lets the
/// user choose the source coordinate contract, then hands the contract to
/// the workflow coordinator which runs the whole
/// pick → stage → import → compile → register chain itself.
///
/// V1R1 deadlocked here: the page waited for `onImportFinished` before
/// calling the function that produces that callback. The page now only
/// observes unified progress/completion events through observer tokens
/// (§5.3) and never drives the chain.
final class MobileMapImportViewController: UIViewController {

    private let coordinator = MobileOnlyWorkflowCoordinator.shared
    private let contractControl = UISegmentedControl(
        items: ["左上原点", "左下原点"])
    private let percentLabel = UILabel()
    private let statusLabel = UILabel()
    private let elapsedLabel = UILabel()
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let resultLabel = UILabel()
    private let importButton = UIButton(type: .system)
    private var observerTokens: [MobileOnlyWorkflowCoordinator.ObserverToken] = []
    private var latestImportReport: MapSourceImportReport?
    private var progressFraction = 0.0
    private var progressUIVisible = false
    private var startedAtUptime: TimeInterval?
    private var elapsedTimer: Timer?
    private var preparedDocumentPicker: UIDocumentPickerViewController?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "导入门店地图"
        view.backgroundColor = .systemBackground
        buildUI()
        registerObservers()
    }

    /// Called by the lightweight library page after it is visible. UIKit and
    /// FileProvider initialization stay on the main thread, but no workflow
    /// transition or provider access happens until the operator taps Import.
    func prepareForPresentation() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.prepareForPresentation()
            }
            return
        }
        loadViewIfNeeded()
        prepareDocumentPickerIfNeeded()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        DispatchQueue.main.async { [weak self] in
            self?.prepareDocumentPickerIfNeeded()
        }
    }

    deinit {
        elapsedTimer?.invalidate()
        for token in observerTokens {
            coordinator.removeObserver(token)
        }
    }

    private func registerObservers() {
        observerTokens.append(coordinator.addStateObserver { [weak self] state in
            self?.updateStatus(state)
        })
        observerTokens.append(coordinator.addProgressObserver { [weak self] fraction, message in
            self?.updateProgress(fraction: fraction, message: message)
        })
        observerTokens.append(coordinator.addImportObserver { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let report):
                self.latestImportReport = report
                self.statusLabel.text =
                    "解析完成：\(report.elementCount) 个源元素，\(report.floorCount) 层，\(report.warningCount) 条警告。正在编译…"
            case .failure(let error):
                self.statusLabel.text = "导入失败：\(error.localizedDescription)"
                self.importButton.isEnabled = true
                self.contractControl.isEnabled = true
                self.stopElapsedTimer()
            }
        })
        observerTokens.append(coordinator.addCompileObserver { [weak self] result in
            guard let self = self else { return }
            self.importButton.isEnabled = true
            self.contractControl.isEnabled = true
            switch result {
            case .success(let map):
                self.updateProgress(fraction: 1, message: "地图已编译、验证并加入地图库")
                self.stopElapsedTimer()
                let details = self.resultDetails(map: map, report: self.latestImportReport)
                self.resultLabel.text = details
                self.resultLabel.isHidden = false
                self.importButton.setTitle("再次导入地图", for: .normal)
                let alert = UIAlertController(
                    title: "地图已就绪",
                    message: self.alertDetails(map: map, report: self.latestImportReport),
                    preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "开始扫描", style: .default) { [weak self] _ in
                    guard let self = self else { return }
                    let setup = MobileScanSetupViewController(selectedMap: map)
                    // Preserve the library/import back stack. Making setup
                    // the only navigation root removed both Back and Close
                    // and caused the inconsistent navigation in the field
                    // screenshots.
                    self.navigationController?.pushViewController(
                        setup, animated: true)
                })
                alert.addAction(UIAlertAction(title: "完成", style: .cancel) { [weak self] _ in
                    self?.navigationController?.popToRootViewController(animated: true)
                })
                self.present(alert, animated: true)
            case .failure(let error):
                self.statusLabel.text = "编译失败：\(error.localizedDescription)"
                self.stopElapsedTimer()
            }
        })
    }

    private func buildUI() {
        let prompt = UILabel()
        prompt.text = "从「文件」选择 XLSX / CSV / JSON 门店地图，\n文件会先安全复制到应用私有目录。"
        prompt.numberOfLines = 0
        prompt.textColor = .secondaryLabel

        let contractLabel = UILabel()
        contractLabel.text = "原始坐标合同"
        contractLabel.font = UIFont.preferredFont(forTextStyle: .headline)
        contractLabel.adjustsFontForContentSizeCategory = true

        contractControl.selectedSegmentIndex = 0
        contractControl.accessibilityLabel = "原始坐标合同"

        percentLabel.text = "0%"
        percentLabel.font = UIFont.preferredFont(forTextStyle: .largeTitle)
        percentLabel.adjustsFontForContentSizeCategory = true
        percentLabel.textAlignment = .center
        percentLabel.accessibilityTraits = .updatesFrequently
        percentLabel.isHidden = true

        statusLabel.numberOfLines = 0
        statusLabel.text = "选择文件后会显示当前解析、编译、验证和注册阶段。"
        statusLabel.font = UIFont.preferredFont(forTextStyle: .headline)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textAlignment = .center

        elapsedLabel.text = "尚未开始"
        elapsedLabel.font = UIFont.preferredFont(forTextStyle: .caption1)
        elapsedLabel.adjustsFontForContentSizeCategory = true
        elapsedLabel.textColor = .secondaryLabel
        elapsedLabel.textAlignment = .center
        elapsedLabel.isHidden = true

        progressView.progress = 0
        progressView.accessibilityLabel = "地图导入与编译进度"
        progressView.accessibilityValue = "0%"
        progressView.isHidden = true

        resultLabel.numberOfLines = 0
        resultLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
        resultLabel.adjustsFontForContentSizeCategory = true
        resultLabel.textColor = .secondaryLabel
        resultLabel.isHidden = true
        resultLabel.accessibilityLabel = "地图编译结果"

        importButton.setTitle("选择文件并导入", for: .normal)
        importButton.titleLabel?.font = UIFont.preferredFont(forTextStyle: .headline)
        importButton.titleLabel?.adjustsFontForContentSizeCategory = true
        importButton.addTarget(self, action: #selector(importTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [
            prompt,
            contractLabel,
            contractControl,
            percentLabel,
            progressView,
            statusLabel,
            elapsedLabel,
            resultLabel,
            importButton,
        ])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = UIScrollView()
        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .interactive
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -20),
            importButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    @objc private func importTapped() {
        let contract: CoordinateContract = contractControl.selectedSegmentIndex == 0
            ? .topLeft : .bottomLeft
        latestImportReport = nil
        progressFraction = 0
        importButton.isEnabled = false
        importButton.setTitle("导入处理中…", for: .normal)
        contractControl.isEnabled = false
        resultLabel.isHidden = true
        resultLabel.text = nil
        progressView.setProgress(0, animated: false)
        progressView.accessibilityValue = "0%"
        percentLabel.text = "0%"
        statusLabel.text = "正在打开文件选择器…"
        setProgressUIVisible(false)
        // Single unified entry: the coordinator runs pick → stage →
        // import → compile → register without any further page calls
        // (V1R2 §4.1). Concurrent taps are rejected with a typed error.
        let picker = preparedDocumentPicker
        preparedDocumentPicker = nil
        coordinator.beginMapImport(
            from: self,
            contract: contract,
            preparedDocumentPicker: picker)
    }

    private func prepareDocumentPickerIfNeeded() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.prepareDocumentPickerIfNeeded()
            }
            return
        }
        guard preparedDocumentPicker == nil,
              coordinator.state == .idle,
              presentedViewController == nil else {
            return
        }
        preparedDocumentPicker = MapSourceDocumentPicker
            .makePreparedViewController()
    }

    private func updateStatus(_ state: MobileOnlyWorkflowState) {
        switch state {
        case .idle:
            if progressFraction < 1 {
                statusLabel.text = "未选择地图文件，可以重新开始。"
                importButton.isEnabled = true
                contractControl.isEnabled = true
                importButton.setTitle("选择文件并导入", for: .normal)
                stopElapsedTimer()
                DispatchQueue.main.async { [weak self] in
                    self?.prepareDocumentPickerIfNeeded()
                }
            }
        case .pickingMap:
            statusLabel.text = "请在文件选择器中选择地图文件…"
        case .stagingMapSource:
            setProgressUIVisible(true)
            statusLabel.text = "正在安全暂存地图文件…"
        case .importingMap:
            setProgressUIVisible(true)
            statusLabel.text = "正在严格解析地图…"
        case .compilingMap:
            setProgressUIVisible(true)
            statusLabel.text = "正在手机端编译地图…"
        case .failed:
            statusLabel.text = coordinator.lastError?.errorDescription ?? "操作失败"
            importButton.isEnabled = true
            contractControl.isEnabled = true
            importButton.setTitle("重新选择文件", for: .normal)
            stopElapsedTimer()
        case .mapReady:
            statusLabel.text = "地图就绪"
        case .cancelled:
            statusLabel.text = "导入已取消"
            setProgressUIVisible(false)
            importButton.isEnabled = true
            contractControl.isEnabled = true
            importButton.setTitle("选择文件并导入", for: .normal)
            stopElapsedTimer()
            DispatchQueue.main.async { [weak self] in
                self?.prepareDocumentPickerIfNeeded()
            }
        default:
            break
        }
    }

    private func updateProgress(fraction: Double, message: String) {
        if !progressUIVisible {
            switch coordinator.state {
            case .stagingMapSource, .importingMap, .compilingMap, .mapReady:
                setProgressUIVisible(true)
            default:
                statusLabel.text = message
                return
            }
        }
        let bounded = min(1, max(0, fraction))
        progressFraction = max(progressFraction, bounded)
        progressView.setProgress(Float(progressFraction), animated: true)
        let percent = Int((progressFraction * 100).rounded())
        percentLabel.text = "\(percent)%"
        progressView.accessibilityValue = "\(percent)%"
        statusLabel.text = message
    }

    private func setProgressUIVisible(_ visible: Bool) {
        progressUIVisible = visible
        percentLabel.isHidden = !visible
        progressView.isHidden = !visible
        elapsedLabel.isHidden = !visible
        if visible {
            if elapsedTimer == nil {
                startElapsedTimer()
            }
        } else {
            elapsedTimer?.invalidate()
            elapsedTimer = nil
            startedAtUptime = nil
            elapsedLabel.text = "尚未开始"
        }
    }

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        startedAtUptime = ProcessInfo.processInfo.systemUptime
        updateElapsedLabel()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateElapsedLabel()
        }
        elapsedTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopElapsedTimer() {
        updateElapsedLabel()
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    private func updateElapsedLabel() {
        guard let started = startedAtUptime else {
            elapsedLabel.text = "尚未开始"
            return
        }
        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - started)
        elapsedLabel.text = String(format: "已用时 %.1f 秒", elapsed)
    }

    private func resultDetails(
        map: MobileMapLibrary.MapEntry,
        report: MapSourceImportReport?
    ) -> String {
        var lines = [
            "地图名称：\(map.name)",
            "地图 ID：\(map.priorMapID)",
            "地图包 SHA-256：\(map.packageSHA256)",
            "楼层：\(map.floorCount)",
            "编译后有效元素：\(map.elementCount)",
        ]
        if let report = report {
            lines.insert("门店 ID：\(report.storeId)", at: 1)
            lines.append("源格式：\(report.format.uppercased())")
            lines.append("源元素：\(report.elementCount)")
            lines.append("忽略元素：\(report.ignoredElementCount)")
            lines.append("导入警告：\(report.warningCount)")
            lines.append("源文件：\(formattedBytes(report.fileSizeBytes))")
            lines.append("Canonical SHA-256：\(report.canonicalSourceSha256)")
        }
        return lines.joined(separator: "\n")
    }

    private func alertDetails(
        map: MobileMapLibrary.MapEntry,
        report: MapSourceImportReport?
    ) -> String {
        var lines = [
            "\(map.name)",
            "地图 ID：\(map.priorMapID)",
            "包 SHA：\(map.packageSHA256.prefix(16))…",
            "\(map.floorCount) 层 · \(map.elementCount) 个有效元素",
        ]
        if let report = report {
            lines.insert("门店：\(report.storeId)", at: 1)
            lines.append("\(report.warningCount) 条导入警告 · \(report.ignoredElementCount) 个忽略元素")
        }
        lines.append("完整摘要已显示在导入页面。")
        return lines.joined(separator: "\n")
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        return ByteCountFormatter.string(
            fromByteCount: bytes,
            countStyle: .file)
    }
}
