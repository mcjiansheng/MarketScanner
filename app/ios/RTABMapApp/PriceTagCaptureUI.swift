//
//  PriceTagCaptureUI.swift
//  RTABMapApp
//
//  Camera-only ESL capture presentation and shelf confirmation. Camera
//  pixels always come from ARFrame.capturedImage; this file never owns an
//  second camera pipeline and never changes ARSession/RTAB-Map lifecycle state.
//

import ARKit
import CoreImage
import ImageIO
import MetalKit
import UIKit

final class PriceTagCapturePreviewView: MTKView, MTKViewDelegate {
    private let frameLock = NSLock()
    private var latestPixelBuffer: CVPixelBuffer?
    private var latestOrientation = CGImagePropertyOrientation.right
    private var latestGeneration: UUID?
    private let commandQueue: MTLCommandQueue?
    private let ciContext: CIContext?
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    init() {
        let metalDevice = MTLCreateSystemDefaultDevice()
        commandQueue = metalDevice?.makeCommandQueue()
        ciContext = metalDevice.map {
            CIContext(mtlDevice: $0, options: [
                .cacheIntermediates: false,
            ])
        }
        super.init(frame: .zero, device: metalDevice)
        framebufferOnly = false
        enableSetNeedsDisplay = true
        isPaused = true
        autoResizeDrawable = true
        clearColor = MTLClearColorMake(0, 0, 0, 1)
        contentMode = .redraw
        delegate = self
        accessibilityLabel = NSLocalizedString("ESL camera preview", comment: "")
    }

    required init(coder: NSCoder) {
        let metalDevice = MTLCreateSystemDefaultDevice()
        commandQueue = metalDevice?.makeCommandQueue()
        ciContext = metalDevice.map {
            CIContext(mtlDevice: $0, options: [
                .cacheIntermediates: false,
            ])
        }
        super.init(coder: coder)
        device = metalDevice
        framebufferOnly = false
        enableSetNeedsDisplay = true
        isPaused = true
        autoResizeDrawable = true
        clearColor = MTLClearColorMake(0, 0, 0, 1)
        contentMode = .redraw
        delegate = self
        accessibilityLabel = NSLocalizedString(
            "ESL camera preview", comment: "")
    }

    func enqueue(
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        generation: UUID
    ) {
        frameLock.lock()
        latestPixelBuffer = pixelBuffer
        latestOrientation = orientation
        latestGeneration = generation
        frameLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.setNeedsDisplay()
        }
    }

    func clear(generation: UUID?) {
        frameLock.lock()
        if generation == nil || generation == latestGeneration {
            latestPixelBuffer = nil
            latestGeneration = nil
        }
        frameLock.unlock()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
    }

    func draw(in view: MTKView) {
        frameLock.lock()
        let pixelBuffer = latestPixelBuffer
        let orientation = latestOrientation
        frameLock.unlock()
        guard let pixelBuffer,
              let drawable = currentDrawable,
              let commandBuffer = commandQueue?.makeCommandBuffer(),
              let ciContext,
              drawableSize.width > 0,
              drawableSize.height > 0 else {
            return
        }
        let input = CIImage(cvPixelBuffer: pixelBuffer)
            .oriented(forExifOrientation: Int32(orientation.rawValue))
        guard input.extent.width > 0, input.extent.height > 0 else { return }
        let normalized = input.transformed(by: CGAffineTransform(
            translationX: -input.extent.minX,
            y: -input.extent.minY))
        let scale = max(
            drawableSize.width / normalized.extent.width,
            drawableSize.height / normalized.extent.height)
        let scaled = normalized.transformed(by: CGAffineTransform(
            scaleX: scale,
            y: scale))
        let target = CGRect(origin: .zero, size: drawableSize)
        let output = scaled.transformed(by: CGAffineTransform(
            translationX: target.midX - scaled.extent.midX,
            y: target.midY - scaled.extent.midY))
        ciContext.render(
            output,
            to: drawable.texture,
            commandBuffer: commandBuffer,
            bounds: target,
            colorSpace: colorSpace)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

enum PriceTagCaptureOverlayStatus {
    case aiming
    case candidate(payload: String, lockFrames: Int, requiredFrames: Int)
    case collecting(payload: String, acceptedFrames: Int, requiredFrames: Int)
    case multiple
    case duplicate
    case resolving
    case success
    case error(message: String)
}

final class PriceTagCaptureOverlayView: UIView {
    let previewView = PriceTagCapturePreviewView()
    var onCancel: (() -> Void)?

    private let dimLayer = CAShapeLayer()
    private let borderLayer = CAShapeLayer()
    private let statusLabel = UILabel()
    private let payloadLabel = UILabel()
    private let cancelButton = UIButton(type: .system)
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let scanTopGuide = UILayoutGuide()
    private let scanBottomGuide = UILayoutGuide()
    private var barcodeBusinessClassification:
        PriceTagBarcodeBusinessClassification = .eslCompatible

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        previewView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(previewView)
        NSLayoutConstraint.activate([
            previewView.leadingAnchor.constraint(equalTo: leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: trailingAnchor),
            previewView.topAnchor.constraint(equalTo: topAnchor),
            previewView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        dimLayer.fillRule = .evenOdd
        dimLayer.fillColor = UIColor.black.withAlphaComponent(0.52).cgColor
        layer.addSublayer(dimLayer)
        borderLayer.fillColor = UIColor.clear.cgColor
        borderLayer.strokeColor = UIColor.white.cgColor
        borderLayer.lineWidth = 4
        borderLayer.lineJoin = .round
        layer.addSublayer(borderLayer)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .preferredFont(forTextStyle: .title3)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textAlignment = .center
        statusLabel.textColor = .white
        statusLabel.numberOfLines = 2
        statusLabel.accessibilityTraits = [.updatesFrequently]
        addSubview(statusLabel)

        payloadLabel.translatesAutoresizingMaskIntoConstraints = false
        payloadLabel.font = .monospacedSystemFont(ofSize: 15, weight: .semibold)
        payloadLabel.textAlignment = .center
        payloadLabel.textColor = .white
        payloadLabel.numberOfLines = 1
        payloadLabel.lineBreakMode = .byTruncatingMiddle
        addSubview(payloadLabel)

        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.trackTintColor = UIColor.white.withAlphaComponent(0.3)
        progressView.progressTintColor = .systemGreen
        addSubview(progressView)

        // The guides share the same normalized geometry as the border and
        // Vision ROI. Labels therefore remain outside the scan box on every
        // supported device height and Dynamic Type size.
        addLayoutGuide(scanTopGuide)
        addLayoutGuide(scanBottomGuide)

        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.setTitle(NSLocalizedString("Cancel ESL scan", comment: ""), for: .normal)
        cancelButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        cancelButton.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        cancelButton.tintColor = .white
        cancelButton.layer.cornerRadius = 12
        cancelButton.contentEdgeInsets = UIEdgeInsets(
            top: 14, left: 24, bottom: 14, right: 24)
        cancelButton.accessibilityLabel = NSLocalizedString("Cancel ESL scan", comment: "")
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        addSubview(cancelButton)

        NSLayoutConstraint.activate([
            scanTopGuide.topAnchor.constraint(equalTo: topAnchor),
            scanTopGuide.heightAnchor.constraint(
                equalTo: heightAnchor,
                multiplier: PriceTagCaptureLayout.normalizedScanRect.minY),
            scanBottomGuide.topAnchor.constraint(equalTo: topAnchor),
            scanBottomGuide.heightAnchor.constraint(
                equalTo: heightAnchor,
                multiplier: PriceTagCaptureLayout.normalizedScanRect.maxY),
            statusLabel.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -24),
            statusLabel.topAnchor.constraint(
                greaterThanOrEqualTo: safeAreaLayoutGuide.topAnchor,
                constant: 12),
            statusLabel.bottomAnchor.constraint(
                equalTo: scanTopGuide.bottomAnchor,
                constant: -PriceTagCaptureLayout.statusClearancePoints),
            payloadLabel.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 24),
            payloadLabel.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -24),
            payloadLabel.topAnchor.constraint(
                equalTo: scanBottomGuide.bottomAnchor,
                constant: PriceTagCaptureLayout.payloadClearancePoints),
            progressView.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 52),
            progressView.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -52),
            progressView.topAnchor.constraint(equalTo: payloadLabel.bottomAnchor, constant: 14),
            progressView.bottomAnchor.constraint(
                lessThanOrEqualTo: cancelButton.topAnchor,
                constant: -20),
            cancelButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            cancelButton.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -24),
            cancelButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 50),
        ])
        update(.aiming)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scanRect = PriceTagCaptureLayout.scanRect(in: bounds)
        let path = UIBezierPath(rect: bounds)
        path.append(UIBezierPath(roundedRect: scanRect, cornerRadius: 18))
        dimLayer.frame = bounds
        dimLayer.path = path.cgPath
        borderLayer.frame = bounds
        borderLayer.path = UIBezierPath(
            roundedRect: scanRect,
            cornerRadius: 18).cgPath
    }

    var captureGeometry: PriceTagCaptureGeometry {
        return PriceTagCaptureGeometry(
            previewBounds: bounds,
            scanRect: PriceTagCaptureLayout.scanRect(in: bounds))
    }

    func update(_ status: PriceTagCaptureOverlayStatus) {
        let color: UIColor
        switch status {
        case .aiming:
            barcodeBusinessClassification = .eslCompatible
            statusLabel.text = NSLocalizedString(
                "Place the ESL barcode inside the frame. Stay about 25–45 cm away for autofocus.",
                comment: "")
            payloadLabel.text = nil
            progressView.progress = 0
            color = .white
        case .candidate(let payload, let lockFrames, let requiredFrames):
            statusLabel.text = barcodeBusinessClassification
                == .likelyRetailProduct
                ? NSLocalizedString(
                    "Possible product barcode. Use only the code printed on the ESL.",
                    comment: "")
                : NSLocalizedString("Barcode detected. Hold steady", comment: "")
            payloadLabel.text = payload
            progressView.progress = Float(lockFrames) / Float(max(1, requiredFrames)) * 0.25
            color = .systemYellow
        case .collecting(let payload, let acceptedFrames, let requiredFrames):
            statusLabel.text = barcodeBusinessClassification
                == .likelyRetailProduct
                ? String(
                    format: NSLocalizedString(
                        "Possible product barcode · ESL evidence %d/%d",
                        comment: ""),
                    acceptedFrames,
                    requiredFrames)
                : String(
                    format: NSLocalizedString(
                        "Collecting evidence %d/%d", comment: ""),
                    acceptedFrames,
                    requiredFrames)
            payloadLabel.text = payload
            progressView.progress = 0.25
                + 0.75 * Float(acceptedFrames) / Float(max(1, requiredFrames))
            color = acceptedFrames > 0 ? .systemGreen : .systemYellow
        case .multiple:
            statusLabel.text = NSLocalizedString("Multiple barcodes are inside the frame", comment: "")
            payloadLabel.text = NSLocalizedString("Keep only one barcode in the scan box", comment: "")
            progressView.progress = 0
            color = .systemOrange
        case .duplicate:
            statusLabel.text = NSLocalizedString("This ESL was just saved", comment: "")
            payloadLabel.text = NSLocalizedString("Move to another tag or wait briefly", comment: "")
            progressView.progress = 0
            color = .systemOrange
        case .resolving:
            statusLabel.text = NSLocalizedString("Resolving ESL position", comment: "")
            payloadLabel.text = nil
            progressView.progress = 1
            color = .systemGreen
        case .success:
            statusLabel.text = NSLocalizedString("ESL capture complete", comment: "")
            payloadLabel.text = nil
            progressView.progress = 1
            color = .systemGreen
        case .error(let message):
            statusLabel.text = message
            payloadLabel.text = nil
            progressView.progress = 0
            color = .systemRed
        }
        borderLayer.strokeColor = color.cgColor
        accessibilityLabel = [statusLabel.text, payloadLabel.text]
            .compactMap { $0 }
            .joined(separator: ". ")
        UIAccessibility.post(notification: .announcement, argument: statusLabel.text)
    }

    func setBarcodeIdentity(payload: String, symbology: String) {
        barcodeBusinessClassification =
            PriceTagBarcodeBusinessPolicy.classify(
                payload: payload,
                symbology: symbology)
    }

    @objc private func cancelTapped() {
        onCancel?()
    }
}

struct PriceTagShelfConfirmationModel {
    let tag: LocalizedPriceTag
    let candidates: [PriceTagShelfCandidate]
    let algorithmCandidateReliable: Bool
}

final class PriceTagShelfMiniMapView: UIView {
    var tagPosition: PriorMapTagPoint3D? { didSet { setNeedsDisplay() } }
    var candidates: [PriceTagShelfCandidate] = [] { didSet { setNeedsDisplay() } }
    var selectedSegmentID: String? { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 14
        clipsToBounds = true
        isAccessibilityElement = true
        accessibilityLabel = NSLocalizedString("Shelf confirmation map", comment: "")
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let points = candidates.flatMap(\.outline)
            + candidates.map {
                PriceTagShelfPreviewPoint(
                    xM: $0.snappedPosition.xM,
                    yM: $0.snappedPosition.yM)
            }
            + (tagPosition.map {
                [PriceTagShelfPreviewPoint(xM: $0.xM, yM: $0.yM)]
            } ?? [])
        guard let minX = points.map(\.xM).min(),
              let maxX = points.map(\.xM).max(),
              let minY = points.map(\.yM).min(),
              let maxY = points.map(\.yM).max() else {
            return
        }
        let spanX = max(0.5, maxX - minX)
        let spanY = max(0.5, maxY - minY)
        let padded = rect.insetBy(dx: 20, dy: 20)
        func viewPoint(_ point: PriceTagShelfPreviewPoint) -> CGPoint {
            return CGPoint(
                x: padded.minX + CGFloat((point.xM - minX) / spanX) * padded.width,
                y: padded.maxY - CGFloat((point.yM - minY) / spanY) * padded.height)
        }
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for candidate in candidates.reversed() {
            guard candidate.outline.count >= 2 else { continue }
            let selected = candidate.shelfSegmentId == selectedSegmentID
            context.setStrokeColor((selected
                ? UIColor.systemYellow
                : UIColor.systemGray3).cgColor)
            context.setLineWidth(selected ? 6 : 3)
            let first = viewPoint(candidate.outline[0])
            context.beginPath()
            context.move(to: first)
            for point in candidate.outline.dropFirst() {
                context.addLine(to: viewPoint(point))
            }
            context.closePath()
            context.strokePath()
        }
        if let tagPosition {
            let point = viewPoint(PriceTagShelfPreviewPoint(
                xM: tagPosition.xM,
                yM: tagPosition.yM))
            context.setFillColor(UIColor.systemRed.cgColor)
            context.fillEllipse(in: CGRect(
                x: point.x - 7,
                y: point.y - 7,
                width: 14,
                height: 14))
            context.setStrokeColor(UIColor.white.cgColor)
            context.setLineWidth(2)
            context.strokeEllipse(in: CGRect(
                x: point.x - 7,
                y: point.y - 7,
                width: 14,
                height: 14))
        }
    }
}

final class PriceTagShelfConfirmationViewController: UIViewController {
    var onDecision: ((ShelfConfirmationDecision) -> Void)?

    private let model: PriceTagShelfConfirmationModel
    private let miniMap = PriceTagShelfMiniMapView()
    private let statusLabel = UILabel()
    private let alternativesStack = UIStackView()
    private let saveSelectedButton = UIButton(type: .system)
    private var selectedAlternative: PriceTagShelfCandidate?
    private var decisionDelivered = false

    init(model: PriceTagShelfConfirmationModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
        isModalInPresentation = true
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let titleLabel = UILabel()
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0
        let businessClassification = PriceTagBarcodeBusinessPolicy.classify(
            payload: model.tag.payload,
            symbology: model.tag.symbology)
        titleLabel.text = businessClassification == .likelyRetailProduct
            ? NSLocalizedString(
                "This looks like a retail product barcode. Confirm only if this exact code is printed on the ESL.",
                comment: "")
            : NSLocalizedString(
                "Does this ESL belong to the highlighted shelf?",
                comment: "")

        let barcodeLabel = UILabel()
        barcodeLabel.font = .monospacedSystemFont(ofSize: 17, weight: .semibold)
        barcodeLabel.numberOfLines = 2
        barcodeLabel.text = String(
            format: NSLocalizedString("ESL: %@", comment: ""),
            model.tag.payload)

        let algorithm = model.candidates.first(where: {
            $0.shelfSegmentId
                == (model.tag.algorithmShelfSegmentId ?? model.tag.shelfSegmentId)
                && $0.side == (model.tag.algorithmSide ?? model.tag.shelfSide)
        })
        let shelfLabel = UILabel()
        shelfLabel.font = .preferredFont(forTextStyle: .headline)
        shelfLabel.numberOfLines = 2
        shelfLabel.text = algorithm.map {
            String(
                format: NSLocalizedString("Expected shelf: %@ · side %@ · %.0f cm", comment: ""),
                $0.shelfCode ?? $0.shelfSegmentId,
                $0.side,
                $0.distanceFromStartCm)
        } ?? NSLocalizedString("No reliable shelf candidate", comment: "")

        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.numberOfLines = 0
        statusLabel.textColor = model.algorithmCandidateReliable
            ? .secondaryLabel
            : .systemOrange
        statusLabel.text = model.algorithmCandidateReliable
            ? String(
                format: NSLocalizedString("Localization / measurement / association: %d%% / %d%% / %d%%", comment: ""),
                Int(model.tag.localizationConfidence * 100),
                Int(model.tag.measurementConfidence * 100),
                Int(model.tag.associationConfidence * 100))
            : NSLocalizedString(
                "The shelf cannot be determined reliably. Rescan or keep observations only.",
                comment: "")

        miniMap.translatesAutoresizingMaskIntoConstraints = false
        miniMap.tagPosition = model.tag.rawMapPosition
            ?? model.tag.snappedMapPosition
        miniMap.candidates = model.candidates
        miniMap.selectedSegmentID = algorithm?.shelfSegmentId

        let correctButton = actionButton(
            title: businessClassification == .likelyRetailProduct
                ? NSLocalizedString("It is printed on the ESL, save", comment: "")
                : NSLocalizedString("Correct, save", comment: ""),
            color: .systemGreen,
            selector: #selector(confirmAlgorithm))
        correctButton.isEnabled = model.algorithmCandidateReliable
            && algorithm?.isSelectable == true
        correctButton.alpha = correctButton.isEnabled ? 1 : 0.45

        let alternatives = model.candidates.filter {
            $0.isSelectable
                && ($0.shelfSegmentId != algorithm?.shelfSegmentId
                    || $0.side != algorithm?.side)
        }
        let wrongButton = actionButton(
            title: NSLocalizedString("Wrong shelf", comment: ""),
            color: .systemOrange,
            selector: #selector(showAlternatives))
        wrongButton.isEnabled = model.algorithmCandidateReliable
            && !alternatives.isEmpty
        wrongButton.alpha = wrongButton.isEnabled ? 1 : 0.45

        alternativesStack.axis = .vertical
        alternativesStack.spacing = 8
        alternativesStack.isHidden = true
        for candidate in alternatives.prefix(4) {
            let button = UIButton(type: .system)
            button.setTitle(
                "\(candidate.shelfCode ?? candidate.shelfSegmentId) · \(candidate.side) · \(Int(candidate.distanceFromStartCm)) cm",
                for: .normal)
            button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
            button.contentHorizontalAlignment = .leading
            button.backgroundColor = .tertiarySystemBackground
            button.layer.cornerRadius = 10
            button.contentEdgeInsets = UIEdgeInsets(
                top: 12, left: 14, bottom: 12, right: 14)
            button.accessibilityLabel = button.title(for: .normal)
            button.addAction(UIAction { [weak self] _ in
                self?.selectedAlternative = candidate
                self?.miniMap.selectedSegmentID = candidate.shelfSegmentId
                self?.saveSelectedButton.isEnabled = true
                self?.saveSelectedButton.alpha = 1
            }, for: .touchUpInside)
            alternativesStack.addArrangedSubview(button)
        }
        saveSelectedButton.setTitle(
            businessClassification == .likelyRetailProduct
                ? NSLocalizedString(
                    "It is printed on the ESL, save selected shelf",
                    comment: "")
                : NSLocalizedString("Save selected shelf", comment: ""),
            for: .normal)
        saveSelectedButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        saveSelectedButton.backgroundColor = .systemBlue
        saveSelectedButton.tintColor = .white
        saveSelectedButton.layer.cornerRadius = 12
        saveSelectedButton.contentEdgeInsets = UIEdgeInsets(
            top: 14, left: 20, bottom: 14, right: 20)
        saveSelectedButton.isEnabled = false
        saveSelectedButton.alpha = 0.45
        saveSelectedButton.addTarget(
            self,
            action: #selector(saveAlternative),
            for: .touchUpInside)
        alternativesStack.addArrangedSubview(saveSelectedButton)

        let rescanButton = actionButton(
            title: NSLocalizedString("Rescan", comment: ""),
            color: .systemBlue,
            selector: #selector(rescan))
        let observationButton = actionButton(
            title: NSLocalizedString("Keep observations only", comment: ""),
            color: .systemGray,
            selector: #selector(observationOnly))

        let stack = UIStackView(arrangedSubviews: [
            titleLabel,
            barcodeLabel,
            shelfLabel,
            miniMap,
            statusLabel,
            correctButton,
            wrongButton,
            alternativesStack,
            rescanButton,
            observationButton,
        ])
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40),
            miniMap.heightAnchor.constraint(equalToConstant: 260),
        ])
    }

    private func actionButton(
        title: String,
        color: UIColor,
        selector: Selector
    ) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        button.backgroundColor = color
        button.tintColor = .white
        button.layer.cornerRadius = 12
        button.contentEdgeInsets = UIEdgeInsets(
            top: 15, left: 20, bottom: 15, right: 20)
        button.accessibilityLabel = title
        button.addTarget(self, action: selector, for: .touchUpInside)
        return button
    }

    @objc private func confirmAlgorithm() {
        deliver(.confirmedAlgorithmCandidate)
    }

    @objc private func showAlternatives() {
        alternativesStack.isHidden = false
        statusLabel.text = NSLocalizedString(
            "Select the shelf visible in the mini map, then save.",
            comment: "")
    }

    @objc private func saveAlternative() {
        guard let selectedAlternative else { return }
        deliver(.selectedAlternative(
            segmentID: selectedAlternative.shelfSegmentId,
            side: selectedAlternative.side))
    }

    @objc private func rescan() {
        deliver(.rescan)
    }

    @objc private func observationOnly() {
        deliver(.observationOnly)
    }

    private func deliver(_ decision: ShelfConfirmationDecision) {
        guard !decisionDelivered else { return }
        decisionDelivered = true
        onDecision?(decision)
    }
}
