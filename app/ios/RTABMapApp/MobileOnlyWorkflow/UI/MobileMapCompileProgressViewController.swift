import UIKit

/// Compile progress screen (V1R1 Gate A §5.2): shows the compile
/// lifecycle and forwards to scan setup on success or an error on
/// failure. It is pushed automatically by the import wizard.
final class MobileMapCompileProgressViewController: UIViewController {

    private let coordinator = MobileOnlyWorkflowCoordinator.shared
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let statusLabel = UILabel()
    private var observerTokens: [MobileOnlyWorkflowCoordinator.ObserverToken] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "编译进度"
        view.backgroundColor = .systemBackground

        statusLabel.numberOfLines = 0
        statusLabel.text = "正在编译地图…"
        statusLabel.textColor = .label

        let stack = UIStackView(arrangedSubviews: [progressView, statusLabel])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 40),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])

        // Token observer (§5.3): this page never overwrites other pages'
        // callbacks.
        observerTokens.append(coordinator.addStateObserver { [weak self] state in
            self?.updateStatus(state)
        })
        observerTokens.append(coordinator.addProgressObserver { [weak self] fraction, _ in
            self?.progressView.setProgress(Float(max(0.1, fraction)), animated: true)
        })
    }

    deinit {
        for token in observerTokens {
            coordinator.removeObserver(token)
        }
    }

    private func updateStatus(_ state: MobileOnlyWorkflowState) {
        switch state {
        case .compilingMap:
            statusLabel.text = "正在编译地图…"
            progressView.setProgress(0.5, animated: true)
        case .mapReady:
            statusLabel.text = "编译完成"
            progressView.setProgress(1.0, animated: true)
        case .failed:
            statusLabel.text = coordinator.lastError?.errorDescription ?? "编译失败"
        default:
            break
        }
    }
}
