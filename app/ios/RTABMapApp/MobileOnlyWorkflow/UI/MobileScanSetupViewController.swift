import UIKit

/// Scan setup screen (V1R1 Gate A / §8.1): the scan wizard selects a
/// phone-compiled map from the on-device library (never a bundled
/// fixture), the floor and a start pose, then hands the configuration to
/// the workflow coordinator which starts the real scan.
final class MobileScanSetupViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    /// Set by the map library when navigating in with a chosen map.
    var selectedMap: MobileMapLibrary.MapEntry?

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let floorControl = UISegmentedControl()
    private let startButton = UIButton(type: .system)
    private var maps: [MobileMapLibrary.MapEntry] = []
    private var currentMap: MobileMapLibrary.MapEntry?

    private var startYawRad: Double = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "开始门店扫描"
        view.backgroundColor = .systemBackground

        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)

        startButton.setTitle("开始扫描", for: .normal)
        startButton.titleLabel?.font = UIFont.preferredFont(forTextStyle: .headline)
        startButton.addTarget(self, action: #selector(startScan), for: .touchUpInside)
        startButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(startButton)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: startButton.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            startButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            startButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            startButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            startButton.heightAnchor.constraint(equalToConstant: 48),
        ])

        reloadMaps()
    }

    private func reloadMaps() {
        maps = (try? MobileMapLibrary.listMaps()) ?? []
        if let selected = selectedMap {
            currentMap = selected
        } else {
            currentMap = maps.first
        }
        updateFloorControl()
    }

    private func updateFloorControl() {
        floorControl.removeAllSegments()
        guard let map = currentMap else { return }
        floorControl.insertSegment(withTitle: "楼层 1", at: 0, animated: false)
        floorControl.selectedSegmentIndex = 0
    }

    @objc private func startScan() {
        guard let map = currentMap else {
            presentNotice("请先在地图库中导入并编译一张地图。")
            return
        }
        guard let onStart = MobileOnlyWorkflowCoordinator.shared.onStartScan else {
            presentNotice("扫描入口尚未就绪（未连接扫描器）。")
            return
        }
        let floorID = "1"
        let configuration = MobileScanConfiguration(
            priorMap: map,
            floorID: floorID,
            startXM: 0,
            startYM: 0,
            startYawRad: startYawRad,
            storeID: "default")
        MobileOnlyWorkflowCoordinator.shared.beginScanSetup(map: map)
        onStart(configuration)
        dismiss(animated: true)
    }

    private func presentNotice(_ message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "知道了", style: .default))
        present(alert, animated: true)
    }

    // MARK: - UITableViewDataSource

    func numberOfSections(in tableView: UITableView) -> Int {
        return 2
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return section == 0 ? max(maps.count, 1) : 1
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return section == 0 ? "手机编译地图" : "起点朝向（弧度，默认 0）"
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        if indexPath.section == 0 {
            if maps.isEmpty {
                cell.textLabel?.text = "地图库为空，请先导入地图"
                cell.textLabel?.textColor = .secondaryLabel
            } else {
                let map = maps[indexPath.row]
                cell.textLabel?.text = "\(map.name)（\(map.floorCount) 层）"
                cell.textLabel?.textColor = .label
                cell.accessoryType = map.packageSHA256 == currentMap?.packageSHA256
                    ? .checkmark : .none
            }
        } else {
            cell.textLabel?.text = String(format: "yaw = %.2f rad", startYawRad)
            let slider = UISlider(frame: .zero)
            slider.minimumValue = -Float.pi
            slider.maximumValue = Float.pi
            slider.value = Float(startYawRad)
            slider.addTarget(self, action: #selector(yawChanged(_:)), for: .valueChanged)
            cell.contentView.addSubview(slider)
            slider.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                slider.centerYAnchor.constraint(equalTo: cell.contentView.centerYAnchor),
                slider.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -16),
                slider.widthAnchor.constraint(equalToConstant: 160),
            ])
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 0, !maps.isEmpty else { return }
        currentMap = maps[indexPath.row]
        updateFloorControl()
        tableView.reloadData()
    }

    @objc private func yawChanged(_ sender: UISlider) {
        startYawRad = Double(sender.value)
        tableView.reloadRows(at: [IndexPath(row: 0, section: 1)], with: .none)
    }
}
