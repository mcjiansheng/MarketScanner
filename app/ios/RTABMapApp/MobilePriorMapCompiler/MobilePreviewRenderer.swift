import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Renders floor previews and the overall package preview as real PNGs
/// with CoreGraphics. Previews are informational only — they never feed
/// localization math — but they must exist and load so the package
/// integrity validator and the map list UI can consume them.
enum MobilePreviewRenderer {
    static let maximumPreviewPixels = 2_000 * 2_000
    static let maximumPreviewBytes = 8 * 1024 * 1024

    static func render(
        elements: [PriorMapSourceElement],
        floors: [[String: Any]],
        directory: URL
    ) throws {
        // Overall preview combining every floor's bounds.
        let allBounds = floors.compactMap { floor -> SourceGeometry.Bounds? in
            guard let value = floor["bounds"] as? [String: Double],
                  let minX = value["min_x_m"], let minY = value["min_y_m"],
                  let maxX = value["max_x_m"], let maxY = value["max_y_m"]
            else { return nil }
            return SourceGeometry.Bounds(minX_m: minX, minY_m: minY, maxX_m: maxX, maxY_m: maxY)
        }
        let merged = SourceGeometry.mergeBounds(allBounds)
        let canvas = try canvasSize(bounds: merged)
        try renderPNG(
            elements: elements, floors: nil, bounds: merged,
            canvasWidth: canvas.width, canvasHeight: canvas.height,
            to: directory.appendingPathComponent("preview.png"))

        for floor in floors {
            guard let floorID = floor["id"] as? String,
                  let previewFile = floor["preview_file"] as? String,
                  let boundsValue = floor["bounds"] as? [String: Double],
                  let minX = boundsValue["min_x_m"], let minY = boundsValue["min_y_m"],
                  let maxX = boundsValue["max_x_m"], let maxY = boundsValue["max_y_m"]
            else { continue }
            let floorBounds = SourceGeometry.Bounds(
                minX_m: minX, minY_m: minY, maxX_m: maxX, maxY_m: maxY)
            let floorCanvas = try canvasSize(bounds: floorBounds)
            try renderPNG(
                elements: elements.filter { $0.floorId == floorID },
                floors: nil, bounds: floorBounds,
                canvasWidth: floorCanvas.width, canvasHeight: floorCanvas.height,
                to: directory.appendingPathComponent(previewFile))
        }
    }

    private struct CanvasSize {
        var width: Int
        var height: Int
    }

    private static func canvasSize(bounds: SourceGeometry.Bounds) throws -> CanvasSize {
        let widthM = max(bounds.widthM, 1.0)
        let heightM = max(bounds.heightM, 1.0)
        let scale = min(2000.0 / widthM, 2000.0 / heightM, 100.0)
        let width = max(1, Int((widthM * scale).rounded()))
        let height = max(1, Int((heightM * scale).rounded()))
        guard width * height <= maximumPreviewPixels else {
            throw MapSourceImportError.invalidGeometry(
                shapeType: "preview", reason: "preview pixel budget exceeded")
        }
        return CanvasSize(width: width, height: height)
    }

    private static func renderPNG(
        elements: [PriorMapSourceElement],
        floors: [[String: Any]]?,
        bounds: SourceGeometry.Bounds,
        canvasWidth: Int,
        canvasHeight: Int,
        to url: URL
    ) throws {
        guard let context = CGContext(
            data: nil,
            width: canvasWidth,
            height: canvasHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw MapSourceImportError.invalidGeometry(
                shapeType: "preview", reason: "cannot create graphics context")
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))

        func project(_ xM: Double, _ yM: Double) -> (Double, Double) {
            let sx = (xM - bounds.minX_m) / max(bounds.widthM, 1.0)
            let sy = (yM - bounds.minY_m) / max(bounds.heightM, 1.0)
            // Map y is up; image y is down.
            return (sx * Double(canvasWidth), (1.0 - sy) * Double(canvasHeight))
        }

        // Road nodes and crosses first (grey), then structures.
        context.setStrokeColor(CGColor(red: 0.6, green: 0.6, blue: 0.6, alpha: 1))
        context.setLineWidth(2)
        for element in elements {
            guard let geometry = element.geometry,
                  let coordinates = geometry["coordinates"] as? [Any]
            else { continue }
            if element.shapeType == "MapCross" || element.shapeType == "MapRoadPoint" {
                drawPolyline(coordinates, context: context, project: project, closePath: false)
            }
        }
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        for element in elements {
            guard let geometry = element.geometry,
                  let coordinates = geometry["coordinates"] as? [Any]
            else { continue }
            if MobileElementTypes.rectangleTypes.contains(element.shapeType) {
                drawPolygon(coordinates, context: context, project: project)
            }
        }
        guard let image = context.makeImage() else {
            throw MapSourceImportError.invalidGeometry(
                shapeType: "preview", reason: "cannot render preview")
        }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else {
            throw MapSourceImportError.invalidGeometry(
                shapeType: "preview", reason: "cannot create PNG destination")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw MapSourceImportError.invalidGeometry(
                shapeType: "preview", reason: "cannot finalize PNG")
        }
        let bytes = try Data(contentsOf: url)
        guard bytes.count <= maximumPreviewBytes else {
            throw MapSourceImportError.invalidGeometry(
                shapeType: "preview", reason: "preview byte budget exceeded")
        }
    }

    private static func drawPolyline(
        _ coordinates: [Any],
        context: CGContext,
        project: (Double, Double) -> (Double, Double),
        closePath: Bool
    ) {
        var points: [(Double, Double)] = []
        for item in coordinates {
            if let pair = item as? [Any], pair.count >= 2,
               let x = pair[0] as? Double, let y = pair[1] as? Double {
                points.append(project(x, y))
            }
        }
        guard points.count >= 2 else { return }
        context.beginPath()
        context.move(to: CGPoint(x: points[0].0, y: points[0].1))
        for point in points.dropFirst() {
            context.addLine(to: CGPoint(x: point.0, y: point.1))
        }
        if closePath {
            context.closePath()
        }
        context.strokePath()
    }

    private static func drawPolygon(
        _ coordinates: [Any],
        context: CGContext,
        project: (Double, Double) -> (Double, Double)
    ) {
        var points: [(Double, Double)] = []
        for item in coordinates {
            if let pair = item as? [Any], pair.count >= 2,
               let x = pair[0] as? Double, let y = pair[1] as? Double {
                points.append(project(x, y))
            }
        }
        guard points.count >= 3 else { return }
        context.beginPath()
        context.move(to: CGPoint(x: points[0].0, y: points[0].1))
        for point in points.dropFirst() {
            context.addLine(to: CGPoint(x: point.0, y: point.1))
        }
        context.closePath()
        context.fillPath()
    }
}
