import UIKit

/// Map import wizard (V1R1 Gate A / Gate B): picks a file, lets the
/// user choose the source coordinate contract, then drives the strict
/// import + on-device compile through the workflow coordinator. The
/// coordinator owns the document picker strongly until the result
/// arrives (V1R1 §5.1).
final class MobileMapImportViewController: UIViewController {

    private let coordinator = MobileOnlyWorkflowCoordinator.shared
    private let contractControl = UISegmentedControl(
        items: ["左上原点", "左下原点"])
    private let statusLabel = UILabel()
    private let importButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "导入门店地图"
        view.backgroundColor = .systemBackground
        buildUI()

        coordinator.onStateChange = { [weak self] state in
            self?.updateStatus(state)
        }
    }

    deinit {
        coordinator.onStateChange = nil
    }

    private func buildUI() {
        let prompt = UILabel()
        prompt.text = "从「文件」选择 XLSX / CSV / JSON 门店地图，\n文件会先安全复制到应用私有目录。"
        prompt.numberOfLines = 0
        prompt.textColor = .secondaryLabel

        let contractLabel = UILabel()
        contractLabel.text = "原始坐标合同"

        contractControl.selectedSegmentIndex = 0

        statusLabel.numberOfLines = 0
        statusLabel.text = ""

        importButton.setTitle("选择文件并导入", for: .normal)
        importButton.addTarget(self, action: #selector(importTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [
            prompt, contractLabel, contractControl, statusLabel, importButton,
        ])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
    }

    @objc private func importTapped() {
        let contract: CoordinateContract = contractControl.selectedSegmentIndex == 0
            ? .topLeft : .bottomLeft
        importButton.isEnabled = false
        statusLabel.text = "正在打开文件选择器…"
        coordinator.beginMapImport(from: self)

        coordinator.onImportFinished = { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let report):
                self.statusLabel.text =
                    "解析完成：\(report.elementCount) 个元素，\(report.floorCount) 层，\(report.warningCount) 条警告。正在编译…"
                // Compilation runs inside importAndCompile; the progress
                // screen observes the coordinator state.
                self.coordinator.importAndCompile(contract: contract)
            case .failure(let error):
                self.statusLabel.text = "导入失败：\(error.localizedDescription)"
                self.importButton.isEnabled = true
            }
        }
        coordinator.onCompileFinished = { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let map):
                self.statusLabel.text = "编译完成，已加入地图库。"
                self.importButton.isEnabled = true
                let alert = UIAlertController(
                    title: "地图已就绪",
                    message: "「\(map.name)」已编译并注册（\(map.floorCount) 层 / \(map.elementCount) 元素）。",
                    preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "开始扫描", style: .default) { [weak self] _ in
                    guard let self = self else { return }
                    let setup = MobileScanSetupViewController()
                    setup.selectedMap = map
                    self.navigationController?.setViewControllers([setup], animated: true)
                })
                alert.addAction(UIAlertAction(title: "完成", style: .cancel) { [weak self] _ in
                    self?.navigationController?.popToRootViewController(animated: true)
                })
                self.present(alert, animated: true)
            case .failure(let error):
                self.statusLabel.text = "编译失败：\(error.localizedDescription)"
                self.importButton.isEnabled = true
            }
        }
    }

    private func updateStatus(_ state: MobileOnlyWorkflowState) {
        switch state {
        case .pickingMap:
            statusLabel.text = "请在文件选择器中选择地图文件…"
        case .importingMap:
            statusLabel.text = "正在严格解析地图…"
        case .compilingMap:
            statusLabel.text = "正在手机端编译地图…"
        case .failed:
            statusLabel.text = coordinator.lastError?.errorDescription ?? "操作失败"
            importButton.isEnabled = true
        case .mapReady:
            statusLabel.text = "地图就绪"
        default:
            break
        }
    }
}
