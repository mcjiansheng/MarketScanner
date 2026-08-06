import UIKit

/// Scan setup screen (V1R2 Gate D §8.1/§8.2): the scan wizard selects a
/// phone-compiled map from the on-device library (never a bundled
/// fixture), shows the REAL floor preview, lets the operator tap the
/// starting position and rotate the heading arrow, and commits the
/// configuration through `coordinator.commitScanConfiguration(_:)`.
///
/// No hard-coded 0/0/1/default start pose (§8.1): the floor list comes
/// from the compiled package manifest and the start pose must be chosen
/// on the preview before the start button enables.
final class MobileScanSetupViewController: UIViewController {

    /// Set by the map library when navigating in with a chosen map.
    var selectedMap: MobileMapLibrary.MapEntry?

    private struct FloorInfo {
        let id: String
        let bounds: [String: Double]
        let previewFile: String
    }

    private let coordinator = MobileOnlyWorkflowCoordinator.shared
    private let mapPicker = UIPickerView()
    private let floorControl = UISegmentedControl()
    private let previewContainer = UIView()
    private let previewImageView = UIImageView()
    private let startMarker = UIView()
    private let yawSlider = UISlider()
    private let summaryLabel = UILabel()
    private let startButton = UIButton(type: .system)

    private var maps: [MobileMapLibrary.MapEntry] = []
    private var floors: [FloorInfo] = []
    private var storeID: String = ""
    private var currentFloor: FloorInfo?
    private var startXM: Double?
    private var startYM: Double?
    private var startYawRad: Double = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "开始门店扫描"
        view.backgroundColor = .systemBackground
        buildUI()
        reloadMaps()
    }

    private func buildUI() {
        mapPicker.dataSource = self
        mapPicker.delegate = self
        mapPicker.translatesAutoresizingMaskIntoConstraints = false

        floorControl.translatesAutoresizingMaskIntoConstraints = false
        floorControl.addTarget(self, action: #selector(floorChanged), for: .valueChanged)

        previewContainer.backgroundColor = .secondarySystemBackground
        previewContainer.layer.borderColor = UIColor.separator.cgColor
        previewContainer.layer.borderWidth = 1
        previewContainer.translatesAutoresizingMaskIntoConstraints = false
        previewImageView.contentMode = .scaleAspectFit
        previewImageView.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(previewImageView)

        // Start position marker with heading arrow.
        startMarker.isHidden = true
        let markerDot = UIView()
        markerDot.backgroundColor = .systemRed
        markerDot.layer.cornerRadius = 6
        markerDot.translatesAutoresizingMaskIntoConstraints = false
        let arrow = UIView()
        arrow.backgroundColor = .systemRed
        arrow.translatesAutoresizingMaskIntoConstraints = false
        arrow.tag = 99
        startMarker.addSubview(arrow)
        startMarker.addSubview(markerDot)
        startMarker.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(startMarker)
        NSLayoutConstraint.activate([
            markerDot.widthAnchor.constraint(equalToConstant: 12),
            markerDot.heightAnchor.constraint(equalToConstant: 12),
            markerDot.centerXAnchor.constraint(equalTo: startMarker.centerXAnchor),
            markerDot.centerYAnchor.constraint(equalTo: startMarker.centerYAnchor),
            arrow.widthAnchor.constraint(equalToConstant: 2),
            arrow.heightAnchor.constraint(equalToConstant: 22),
            arrow.centerXAnchor.constraint(equalTo: startMarker.centerXAnchor),
            arrow.bottomAnchor.constraint(equalTo: markerDot.topAnchor, constant: 4),
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(previewTapped(_:)))
        previewContainer.addGestureRecognizer(tap)

        yawSlider.minimumValue = -Float.pi
        yawSlider.maximumValue = Float.pi
        yawSlider.value = 0
        yawSlider.addTarget(self, action: #selector(yawChanged(_:)), for: .valueChanged)
        yawSlider.translatesAutoresizingMaskIntoConstraints = false

        summaryLabel.numberOfLines = 0
        summaryLabel.textColor = .secondaryLabel
        summaryLabel.text = "请选择地图、楼层，并在预览图上点选起点。"
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false

        startButton.setTitle("开始扫描", for: .normal)
        startButton.titleLabel?.font = UIFont.preferredFont(forTextStyle: .headline)
        startButton.isEnabled = false
        startButton.addTarget(self, action: #selector(startScan), for: .touchUpInside)
        startButton.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [
            mapPicker, floorControl, previewContainer, yawSlider, summaryLabel, startButton,
        ])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            previewContainer.heightAnchor.constraint(equalToConstant: 260),
            previewImageView.topAnchor.constraint(equalTo: previewContainer.topAnchor),
            previewImageView.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor),
            previewImageView.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
            previewImageView.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
        ])
    }

    // MARK: - Data

    private func reloadMaps() {
        maps = (try? MobileMapLibrary.listMaps()) ?? []
        mapPicker.reloadAllComponents()
        if let selected = selectedMap,
           let index = maps.firstIndex(where: { $0.packageSHA256 == selected.packageSHA256 }) {
            mapPicker.selectRow(index, inComponent: 0, animated: false)
        }
        loadSelectedMap()
    }

    private func currentMap() -> MobileMapLibrary.MapEntry? {
        let row = mapPicker.selectedRow(inComponent: 0)
        guard maps.indices.contains(row) else { return nil }
        return maps[row]
    }

    /// Reads the compiled package manifest: floors (with bounds and the
    /// per-floor preview file) and the real store id. Never defaults to
    /// 0/0/1 (§8.1).
    private func loadSelectedMap() {
        floors = []
        storeID = ""
        startXM = nil
        startYM = nil
        startMarker.isHidden = true
        guard let map = currentMap() else {
            floorControl.removeAllSegments()
            updateSummary()
            return
        }
        let manifestURL = map.packageDirectory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let object = try? StrictJSONDocumentParser.object(
                  from: data,
                  limits: StrictJSONDocumentLimits(maximumBytes: data.count + 1)) as? [String: Any]
        else {
            presentNotice("无法读取地图包 manifest，请重新编译地图。")
            updateSummary()
            return
        }
        storeID = object["store_id"] as? String ?? ""
        if let rawFloors = object["floors"] as? [[String: Any]] {
            for raw in rawFloors {
                guard let id = raw["id"] as? String,
                      let bounds = raw["bounds"] as? [String: Double],
                      let previewFile = raw["preview_file"] as? String
                else { continue }
                floors.append(FloorInfo(id: id, bounds: bounds, previewFile: previewFile))
            }
        }
        floorControl.removeAllSegments()
        for (index, floor) in floors.enumerated() {
            floorControl.insertSegment(withTitle: "楼层 \(floor.id)", at: index, animated: false)
        }
        if !floors.isEmpty {
            floorControl.selectedSegmentIndex = 0
            selectFloor(floors[0])
        }
        updateSummary()
    }

    private func selectFloor(_ floor: FloorInfo) {
        currentFloor = floor
        startXM = nil
        startYM = nil
        startMarker.isHidden = true
        guard let map = currentMap() else { return }
        let previewURL = map.packageDirectory.appendingPathComponent(floor.previewFile)
        previewImageView.image = UIImage(contentsOfFile: previewURL.path)
        updateSummary()
    }

    // MARK: - Start pose geometry

    /// Converts a point in the preview container to map metres using the
    /// exact projection of `MobilePreviewRenderer` (aspect-fit image, map
    /// y up / image y down).
    private func mapPoint(from containerPoint: CGPoint) -> (Double, Double)? {
        guard let floor = currentFloor,
              let image = previewImageView.image,
              let minX = floor.bounds["min_x_m"], let minY = floor.bounds["min_y_m"],
              let maxX = floor.bounds["max_x_m"], let maxY = floor.bounds["max_y_m"],
              maxX > minX, maxY > minY
        else { return nil }
        let containerSize = previewContainer.bounds.size
        guard containerSize.width > 0, containerSize.height > 0 else { return nil }
        // Aspect-fit rect of the image inside the container.
        let imageAspect = image.size.width / max(image.size.height, 1)
        let containerAspect = containerSize.width / containerSize.height
        let fittedSize: CGSize
        if imageAspect > containerAspect {
            fittedSize = CGSize(
                width: containerSize.width,
                height: containerSize.width / imageAspect)
        } else {
            fittedSize = CGSize(
                width: containerSize.height * imageAspect,
                height: containerSize.height)
        }
        let originX = (containerSize.width - fittedSize.width) / 2
        let originY = (containerSize.height - fittedSize.height) / 2
        let u = (containerPoint.x - originX) / fittedSize.width
        let v = (containerPoint.y - originY) / fittedSize.height
        guard u >= 0, u <= 1, v >= 0, v <= 1 else { return nil }
        let widthM = maxX - minX
        let heightM = maxY - minY
        let xM = minX + Double(u) * widthM
        let yM = minY + (1.0 - Double(v)) * heightM
        return (xM, yM)
    }

    @objc private func previewTapped(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: previewContainer)
        guard let mapped = mapPoint(from: point) else { return }
        startXM = mapped.0
        startYM = mapped.1
        startMarker.isHidden = false
        startMarker.center = point
        rotateMarker()
        updateSummary()
    }

    @objc private func yawChanged(_ sender: UISlider) {
        startYawRad = Double(sender.value)
        rotateMarker()
        updateSummary()
    }

    private func rotateMarker() {
        // Map yaw is counter-clockwise from +y (preview renderer
        // contract); UIKit rotation is clockwise, hence the negation.
        startMarker.transform = CGAffineTransform(rotationAngle: CGFloat(-startYawRad))
    }

    @objc private func floorChanged() {
        let index = floorControl.selectedSegmentIndex
        guard floors.indices.contains(index) else { return }
        selectFloor(floors[index])
    }

    private func updateSummary() {
        guard let map = currentMap() else {
            summaryLabel.text = "地图库为空，请先导入并编译地图。"
            startButton.isEnabled = false
            return
        }
        if let x = startXM, let y = startYM, let floor = currentFloor {
            summaryLabel.text = String(
                format: "「%@」 楼层 %@ · 起点 (%.2f, %.2f) m · 朝向 %.2f rad",
                map.name, floor.id, x, y, startYawRad)
            startButton.isEnabled = true
        } else {
            summaryLabel.text = "已选「\(map.name)」，请在预览图上点选扫描起点。"
            startButton.isEnabled = false
        }
    }

    // MARK: - Commit (§8.2)

    @objc private func startScan() {
        guard let map = currentMap(), let floor = currentFloor,
              let x = startXM, let y = startYM else {
            presentNotice("请先选择地图、楼层并点选起点。")
            return
        }
        let configuration = MobileScanConfiguration(
            priorMap: map,
            floorID: floor.id,
            startXM: x,
            startYM: y,
            startYawRad: startYawRad,
            storeID: storeID)
        // The page only commits; the coordinator validates the identity
        // and hands the configuration to the scanner host (§8.2).
        coordinator.beginScanSetup(map: map)
        coordinator.commitScanConfiguration(configuration)
        dismiss(animated: true)
    }

    private func presentNotice(_ message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "知道了", style: .default))
        present(alert, animated: true)
    }
}

extension MobileScanSetupViewController: UIPickerViewDataSource, UIPickerViewDelegate {
    func numberOfComponents(in pickerView: UIPickerView) -> Int { return 1 }

    func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
        return max(maps.count, 1)
    }

    func pickerView(_ pickerView: UIPickerView, titleForRow row: Int, forComponent component: Int) -> String? {
        guard maps.indices.contains(row) else { return "地图库为空" }
        return "\(maps[row].name)（\(maps[row].floorCount) 层）"
    }

    func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) {
        loadSelectedMap()
    }
}
