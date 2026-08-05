import UIKit

/// On-device map library browser (V1R1 Gate A / Gate C): lists maps
/// compiled on the phone from the durable registry and offers the
/// import entry point.
final class MobileMapLibraryViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private var maps: [MobileMapLibrary.MapEntry] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "门店地图"
        view.backgroundColor = .systemBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .add, target: self, action: #selector(importMap))
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close, target: self, action: #selector(close))

        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    private func reload() {
        do {
            maps = try MobileMapLibrary.listMaps()
        } catch {
            maps = []
            let alert = UIAlertController(
                title: "地图库不可用",
                message: error.localizedDescription,
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "重建索引", style: .default) { [weak self] _ in
                try? MobileMapLibrary.rebuildRegistry()
                self?.reload()
            })
            alert.addAction(UIAlertAction(title: "取消", style: .cancel))
            present(alert, animated: true)
        }
        tableView.reloadData()
    }

    @objc private func importMap() {
        let importer = MobileMapImportViewController()
        navigationController?.pushViewController(importer, animated: true)
    }

    @objc private func close() {
        dismiss(animated: true)
    }

    // MARK: - UITableViewDataSource

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return maps.isEmpty ? 1 : maps.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        if maps.isEmpty {
            cell.textLabel?.text = "暂无地图，点击右上角 + 导入"
            cell.textLabel?.textColor = .secondaryLabel
            cell.accessoryType = .none
            return cell
        }
        let map = maps[indexPath.row]
        cell.textLabel?.text = "\(map.name)（\(map.floorCount) 层）"
        cell.textLabel?.textColor = .label
        cell.detailTextLabel?.text = "\(map.elementCount) 元素 · SHA \(String(map.packageSHA256.prefix(12)))"
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    // MARK: - UITableViewDelegate

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !maps.isEmpty else { return }
        let map = maps[indexPath.row]
        let setup = MobileScanSetupViewController()
        setup.selectedMap = map
        navigationController?.pushViewController(setup, animated: true)
    }
}
