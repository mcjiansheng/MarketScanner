import UIKit

/// Compile progress screen (V1R1 Gate A §5.2): shows the compile
/// lifecycle and forwards to scan setup on success or an error on
/// failure. It is pushed automatically by the import wizard.
final class MobileMapCompileProgressViewController: UIViewController {

    private let coordinator = MobileOnlyWorkflowCoordinator.shared
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let percentLabel = UILabel()
    private let statusLabel = UILabel()
    private let elapsedLabel = UILabel()
    private let resultLabel = UILabel()
    private var observerTokens: [MobileOnlyWorkflowCoordinator.ObserverToken] = []
    private var latestImportReport: MapSourceImportReport?
    private var progressFraction = 0.0
    private var startedAtUptime: TimeInterval?
    private var elapsedTimer: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "编译进度"
        view.backgroundColor = .systemBackground

        percentLabel.text = "0%"
        percentLabel.font = UIFont.preferredFont(forTextStyle: .largeTitle)
        percentLabel.adjustsFontForContentSizeCategory = true
        percentLabel.textAlignment = .center
        percentLabel.accessibilityTraits = .updatesFrequently

        statusLabel.numberOfLines = 0
        statusLabel.text = "正在编译地图…"
        statusLabel.textColor = .label
        statusLabel.font = UIFont.preferredFont(forTextStyle: .headline)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textAlignment = .center

        elapsedLabel.textColor = .secondaryLabel
        elapsedLabel.font = UIFont.preferredFont(forTextStyle: .caption1)
        elapsedLabel.adjustsFontForContentSizeCategory = true
        elapsedLabel.textAlignment = .center

        resultLabel.numberOfLines = 0
        resultLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
        resultLabel.adjustsFontForContentSizeCategory = true
        resultLabel.textColor = .secondaryLabel
        resultLabel.isHidden = true
        resultLabel.accessibilityLabel = "地图编译结果"

        progressView.accessibilityLabel = "地图编译进度"
        progressView.accessibilityValue = "0%"

        let stack = UIStackView(arrangedSubviews: [
            percentLabel, progressView, statusLabel, elapsedLabel, resultLabel,
        ])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = UIScrollView()
        scrollView.alwaysBounceVertical = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 40),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -20),
        ])

        startElapsedTimer()

        // Token observer (§5.3): this page never overwrites other pages'
        // callbacks.
        observerTokens.append(coordinator.addStateObserver { [weak self] state in
            self?.updateStatus(state)
        })
        observerTokens.append(coordinator.addProgressObserver { [weak self] fraction, message in
            self?.updateProgress(fraction: fraction, message: message)
        })
        observerTokens.append(coordinator.addImportObserver { [weak self] result in
            if case .success(let report) = result {
                self?.latestImportReport = report
            }
        })
        observerTokens.append(coordinator.addCompileObserver { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let map):
                self.updateProgress(fraction: 1, message: "地图已编译、验证并注册")
                self.resultLabel.text = self.resultDetails(
                    map: map, report: self.latestImportReport)
                self.resultLabel.isHidden = false
                self.stopElapsedTimer()
            case .failure(let error):
                self.statusLabel.text = "编译失败：\(error.localizedDescription)"
                self.stopElapsedTimer()
            }
        })
    }

    deinit {
        elapsedTimer?.invalidate()
        for token in observerTokens {
            coordinator.removeObserver(token)
        }
    }

    private func updateStatus(_ state: MobileOnlyWorkflowState) {
        switch state {
        case .compilingMap:
            if progressFraction < 0.28 {
                statusLabel.text = "开始手机端地图编译"
            }
        case .mapReady:
            updateProgress(fraction: 1, message: "地图编译完成")
        case .failed:
            statusLabel.text = coordinator.lastError?.errorDescription ?? "编译失败"
            stopElapsedTimer()
        case .cancelled, .idle:
            if progressFraction < 1 {
                statusLabel.text = "地图编译已取消"
                stopElapsedTimer()
            }
        default:
            break
        }
    }

    private func updateProgress(fraction: Double, message: String) {
        let bounded = min(1, max(0, fraction))
        progressFraction = max(progressFraction, bounded)
        progressView.setProgress(Float(progressFraction), animated: true)
        let percent = Int((progressFraction * 100).rounded())
        percentLabel.text = "\(percent)%"
        progressView.accessibilityValue = "\(percent)%"
        statusLabel.text = message
    }

    private func startElapsedTimer() {
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
            lines.append("源元素：\(report.elementCount)")
            lines.append("忽略元素：\(report.ignoredElementCount)")
            lines.append("导入警告：\(report.warningCount)")
            lines.append("Canonical SHA-256：\(report.canonicalSourceSha256)")
        }
        return lines.joined(separator: "\n")
    }
}
