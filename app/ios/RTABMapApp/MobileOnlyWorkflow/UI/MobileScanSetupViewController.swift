import UIKit

/// Scan setup screen (V1R3 Gate B §5): the scan wizard selects a
/// phone-compiled map from the on-device library (never a bundled
/// fixture), shows the REAL floor preview, lets the operator tap the
/// starting position and rotate the heading arrow, and commits the
/// configuration through `coordinator.commitScanConfiguration(_:)`.
///
/// Yaw convention (§5.1, frozen): yaw = 0 points along map +X, positive
/// is counter-clockwise. Golden directions: 0° → right, 90° → up,
/// 180° → left, -90° → down. The heading arrow is drawn pointing along
/// +X at yaw = 0 (the V1R2 arrow pointed up and silently carried a 90°
/// bias).
///
/// Traversability (§5.3): the tapped point must lie inside the floor
/// bounds, outside every obstacle polygon (shelves + fixed structures)
/// and keep a minimum clearance; illegal points show the reason and keep
/// the start button disabled. Store/floor identity gaps block the start
/// (§5.4).
final class MobileScanSetupViewController: UIViewController {

    /// Set by the map library when navigating in with a chosen map.
    var selectedMap: MobileMapLibrary.MapEntry?

    private struct FloorInfo {
        let id: String
        let bounds: [String: Double]
        let previewFile: String
    }

    /// Obstacle polygon in map metres for the selected floor.
    private struct Obstacle {
        let points: [(Double, Double)]
        let bounds: (minX: Double, minY: Double, maxX: Double, maxY: Double)
    }

    private enum TraversabilityFailure {
        case outsideFloorBounds
        case insideObstacle
        case insufficientClearance(Double)
        case evidenceCorrupt

        var reason: String {
            switch self {
            case .outsideFloorBounds:
                return "起点必须在楼层边界内"
            case .insideObstacle:
                return "起点不能落在货架/固定结构内"
            case .insufficientClearance(let distance):
                return String(format: "起点距离障碍物过近（%.2f m < %.2f m）",
                              distance, MobileScanSetupViewController.minimumClearanceM)
            case .evidenceCorrupt:
                return "地图障碍证据损坏，无法验证可通行性（请重新编译地图）"
            }
        }
    }

    static let minimumClearanceM = 0.30

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
    private var obstacles: [Obstacle] = []
    private var storeID: String = ""
    private var currentFloor: FloorInfo?
    private var startXM: Double?
    private var startYM: Double?
    private var startYawRad: Double = 0
    private var traversabilityFailure: TraversabilityFailure?
    /// H-10: set when any obstacle evidence artifact is missing,
    /// unparseable or malformed — fail closed, never treat the whole
    /// floor as traversable.
    private var obstacleEvidenceFailed = false

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

        // Start position marker (§5.2): explicit frame, managed without
        // AutoLayout so the rotation transform never changes the tap
        // coordinate. The arrow artwork points along +X (right) at
        // yaw = 0 (H-09): a horizontal bar on the marker's right side,
        // so `rotateMarker`'s negation-only chirality flip renders the
        // frozen yaw contract without any 90° bias.
        startMarker.isHidden = true
        startMarker.translatesAutoresizingMaskIntoConstraints = false
        startMarker.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        let markerDot = UIView(frame: CGRect(x: 16, y: 16, width: 12, height: 12))
        markerDot.backgroundColor = .systemRed
        markerDot.layer.cornerRadius = 6
        let arrow = UIView(frame: CGRect(x: 29, y: 21, width: 14, height: 2))
        arrow.backgroundColor = .systemRed
        startMarker.addSubview(arrow)
        startMarker.addSubview(markerDot)
        previewContainer.addSubview(startMarker)

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
    /// 0/0/1 (§5.4).
    private func loadSelectedMap() {
        floors = []
        storeID = ""
        resetStartPose()
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
        resetStartPose()
        loadObstacles(for: floor.id)
        guard let map = currentMap() else { return }
        let previewURL = map.packageDirectory.appendingPathComponent(floor.previewFile)
        previewImageView.image = UIImage(contentsOfFile: previewURL.path)
        updateSummary()
    }

    private func resetStartPose() {
        startXM = nil
        startYM = nil
        traversabilityFailure = nil
        startMarker.isHidden = true
    }

    /// Loads obstacle polygons (shelves + fixed structures) for the
    /// selected floor from the compiled package (§5.3).
    ///
    /// H-10: evidence is fail-closed — a missing/unparseable artifact,
    /// a missing element array, or a malformed geometry for THIS floor
    /// marks the evidence corrupt and blocks scan start instead of
    /// silently treating the floor as fully traversable.
    private func loadObstacles(for floorID: String) {
        obstacles = []
        obstacleEvidenceFailed = false
        guard let map = currentMap() else { return }
        for file in ["shelves.json", "fixed_structures.json"] {
            let url = map.packageDirectory.appendingPathComponent(file)
            guard let data = try? Data(contentsOf: url),
                  let object = try? StrictJSONDocumentParser.object(
                      from: data,
                      limits: StrictJSONDocumentLimits(maximumBytes: data.count + 1)) as? [String: Any]
            else {
                obstacleEvidenceFailed = true
                continue
            }
            let key = file == "shelves.json" ? "shelves" : "structures"
            guard let elements = object[key] as? [[String: Any]] else {
                obstacleEvidenceFailed = true
                continue
            }
            for element in elements {
                guard element["floor_id"] as? String == floorID else { continue }
                guard let geometry = element["geometry"] as? [String: Any],
                      let coordinates = geometry["coordinates"] as? [[Double]],
                      coordinates.allSatisfy({
                          $0.count >= 2 && $0[0].isFinite && $0[1].isFinite
                      })
                else {
                    obstacleEvidenceFailed = true
                    continue
                }
                var points: [(Double, Double)] = []
                for pair in coordinates where pair.count >= 2 {
                    points.append((pair[0], pair[1]))
                }
                // Closed polygon handling: drop the duplicated last point.
                if points.count >= 2,
                   abs(points.first!.0 - points.last!.0) < 1e-9,
                   abs(points.first!.1 - points.last!.1) < 1e-9 {
                    points.removeLast()
                }
                guard points.count >= 3 else {
                    obstacleEvidenceFailed = true
                    continue
                }
                var minX = Double.greatestFiniteMagnitude
                var minY = Double.greatestFiniteMagnitude
                var maxX = -Double.greatestFiniteMagnitude
                var maxY = -Double.greatestFiniteMagnitude
                for p in points {
                    minX = min(minX, p.0); minY = min(minY, p.1)
                    maxX = max(maxX, p.0); maxY = max(maxY, p.1)
                }
                obstacles.append(Obstacle(points: points, bounds: (minX, minY, maxX, maxY)))
            }
        }
    }

    // MARK: - Traversability (§5.3)

    private func traversability(at xM: Double, _ yM: Double) -> TraversabilityFailure? {
        // H-10: corrupt evidence fails closed — no point is considered
        // traversable until the artifacts parse cleanly.
        if obstacleEvidenceFailed {
            return .evidenceCorrupt
        }
        guard let floor = currentFloor,
              let minX = floor.bounds["min_x_m"], let minY = floor.bounds["min_y_m"],
              let maxX = floor.bounds["max_x_m"], let maxY = floor.bounds["max_y_m"]
        else { return .outsideFloorBounds }
        guard xM >= minX, xM <= maxX, yM >= minY, yM <= maxY else {
            return .outsideFloorBounds
        }
        var nearestDistance = Double.greatestFiniteMagnitude
        for obstacle in obstacles {
            // Envelope pre-check.
            guard xM >= obstacle.bounds.minX - Self.minimumClearanceM,
                  xM <= obstacle.bounds.maxX + Self.minimumClearanceM,
                  yM >= obstacle.bounds.minY - Self.minimumClearanceM,
                  yM <= obstacle.bounds.maxY + Self.minimumClearanceM
            else { continue }
            if pointInPolygon(xM, yM, obstacle.points) {
                return .insideObstacle
            }
            nearestDistance = min(
                nearestDistance, distanceToPolygon(xM, yM, obstacle.points))
        }
        if nearestDistance < Self.minimumClearanceM {
            return .insufficientClearance(nearestDistance)
        }
        return nil
    }

    private func pointInPolygon(_ x: Double, _ y: Double, _ polygon: [(Double, Double)]) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let xi = polygon[i].0, yi = polygon[i].1
            let xj = polygon[j].0, yj = polygon[j].1
            if (yi > y) != (yj > y),
               x < (xj - xi) * (y - yi) / (yj - yi) + xi {
                inside = !inside
            }
            j = i
        }
        return inside
    }

    private func distanceToPolygon(_ x: Double, _ y: Double, _ polygon: [(Double, Double)]) -> Double {
        var best = Double.greatestFiniteMagnitude
        for i in 0..<polygon.count {
            let a = polygon[i]
            let b = polygon[(i + 1) % polygon.count]
            let abx = b.0 - a.0, aby = b.1 - a.1
            let length2 = abx * abx + aby * aby
            var t = 0.0
            if length2 > 1e-12 {
                t = max(0.0, min(1.0, ((x - a.0) * abx + (y - a.1) * aby) / length2))
            }
            let px = a.0 + t * abx, py = a.1 + t * aby
            best = min(best, hypot(x - px, y - py))
        }
        return best
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
        traversabilityFailure = traversability(at: mapped.0, mapped.1)
        startMarker.isHidden = false
        var frame = startMarker.frame
        frame.origin = CGPoint(x: point.x - frame.width / 2, y: point.y - frame.height / 2)
        startMarker.frame = frame
        rotateMarker()
        updateSummary()
    }

    @objc private func yawChanged(_ sender: UISlider) {
        startYawRad = Double(sender.value)
        rotateMarker()
        updateSummary()
    }

    private func rotateMarker() {
        // Frozen yaw contract (§5.1): yaw = 0 along map +X (right in the
        // preview), positive counter-clockwise. The arrow artwork points
        // along +X, so only the map->image chirality flip (negation) is
        // applied — no residual 90° bias.
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
        guard !storeID.isEmpty else {
            summaryLabel.text = "地图包缺少 store_id（manifest 与预览不一致），请重新编译地图。"
            startButton.isEnabled = false
            return
        }
        guard let floor = currentFloor else {
            summaryLabel.text = "地图包没有可用楼层（manifest 与预览不一致）。"
            startButton.isEnabled = false
            return
        }
        // H-10: corrupt obstacle evidence blocks scan start.
        if obstacleEvidenceFailed {
            summaryLabel.text = "地图障碍证据损坏（shelves/fixed_structures），已阻止扫描启动，请重新编译地图。"
            startButton.isEnabled = false
            return
        }
        guard let x = startXM, let y = startYM else {
            summaryLabel.text = "已选「\(map.name)」，请在预览图上点选扫描起点。"
            startButton.isEnabled = false
            return
        }
        if let failure = traversabilityFailure {
            summaryLabel.text = "起点不可用：\(failure.reason)"
            startButton.isEnabled = false
            return
        }
        summaryLabel.text = String(
            format: "「%@」 楼层 %@ · 起点 (%.2f, %.2f) m · 朝向 %.2f rad",
            map.name, floor.id, x, y, startYawRad)
        startButton.isEnabled = true
    }

    // MARK: - Commit (§8.2)

    @objc private func startScan() {
        guard let map = currentMap(), let floor = currentFloor,
              let x = startXM, let y = startYM else {
            presentNotice("请先选择地图、楼层并点选起点。")
            return
        }
        guard traversabilityFailure == nil else {
            presentNotice("起点不可用：\(traversabilityFailure!.reason)")
            return
        }
        // H-10: defense in depth — never start with corrupt evidence.
        guard !obstacleEvidenceFailed else {
            presentNotice("地图障碍证据损坏，无法开始扫描，请重新编译地图。")
            return
        }
        guard !storeID.isEmpty else {
            presentNotice("地图包缺少 store_id，无法开始扫描。")
            return
        }
        let configuration = MobileScanConfiguration(
            priorMap: map,
            floorID: floor.id,
            startXM: x,
            startYM: y,
            startYawRad: startYawRad,
            storeID: storeID)
        // The page only commits; the coordinator validates the identity,
        // runs the transactional host start and reports failures (§4.3).
        coordinator.beginScanSetup(map: map)
        coordinator.commitScanConfiguration(configuration)
        if coordinator.state == .scanning {
            dismiss(animated: true)
        } else {
            presentNotice(coordinator.lastError?.errorDescription ?? "扫描启动失败")
        }
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
