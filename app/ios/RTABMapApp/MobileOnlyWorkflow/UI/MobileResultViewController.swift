import UIKit

/// Result screen (V1R1 Gate A / Gate J): shows the result package
/// summary and hands the real workbook URL to the system share sheet
/// (Gate A test A10).
final class MobileResultViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    /// Set by the processing screen when a run completes; otherwise the
    /// screen lists all historical results.
    var resultEntry: MobileResultLibrary.ResultEntry?

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private var results: [MobileResultLibrary.ResultEntry] = []
    private let shareButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "历史结果"
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close, target: self, action: #selector(close))

        tableView.dataSource = self
        tableView.delegate = self
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)

        shareButton.setTitle("分享工作簿", for: .normal)
        shareButton.addTarget(self, action: #selector(shareTapped), for: .touchUpInside)
        shareButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(shareButton)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: shareButton.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            shareButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            shareButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            shareButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            shareButton.heightAnchor.constraint(equalToConstant: 48),
        ])

        if let entry = resultEntry {
            results = [entry]
        } else {
            results = MobileResultLibrary.listResults()
        }
        tableView.reloadData()
    }

    @objc private func close() {
        dismiss(animated: true)
    }

    @objc private func shareTapped() {
        guard let entry = results.first else { return }
        ResultShareController.share(workbookURL: entry.workbookURL, from: self)
    }

    // MARK: - UITableViewDataSource

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return max(results.count, 1)
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "cell")
        if results.isEmpty {
            cell.textLabel?.text = "暂无结果，请先处理一次扫描。"
            cell.textLabel?.textColor = .secondaryLabel
            cell.detailTextLabel?.text = nil
            return cell
        }
        let entry = results[indexPath.row]
        let quality = entry.manifest["result_quality_status"] as? String
            ?? "COMPLETE"
        let publish = StrictJSONScalar.boolean(
            entry.manifest["publish_permitted"]) ?? false
        let productionPublish = StrictJSONScalar.boolean(
            entry.manifest["production_publish_permitted"]) ?? publish
        let scope = entry.manifest["result_scope"] as? String
            ?? (productionPublish ? "PRODUCTION" : "TEST")
        if productionPublish {
            cell.textLabel?.text = "\(entry.resultID) · 生产结果"
        } else if publish && scope == "TEST" {
            cell.textLabel?.text = "\(entry.resultID) · 完整测试结果"
        } else {
            cell.textLabel?.text = "\(entry.resultID) · 需要复核"
        }
        cell.textLabel?.textColor = .label
        let positions = StrictJSONScalar.integer(
            entry.manifest["coordinate_position_count"])
            ?? StrictJSONScalar.integer(
                entry.manifest["available_position_count"]) ?? 0
        let tags = StrictJSONScalar.integer(entry.manifest["tag_count"]) ?? 0
        cell.detailTextLabel?.numberOfLines = 2
        cell.detailTextLabel?.text =
            "\(quality) · 坐标 \(positions) · 价签 \(tags)\n"
            + "workbook SHA \(String(entry.workbookSHA256.prefix(16)))"
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    // MARK: - UITableViewDelegate

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !results.isEmpty else { return }
        let rescan = MobileRescanTasksViewController()
        rescan.resultEntry = results[indexPath.row]
        navigationController?.pushViewController(rescan, animated: true)
    }
}
