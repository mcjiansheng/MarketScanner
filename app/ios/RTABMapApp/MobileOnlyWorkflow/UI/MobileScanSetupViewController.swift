import UIKit
import AVFoundation

/// Canonical prior-map scan setup used by every production map source.
///
/// Expensive registry/package work is deliberately kept off the main
/// thread. A package is read and validated once into `PriorMapPackage`,
/// then the same typed object is passed through the coordinator to the
/// scanner host. This keeps navigation responsive without weakening the
/// package-integrity gate.
final class MobileScanSetupViewController: UIViewController {

    /// The setup screen is entered only after an explicit lightweight
    /// library selection. Keeping this immutable prevents an accidental
    /// picker change from starting another expensive package load.
    private let selectedMap: MobileMapLibrary.MapEntry

    private struct Obstacle {
        let points: [(Double, Double)]
        let bounds: (minX: Double, minY: Double, maxX: Double, maxY: Double)
    }

    private struct SetupPayload {
        let package: PriorMapPackage
        let obstaclesByFloor: [String: [Obstacle]]
    }

    private enum TraversabilityFailure {
        case outsideFloorBounds
        case insideObstacle
        case insufficientClearance(Double)

        var reason: String {
            switch self {
            case .outsideFloorBounds:
                return "起点必须在楼层边界内"
            case .insideObstacle:
                return "起点不能落在货架或固定结构内"
            case .insufficientClearance(let distance):
                return String(
                    format: "起点距离障碍物过近（%.2f m < %.2f m）",
                    distance,
                    MobileScanSetupViewController.minimumClearanceM)
            }
        }
    }

    static let minimumClearanceM = 0.30

    private let coordinator = MobileOnlyWorkflowCoordinator.shared
    private let loadQueue = DispatchQueue(
        label: "MarketScanner.ScanSetupLoad",
        qos: .userInitiated)

    private let formScrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let floorControl = UISegmentedControl()
    private let loadingIndicator = UIActivityIndicatorView(style: .medium)
    private let loadingLabel = UILabel()

    private let mapScrollView = UIScrollView()
    private let mapCanvasView = UIView()
    private let previewImageView = UIImageView()
    private let startMarker = UIView()
    private let markerDot = UIView()
    private let markerArrow = UIView()

    private let positionStepControl = UISegmentedControl(
        items: ["0.1 m", "0.5 m", "1.0 m"])
    private let headingControl = UISegmentedControl(
        items: ["东 0°", "北 90°", "西 180°", "南 270°"])
    private let headingLabel = UILabel()
    private let summaryLabel = UILabel()
    private let startButton = UIButton(type: .system)

    private var payload: SetupPayload?
    private var selectedFloorIndex = 0
    private var startXM: Double?
    private var startYM: Double?
    private var startYawRad: Double = 0
    private var traversabilityFailure: TraversabilityFailure?
    private var loadingGeneration = UUID()
    private var lastCanvasViewportSize = CGSize.zero
    private var startInFlight = false
    private var cameraPermissionRequestInFlight = false
    private var observerTokens: [MobileOnlyWorkflowCoordinator.ObserverToken] = []

    init(selectedMap: MobileMapLibrary.MapEntry) {
        self.selectedMap = selectedMap
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "开始门店扫描"
        view.backgroundColor = .systemBackground
        buildUI()
        registerWorkflowObservers()
        loadMap(selectedMap)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        installRootCloseButtonIfNeeded()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        configureCanvasForCurrentViewportIfNeeded()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // A pushed setup page can still leave through the navigation back
        // gesture/button while the background start transaction is running.
        // Leaving the page is an explicit cancellation request: the
        // coordinator cancels before host start or rolls back after receipt.
        if startInFlight {
            coordinator.cancelScanStart()
        }
    }

    deinit {
        for token in observerTokens {
            coordinator.removeObserver(token)
        }
    }

    private func installRootCloseButtonIfNeeded() {
        guard let navigation = navigationController,
              navigation.viewControllers.first === self else {
            return
        }
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close,
            target: self,
            action: #selector(close))
    }

    @objc private func close() {
        if startInFlight {
            loadingLabel.text = "正在取消扫描启动并清理会话…"
            coordinator.cancelScanStart()
            return
        }
        guard !cameraPermissionRequestInFlight else { return }
        dismiss(animated: true)
    }

    private func buildUI() {
        formScrollView.alwaysBounceVertical = true
        formScrollView.keyboardDismissMode = .interactive
        formScrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(formScrollView)

        contentStack.axis = .vertical
        contentStack.spacing = 14
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        formScrollView.addSubview(contentStack)

        floorControl.addTarget(
            self, action: #selector(floorChanged), for: .valueChanged)
        floorControl.accessibilityLabel = "扫描楼层"

        loadingIndicator.hidesWhenStopped = true
        loadingLabel.font = UIFont.preferredFont(forTextStyle: .subheadline)
        loadingLabel.textColor = .secondaryLabel
        loadingLabel.numberOfLines = 0
        let loadingRow = UIStackView(arrangedSubviews: [
            loadingIndicator, loadingLabel, UIView(),
        ])
        loadingRow.axis = .horizontal
        loadingRow.alignment = .center
        loadingRow.spacing = 10

        configureMapEditor()

        let positionTitle = sectionLabel("微调起点位置")
        positionStepControl.selectedSegmentIndex = 1
        positionStepControl.accessibilityLabel = "位置微调步长"
        let positionPad = makePositionPad()

        let headingTitle = sectionLabel("微调起始朝向")
        headingControl.selectedSegmentIndex = 0
        headingControl.addTarget(
            self, action: #selector(cardinalHeadingChanged), for: .valueChanged)
        headingControl.accessibilityLabel = "朝向快捷选择"
        headingLabel.font = UIFont.monospacedDigitSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize,
            weight: .semibold)
        headingLabel.textAlignment = .center
        headingLabel.adjustsFontForContentSizeCategory = true
        let headingNudgeRow = makeHeadingNudgeRow()

        summaryLabel.numberOfLines = 0
        summaryLabel.font = UIFont.preferredFont(forTextStyle: .subheadline)
        summaryLabel.textColor = .secondaryLabel
        summaryLabel.accessibilityIdentifier = "mobile.scan.setup.summary"

        startButton.setTitle("开始门店扫描", for: .normal)
        startButton.titleLabel?.font = UIFont.preferredFont(
            forTextStyle: .headline)
        startButton.titleLabel?.adjustsFontForContentSizeCategory = true
        startButton.isEnabled = false
        startButton.accessibilityHint = "验证地图和起点后启动连续扫描"
        startButton.addTarget(
            self, action: #selector(startScan), for: .touchUpInside)
        startButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 50)
            .isActive = true

        [
            floorControl,
            loadingRow,
            mapScrollView,
            positionTitle,
            positionStepControl,
            positionPad,
            headingTitle,
            headingControl,
            headingNudgeRow,
            headingLabel,
            summaryLabel,
            startButton,
        ].forEach(contentStack.addArrangedSubview)

        NSLayoutConstraint.activate([
            formScrollView.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor),
            formScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            formScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            formScrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            contentStack.topAnchor.constraint(
                equalTo: formScrollView.contentLayoutGuide.topAnchor,
                constant: 12),
            contentStack.leadingAnchor.constraint(
                equalTo: formScrollView.frameLayoutGuide.leadingAnchor,
                constant: 16),
            contentStack.trailingAnchor.constraint(
                equalTo: formScrollView.frameLayoutGuide.trailingAnchor,
                constant: -16),
            contentStack.bottomAnchor.constraint(
                equalTo: formScrollView.contentLayoutGuide.bottomAnchor,
                constant: -24),
            mapScrollView.heightAnchor.constraint(equalToConstant: 310),
        ])
        updateHeadingLabel()
    }

    private func sectionLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = UIFont.preferredFont(forTextStyle: .headline)
        label.adjustsFontForContentSizeCategory = true
        return label
    }

    private func configureMapEditor() {
        mapScrollView.delegate = self
        mapScrollView.minimumZoomScale = 1
        mapScrollView.maximumZoomScale = 8
        mapScrollView.bouncesZoom = true
        mapScrollView.showsHorizontalScrollIndicator = true
        mapScrollView.showsVerticalScrollIndicator = true
        mapScrollView.backgroundColor = .secondarySystemBackground
        mapScrollView.layer.borderColor = UIColor.separator.cgColor
        mapScrollView.layer.borderWidth = 1
        mapScrollView.layer.cornerRadius = 10
        mapScrollView.clipsToBounds = true
        mapScrollView.accessibilityLabel = "地图预览，可双击或捏合缩放"

        previewImageView.contentMode = .scaleToFill
        previewImageView.frame = .zero
        previewImageView.isUserInteractionEnabled = true
        mapCanvasView.addSubview(previewImageView)

        startMarker.frame = CGRect(x: 0, y: 0, width: 48, height: 48)
        startMarker.isHidden = true
        startMarker.isUserInteractionEnabled = false
        markerDot.frame = CGRect(x: 18, y: 18, width: 12, height: 12)
        markerDot.backgroundColor = .systemRed
        markerDot.layer.cornerRadius = 6
        markerDot.layer.borderWidth = 2
        markerDot.layer.borderColor = UIColor.systemBackground.cgColor
        markerArrow.frame = CGRect(x: 29, y: 22, width: 17, height: 4)
        markerArrow.backgroundColor = .systemRed
        markerArrow.layer.cornerRadius = 2
        startMarker.addSubview(markerArrow)
        startMarker.addSubview(markerDot)
        mapCanvasView.addSubview(startMarker)
        mapScrollView.addSubview(mapCanvasView)

        let tap = UITapGestureRecognizer(
            target: self, action: #selector(previewTapped(_:)))
        let doubleTap = UITapGestureRecognizer(
            target: self, action: #selector(previewDoubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        tap.require(toFail: doubleTap)
        mapCanvasView.addGestureRecognizer(tap)
        mapCanvasView.addGestureRecognizer(doubleTap)
    }

    private func makePositionPad() -> UIView {
        func nudgeButton(
            symbol: String,
            label: String,
            action: Selector
        ) -> UIButton {
            let button = UIButton(type: .system)
            button.setImage(UIImage(systemName: symbol), for: .normal)
            button.accessibilityLabel = label
            button.addTarget(self, action: action, for: .touchUpInside)
            button.backgroundColor = .tertiarySystemBackground
            button.layer.cornerRadius = 10
            button.widthAnchor.constraint(equalToConstant: 52).isActive = true
            button.heightAnchor.constraint(equalToConstant: 48).isActive = true
            return button
        }

        let up = nudgeButton(
            symbol: "arrow.up", label: "起点向北微调", action: #selector(nudgeUp))
        let down = nudgeButton(
            symbol: "arrow.down", label: "起点向南微调", action: #selector(nudgeDown))
        let left = nudgeButton(
            symbol: "arrow.left", label: "起点向西微调", action: #selector(nudgeLeft))
        let right = nudgeButton(
            symbol: "arrow.right", label: "起点向东微调", action: #selector(nudgeRight))
        let centre = UILabel()
        centre.text = "起点"
        centre.textAlignment = .center
        centre.textColor = .secondaryLabel
        centre.widthAnchor.constraint(equalToConstant: 52).isActive = true
        centre.heightAnchor.constraint(equalToConstant: 48).isActive = true

        let top = UIStackView(arrangedSubviews: [UIView(), up, UIView()])
        let middle = UIStackView(arrangedSubviews: [left, centre, right])
        let bottom = UIStackView(arrangedSubviews: [UIView(), down, UIView()])
        for row in [top, middle, bottom] {
            row.axis = .horizontal
            row.alignment = .center
            row.distribution = .equalCentering
        }
        let pad = UIStackView(arrangedSubviews: [top, middle, bottom])
        pad.axis = .vertical
        pad.spacing = 6
        return pad
    }

    private func makeHeadingNudgeRow() -> UIView {
        let left = UIButton(type: .system)
        left.setTitle("↶ 15°", for: .normal)
        left.titleLabel?.font = UIFont.preferredFont(forTextStyle: .headline)
        left.accessibilityLabel = "朝向向左旋转十五度"
        left.addTarget(self, action: #selector(turnLeft), for: .touchUpInside)

        let right = UIButton(type: .system)
        right.setTitle("15° ↷", for: .normal)
        right.titleLabel?.font = UIFont.preferredFont(forTextStyle: .headline)
        right.accessibilityLabel = "朝向向右旋转十五度"
        right.addTarget(self, action: #selector(turnRight), for: .touchUpInside)

        for button in [left, right] {
            button.backgroundColor = .tertiarySystemBackground
            button.layer.cornerRadius = 10
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 48)
                .isActive = true
        }
        let row = UIStackView(arrangedSubviews: [left, right])
        row.axis = .horizontal
        row.spacing = 12
        row.distribution = .fillEqually
        return row
    }

    // MARK: - Background loading

    private func loadMap(_ map: MobileMapLibrary.MapEntry) {
        let generation = UUID()
        loadingGeneration = generation
        payload = nil
        resetStartPose()
        clearPreview()
        setLoading(true, message: "正在后台验证并加载「\(map.name)」…")

        loadQueue.async { [weak self] in
            let result = Result { () throws -> SetupPayload in
                let package = try PriorMapPackage.load(
                    directory: map.packageDirectory)
                guard package.manifest.priorMapId == map.priorMapID,
                      package.packageSha256 == map.packageSHA256,
                      package.manifest.name == map.name,
                      package.manifest.floors.count == map.floorCount,
                      package.manifest.elementCount == map.elementCount,
                      package.manifest.canonicalSourceSha256
                        == map.canonicalSourceSHA256 else {
                    throw MobileOnlyWorkflowError.invalidState(
                        "地图注册身份与地图包内容不一致")
                }
                return SetupPayload(
                    package: package,
                    obstaclesByFloor: Self.buildObstacleIndex(package))
            }
            DispatchQueue.main.async {
                guard let self = self,
                      self.loadingGeneration == generation else { return }
                switch result {
                case .success(let payload):
                    self.payload = payload
                    self.selectedFloorIndex = 0
                    self.rebuildFloorControl()
                    self.applySelectedFloor(resetZoom: true)
                    self.setLoading(false, message: "地图验证完成，可选择起点。")
                case .failure(let error):
                    self.payload = nil
                    self.rebuildFloorControl()
                    self.clearPreview()
                    self.setLoading(false, message: "地图验证失败")
                    self.presentNotice(
                        "地图无法用于扫描：\(error.localizedDescription)\n\n源地图和已有扫描数据均未修改。")
                }
                self.updateSummary()
            }
        }
    }

    private static func buildObstacleIndex(
        _ package: PriorMapPackage
    ) -> [String: [Obstacle]] {
        var result: [String: [Obstacle]] = [:]
        func append(
            floorID: String,
            coordinates: [[Double]]
        ) {
            var points = coordinates.compactMap { pair -> (Double, Double)? in
                guard pair.count >= 2,
                      pair[0].isFinite,
                      pair[1].isFinite else { return nil }
                return (pair[0], pair[1])
            }
            if let first = points.first,
               let last = points.last,
               points.count >= 2,
               abs(first.0 - last.0) < 1e-9,
               abs(first.1 - last.1) < 1e-9 {
                points.removeLast()
            }
            guard points.count >= 3 else { return }
            let xs = points.map { $0.0 }
            let ys = points.map { $0.1 }
            guard let minX = xs.min(), let minY = ys.min(),
                  let maxX = xs.max(), let maxY = ys.max() else {
                return
            }
            result[floorID, default: []].append(Obstacle(
                points: points,
                bounds: (minX, minY, maxX, maxY)))
        }
        for shelf in package.shelves {
            append(
                floorID: shelf.floorId,
                coordinates: shelf.geometry.coordinates)
        }
        for structure in package.fixedStructures {
            append(
                floorID: structure.floorId,
                coordinates: structure.geometry.coordinates)
        }
        return result
    }

    private func setLoading(_ loading: Bool, message: String) {
        loadingLabel.text = message
        if loading {
            loadingIndicator.startAnimating()
        } else {
            loadingIndicator.stopAnimating()
        }
        floorControl.isEnabled = !loading
            && !startInFlight
            && !cameraPermissionRequestInFlight
        updateSummary()
    }

    // MARK: - Floor and canvas

    private var currentFloor: PriorMapFloor? {
        guard let floors = payload?.package.manifest.floors,
              floors.indices.contains(selectedFloorIndex) else { return nil }
        return floors[selectedFloorIndex]
    }

    private var currentObstacles: [Obstacle] {
        guard let floorID = currentFloor?.id else { return [] }
        return payload?.obstaclesByFloor[floorID] ?? []
    }

    private func rebuildFloorControl() {
        floorControl.removeAllSegments()
        guard let floors = payload?.package.manifest.floors else { return }
        for (index, floor) in floors.enumerated() {
            floorControl.insertSegment(
                withTitle: "楼层 \(floor.id)", at: index, animated: false)
        }
        if !floors.isEmpty {
            selectedFloorIndex = min(selectedFloorIndex, floors.count - 1)
            floorControl.selectedSegmentIndex = selectedFloorIndex
        }
    }

    @objc private func floorChanged() {
        selectedFloorIndex = max(0, floorControl.selectedSegmentIndex)
        applySelectedFloor(resetZoom: true)
    }

    private func applySelectedFloor(resetZoom: Bool) {
        resetStartPose()
        guard let floor = currentFloor,
              let package = payload?.package else {
            clearPreview()
            return
        }
        previewImageView.image = package.preview(floorId: floor.id)
        lastCanvasViewportSize = .zero
        view.setNeedsLayout()
        view.layoutIfNeeded()
        if resetZoom {
            mapScrollView.setZoomScale(1, animated: false)
        }
        updateSummary()
    }

    private func clearPreview() {
        previewImageView.image = nil
        mapCanvasView.frame = .zero
        previewImageView.frame = .zero
        startMarker.isHidden = true
        lastCanvasViewportSize = .zero
    }

    private func configureCanvasForCurrentViewportIfNeeded() {
        guard let image = previewImageView.image else { return }
        let viewport = mapScrollView.bounds.size
        guard viewport.width > 1, viewport.height > 1,
              viewport != lastCanvasViewportSize else { return }
        lastCanvasViewportSize = viewport
        let imageAspect = image.size.width / max(image.size.height, 1)
        let viewportAspect = viewport.width / viewport.height
        let fitted: CGSize
        if imageAspect > viewportAspect {
            fitted = CGSize(
                width: viewport.width,
                height: viewport.width / imageAspect)
        } else {
            fitted = CGSize(
                width: viewport.height * imageAspect,
                height: viewport.height)
        }
        mapCanvasView.frame = CGRect(origin: .zero, size: fitted)
        previewImageView.frame = mapCanvasView.bounds
        mapScrollView.contentSize = fitted
        mapScrollView.zoomScale = 1
        centreCanvas()
        updateMarkerPosition()
    }

    private func centreCanvas() {
        let horizontal = max(
            0, (mapScrollView.bounds.width - mapScrollView.contentSize.width) / 2)
        let vertical = max(
            0, (mapScrollView.bounds.height - mapScrollView.contentSize.height) / 2)
        mapScrollView.contentInset = UIEdgeInsets(
            top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }

    @objc private func previewTapped(_ gesture: UITapGestureRecognizer) {
        guard payload != nil else { return }
        let point = gesture.location(in: mapCanvasView)
        guard let mapped = mapPoint(fromCanvasPoint: point) else { return }
        setStartPosition(xM: mapped.0, yM: mapped.1)
    }

    @objc private func previewDoubleTapped(_ gesture: UITapGestureRecognizer) {
        let target: CGFloat = mapScrollView.zoomScale > 1.05
            ? 1 : min(4, mapScrollView.maximumZoomScale)
        if target == 1 {
            mapScrollView.setZoomScale(1, animated: true)
            return
        }
        let point = gesture.location(in: mapCanvasView)
        let size = CGSize(
            width: mapScrollView.bounds.width / target,
            height: mapScrollView.bounds.height / target)
        mapScrollView.zoom(
            to: CGRect(
                x: point.x - size.width / 2,
                y: point.y - size.height / 2,
                width: size.width,
                height: size.height),
            animated: true)
    }

    private func mapPoint(
        fromCanvasPoint point: CGPoint
    ) -> (Double, Double)? {
        guard let floor = currentFloor,
              mapCanvasView.bounds.width > 0,
              mapCanvasView.bounds.height > 0 else { return nil }
        let u = point.x / mapCanvasView.bounds.width
        let v = point.y / mapCanvasView.bounds.height
        guard u >= 0, u <= 1, v >= 0, v <= 1 else { return nil }
        let x = floor.bounds.minXM
            + Double(u) * (floor.bounds.maxXM - floor.bounds.minXM)
        let y = floor.bounds.minYM
            + (1 - Double(v)) * (floor.bounds.maxYM - floor.bounds.minYM)
        return (x, y)
    }

    private func canvasPoint(xM: Double, yM: Double) -> CGPoint? {
        guard let floor = currentFloor,
              floor.bounds.maxXM > floor.bounds.minXM,
              floor.bounds.maxYM > floor.bounds.minYM else { return nil }
        let u = (xM - floor.bounds.minXM)
            / (floor.bounds.maxXM - floor.bounds.minXM)
        let v = 1 - (yM - floor.bounds.minYM)
            / (floor.bounds.maxYM - floor.bounds.minYM)
        return CGPoint(
            x: CGFloat(u) * mapCanvasView.bounds.width,
            y: CGFloat(v) * mapCanvasView.bounds.height)
    }

    private func resetStartPose() {
        startXM = nil
        startYM = nil
        traversabilityFailure = nil
        startMarker.isHidden = true
    }

    private func setStartPosition(xM: Double, yM: Double) {
        startXM = xM
        startYM = yM
        traversabilityFailure = traversability(at: xM, yM)
        updateMarkerPosition()
        updateSummary()
    }

    private func updateMarkerPosition() {
        guard let x = startXM,
              let y = startYM,
              let point = canvasPoint(xM: x, yM: y) else {
            startMarker.isHidden = true
            return
        }
        startMarker.isHidden = false
        startMarker.bounds = CGRect(x: 0, y: 0, width: 48, height: 48)
        startMarker.center = point
        rotateMarker()
    }

    // MARK: - Position and heading controls

    private var positionStepM: Double {
        switch positionStepControl.selectedSegmentIndex {
        case 0: return 0.1
        case 2: return 1.0
        default: return 0.5
        }
    }

    private func nudge(dx: Double, dy: Double) {
        guard let x = startXM, let y = startYM else {
            guard let floor = currentFloor else { return }
            setStartPosition(
                xM: (floor.bounds.minXM + floor.bounds.maxXM) / 2 + dx,
                yM: (floor.bounds.minYM + floor.bounds.maxYM) / 2 + dy)
            return
        }
        setStartPosition(xM: x + dx, yM: y + dy)
    }

    @objc private func nudgeUp() {
        nudge(dx: 0, dy: positionStepM)
    }

    @objc private func nudgeDown() {
        nudge(dx: 0, dy: -positionStepM)
    }

    @objc private func nudgeLeft() {
        nudge(dx: -positionStepM, dy: 0)
    }

    @objc private func nudgeRight() {
        nudge(dx: positionStepM, dy: 0)
    }

    @objc private func cardinalHeadingChanged() {
        switch headingControl.selectedSegmentIndex {
        case 1: startYawRad = Double.pi / 2
        case 2: startYawRad = Double.pi
        case 3: startYawRad = -Double.pi / 2
        default: startYawRad = 0
        }
        rotateMarker()
        updateHeadingLabel()
        updateSummary()
    }

    @objc private func turnLeft() {
        startYawRad = normalizeYaw(startYawRad + 15 * Double.pi / 180)
        headingControl.selectedSegmentIndex = UISegmentedControl.noSegment
        rotateMarker()
        updateHeadingLabel()
        updateSummary()
    }

    @objc private func turnRight() {
        startYawRad = normalizeYaw(startYawRad - 15 * Double.pi / 180)
        headingControl.selectedSegmentIndex = UISegmentedControl.noSegment
        rotateMarker()
        updateHeadingLabel()
        updateSummary()
    }

    private func normalizeYaw(_ value: Double) -> Double {
        var result = value
        while result > Double.pi { result -= 2 * Double.pi }
        while result <= -Double.pi { result += 2 * Double.pi }
        return result
    }

    private func rotateMarker() {
        // Canonical map yaw is 0 = +X/right and +pi/2 = +Y/up. UIKit's
        // y-down projection requires only the shared chirality inversion.
        let inverseZoom = 1 / max(mapScrollView.zoomScale, 0.001)
        startMarker.transform = PriorMapHeadingUI
            .screenTransform(yawRad: startYawRad)
            .scaledBy(x: inverseZoom, y: inverseZoom)
    }

    private func updateHeadingLabel() {
        var degrees = startYawRad * 180 / Double.pi
        if degrees < 0 { degrees += 360 }
        headingLabel.text = String(format: "当前朝向 %.0f°", degrees)
        headingLabel.accessibilityLabel = String(
            format: "当前朝向 %.0f 度", degrees)
    }

    // MARK: - Traversability

    private func traversability(
        at xM: Double,
        _ yM: Double
    ) -> TraversabilityFailure? {
        guard let floor = currentFloor,
              xM >= floor.bounds.minXM,
              xM <= floor.bounds.maxXM,
              yM >= floor.bounds.minYM,
              yM <= floor.bounds.maxYM else {
            return .outsideFloorBounds
        }
        var nearestDistance = Double.greatestFiniteMagnitude
        for obstacle in currentObstacles {
            guard xM >= obstacle.bounds.minX - Self.minimumClearanceM,
                  xM <= obstacle.bounds.maxX + Self.minimumClearanceM,
                  yM >= obstacle.bounds.minY - Self.minimumClearanceM,
                  yM <= obstacle.bounds.maxY + Self.minimumClearanceM else {
                continue
            }
            if pointInPolygon(xM, yM, obstacle.points) {
                return .insideObstacle
            }
            nearestDistance = min(
                nearestDistance,
                distanceToPolygon(xM, yM, obstacle.points))
        }
        if nearestDistance < Self.minimumClearanceM {
            return .insufficientClearance(nearestDistance)
        }
        return nil
    }

    private func pointInPolygon(
        _ x: Double,
        _ y: Double,
        _ polygon: [(Double, Double)]
    ) -> Bool {
        var inside = false
        var previous = polygon.count - 1
        for index in polygon.indices {
            let currentPoint = polygon[index]
            let previousPoint = polygon[previous]
            if (currentPoint.1 > y) != (previousPoint.1 > y),
               x < (previousPoint.0 - currentPoint.0)
                    * (y - currentPoint.1)
                    / (previousPoint.1 - currentPoint.1)
                    + currentPoint.0 {
                inside.toggle()
            }
            previous = index
        }
        return inside
    }

    private func distanceToPolygon(
        _ x: Double,
        _ y: Double,
        _ polygon: [(Double, Double)]
    ) -> Double {
        var best = Double.greatestFiniteMagnitude
        for index in polygon.indices {
            let a = polygon[index]
            let b = polygon[(index + 1) % polygon.count]
            let dx = b.0 - a.0
            let dy = b.1 - a.1
            let lengthSquared = dx * dx + dy * dy
            let ratio: Double
            if lengthSquared > 1e-12 {
                ratio = max(
                    0,
                    min(1, ((x - a.0) * dx + (y - a.1) * dy)
                        / lengthSquared))
            } else {
                ratio = 0
            }
            let projectedX = a.0 + ratio * dx
            let projectedY = a.1 + ratio * dy
            best = min(best, hypot(x - projectedX, y - projectedY))
        }
        return best
    }

    // MARK: - Workflow start

    private func registerWorkflowObservers() {
        observerTokens.append(coordinator.addStateObserver { [weak self] state in
            guard let self = self, self.startInFlight else { return }
            switch state {
            case .startingScan:
                self.loadingLabel.text = "正在验证地图并启动相机与连续数据库…"
            case .scanning:
                self.startInFlight = false
                self.loadingIndicator.stopAnimating()
                self.dismiss(animated: true)
            case .failed:
                self.startInFlight = false
                self.formScrollView.isUserInteractionEnabled = true
                self.navigationItem.leftBarButtonItem?.isEnabled = true
                self.setLoading(false, message: "扫描启动失败，可修正后重试。")
                self.presentNotice(
                    self.coordinator.lastError?.errorDescription
                        ?? "扫描启动失败")
            case .cancelled:
                self.startInFlight = false
                self.formScrollView.isUserInteractionEnabled = true
                self.navigationItem.leftBarButtonItem?.isEnabled = true
                self.setLoading(false, message: "扫描启动已取消，可以重新配置。")
            case .interrupted:
                self.startInFlight = false
                self.formScrollView.isUserInteractionEnabled = true
                self.navigationItem.leftBarButtonItem?.isEnabled = true
                self.setLoading(false, message: "扫描启动被系统中断，请重新确认后启动。")
                self.presentNotice("扫描启动被系统中断，没有提交新的扫描会话。")
            default:
                break
            }
        })
        observerTokens.append(coordinator.addProgressObserver {
            [weak self] _, message in
            guard let self = self, self.startInFlight else { return }
            self.loadingLabel.text = message
        })
    }

    @objc private func startScan() {
        guard !startInFlight, !cameraPermissionRequestInFlight else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startAuthorizedScan()
        case .notDetermined:
            requestCameraPermissionAndResume()
        case .denied, .restricted:
            presentCameraPermissionNotice()
        @unknown default:
            presentCameraPermissionNotice()
        }
    }

    /// The workflow transaction is only created after camera authority is
    /// already durable. This prevents ViewController.startCamera()'s legacy
    /// `.notDetermined` callback from firing after the workflow has failed.
    private func startAuthorizedScan() {
        guard AVCaptureDevice.authorizationStatus(for: .video)
                == .authorized,
              let map = currentMap(),
              let package = payload?.package,
              let floor = currentFloor,
              let x = startXM,
              let y = startYM else {
            presentNotice("请等待地图加载完成，并选择楼层和起点。")
            return
        }
        if let traversabilityFailure {
            presentNotice("起点不可用：\(traversabilityFailure.reason)")
            return
        }
        let identity = MobileBuildIdentity.loadFromBundle()
        guard identity.isUsable else {
            presentNotice(Self.unqualifiedBuildMessage)
            return
        }

        startInFlight = true
        formScrollView.isUserInteractionEnabled = false
        loadingIndicator.startAnimating()
        loadingLabel.text = "正在验证地图并启动扫描…"
        startButton.isEnabled = false

        let configuration = MobileScanConfiguration(
            priorMap: map,
            preparedPackage: package,
            floorID: floor.id,
            startXM: x,
            startYM: y,
            startYawRad: startYawRad,
            storeID: package.manifest.storeID)
        guard coordinator.beginScanSetup(map: map) else {
            startInFlight = false
            formScrollView.isUserInteractionEnabled = true
            navigationItem.leftBarButtonItem?.isEnabled = true
            setLoading(
                false,
                message: "当前已有扫描正在进行或结束中，不能创建第二个扫描事务。")
            presentNotice(
                coordinator.lastError?.errorDescription
                    ?? "当前已有扫描正在进行或结束中，请先返回扫描界面完成或结束当前扫描。")
            return
        }
        coordinator.commitScanConfiguration(configuration)
    }

    private func requestCameraPermissionAndResume() {
        cameraPermissionRequestInFlight = true
        formScrollView.isUserInteractionEnabled = false
        loadingIndicator.startAnimating()
        loadingLabel.text = "等待系统相机权限确认…"
        startButton.isEnabled = false
        navigationItem.leftBarButtonItem?.isEnabled = false

        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self = self,
                      self.cameraPermissionRequestInFlight else { return }
                self.cameraPermissionRequestInFlight = false
                self.formScrollView.isUserInteractionEnabled = true
                self.navigationItem.leftBarButtonItem?.isEnabled = true
                self.setLoading(
                    false,
                    message: granted
                        ? "相机权限已授权，正在重新验证扫描配置…"
                        : "未获得相机权限，扫描尚未启动。")
                guard granted,
                      AVCaptureDevice.authorizationStatus(for: .video)
                        == .authorized else {
                    self.presentCameraPermissionNotice()
                    return
                }
                // Re-enter the same production entry so map, floor, pose,
                // build identity and authorization are all checked again
                // before beginScanSetup/commitScanConfiguration.
                self.startScan()
            }
        }
    }

    private func presentCameraPermissionNotice() {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(
            title: "需要相机权限",
            message: "门店扫描需要相机与 LiDAR/深度数据。请在系统设置中允许相机访问后重试；当前没有创建或提交扫描会话。",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(
            title: "打开设置",
            style: .default,
            handler: { _ in
                guard let url = URL(
                    string: UIApplication.openSettingsURLString) else {
                    return
                }
                UIApplication.shared.open(url)
            }))
        present(alert, animated: true)
    }

    private static let unqualifiedBuildMessage = """
    当前构建没有可追踪的扫描身份，因此不能开始已有地图辅助扫描。

    请使用 Xcode 共享的 RTABMapApp 默认 Run（当前配置为 Release），或 RTABMapApp-QualifiedDevice，从已提交且 tracked 文件干净的版本重新构建。手动改成 Debug 时仍只用于界面和导入调试。
    """

    private func updateSummary() {
        guard !startInFlight, !cameraPermissionRequestInFlight else {
            summaryLabel.text = cameraPermissionRequestInFlight
                ? "正在等待系统相机权限确认…"
                : "正在启动扫描，请稍候…"
            startButton.isEnabled = false
            return
        }
        guard let map = currentMap() else {
            summaryLabel.text = "地图库为空。请返回“门店地图”导入 XLSX 或已有地图包。"
            startButton.isEnabled = false
            return
        }
        guard let package = payload?.package else {
            summaryLabel.text = "正在加载并验证「\(map.name)」…"
            startButton.isEnabled = false
            return
        }
        guard let floor = currentFloor else {
            summaryLabel.text = "地图包没有可用楼层。"
            startButton.isEnabled = false
            return
        }
        guard let x = startXM, let y = startYM else {
            summaryLabel.text = "已选「\(map.name)」· 楼层 \(floor.id)。请在地图上点选起点，必要时缩放并使用方向键微调。"
            startButton.isEnabled = false
            return
        }
        if let failure = traversabilityFailure {
            summaryLabel.text = "起点不可用：\(failure.reason)"
            startButton.isEnabled = false
            return
        }
        let identityUsable = MobileBuildIdentity.loadFromBundle().isUsable
        let identityNote = identityUsable
            ? ""
            : "\n当前 App 缺少可追踪身份；请用 RTABMapApp 默认 Run 重新构建。"
        var displayDegrees = startYawRad * 180 / Double.pi
        if displayDegrees < 0 { displayDegrees += 360 }
        summaryLabel.text = String(
            format: "门店 %@ · 地图 %@ · 楼层 %@\n起点 (%.2f, %.2f) m · 朝向 %.0f°%@",
            package.manifest.storeID,
            map.name,
            floor.id,
            x,
            y,
            displayDegrees,
            identityNote)
        startButton.isEnabled = identityUsable
    }

    private func currentMap() -> MobileMapLibrary.MapEntry? {
        return selectedMap
    }

    private func presentNotice(_ message: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(
            title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "知道了", style: .default))
        present(alert, animated: true)
    }
}

extension MobileScanSetupViewController: UIScrollViewDelegate {
    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        return scrollView === mapScrollView ? mapCanvasView : nil
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        if scrollView === mapScrollView {
            centreCanvas()
            rotateMarker()
        }
    }
}
