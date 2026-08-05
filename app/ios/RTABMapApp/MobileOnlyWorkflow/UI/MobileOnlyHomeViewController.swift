import UIKit

/// Mobile-Only home screen: the four user-visible product entries
/// (V1R1 §5.3): 门店地图 / 开始门店扫描 / 处理历史扫描 / 历史结果.
/// Every entry is reachable from the app menu and drives the shared
/// workflow coordinator.
final class MobileOnlyHomeViewController: UIViewController {

    private struct Entry {
        let title: String
        let subtitle: String
        let symbol: String
        let action: () -> Void
    }

    private var entries: [Entry] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "MarketScanner"
        view.backgroundColor = .systemBackground

        entries = [
            Entry(
                title: "门店地图",
                subtitle: "导入地图文件并编译到手机地图库",
                symbol: "map",
                action: { [weak self] in self?.openMapLibrary() }),
            Entry(
                title: "开始门店扫描",
                subtitle: "选择手机编译地图，配置起点与朝向",
                symbol: "camera.viewfinder",
                action: { [weak self] in self?.openScanSetup() }),
            Entry(
                title: "处理历史扫描",
                subtitle: "对已结束的扫描会话生成四表结果",
                symbol: "wand.and.stars",
                action: { [weak self] in self?.openProcessing() }),
            Entry(
                title: "历史结果",
                subtitle: "查看并分享已生成的结果工作簿",
                symbol: "doc.text",
                action: { [weak self] in self?.openResults() }),
        ]

        buildUI()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // If a workflow state was left interrupted, surface it once.
        let state = MobileOnlyWorkflowCoordinator.shared.state
        if state.isResumable {
            presentInterruptedBanner(state)
        }
    }

    private func buildUI() {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        for entry in entries {
            let button = makeEntryButton(entry)
            stack.addArrangedSubview(button)
        }

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
    }

    private func makeEntryButton(_ entry: Entry) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.image = UIImage(systemName: entry.symbol)
        configuration.imagePadding = 12
        configuration.title = entry.title
        configuration.subtitle = entry.subtitle
        configuration.cornerStyle = .medium
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 14, leading: 16, bottom: 14, trailing: 16)
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in
            entry.action()
        })
        return button
    }

    private func presentInterruptedBanner(_ state: MobileOnlyWorkflowState) {
        let alert = UIAlertController(
            title: "上次流程未完成",
            message: "上次操作在「\(state.displayName)」时被中断，已安全恢复为中断状态。",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "知道了", style: .default))
        present(alert, animated: true)
    }

    // MARK: - Navigation

    private func openMapLibrary() {
        let navigation = UINavigationController(
            rootViewController: MobileMapLibraryViewController())
        present(navigation, animated: true)
    }

    private func openScanSetup() {
        let navigation = UINavigationController(
            rootViewController: MobileScanSetupViewController())
        present(navigation, animated: true)
    }

    private func openProcessing() {
        let navigation = UINavigationController(
            rootViewController: MobileProcessingViewController())
        present(navigation, animated: true)
    }

    private func openResults() {
        let navigation = UINavigationController(
            rootViewController: MobileResultViewController())
        present(navigation, animated: true)
    }
}
