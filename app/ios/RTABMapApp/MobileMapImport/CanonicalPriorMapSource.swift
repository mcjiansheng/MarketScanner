import Foundation

/// Canonical, format-independent representation of a store map imported
/// on-device from an XLSX, CSV or JSON source.
///
/// The three importers (XLSX/CSV/JSON) must produce byte-identical
/// business payloads for the same store map, so that
/// `canonicalSourceSha256` is format-independent. The original filename
/// and source file hash are intentionally excluded from the canonical
/// payload (they live in `MapSourceIdentity` only).
struct MarketScannerPriorMapSource: Equatable {
    static let formatValue = "MarketScannerPriorMapSource"
    static let versionValue = 1

    var format: String
    var version: Int
    var storeId: String
    var mapName: String
    var source: MapSourceIdentity
    var coordinateContract: CoordinateContract
    var elements: [PriorMapSourceElement]
    var warnings: [MapSourceWarning]

    /// The canonical payload whose deterministic encoding feeds
    /// `canonicalSourceSha256`. V2 business payload (see
    /// `CanonicalPriorMapBusinessSourceV2`) excludes source identity,
    /// source rows, warnings and raw fields so that the same store map
    /// imported from XLSX, CSV and JSON produces the same digest.
    var canonicalPayload: [String: Any] {
        return CanonicalPriorMapBusinessSourceV2(
            storeID: storeId,
            mapName: mapName,
            coordinateContract: coordinateContract,
            elements: elements
        ).payload
    }

    static func == (lhs: MarketScannerPriorMapSource, rhs: MarketScannerPriorMapSource) -> Bool {
        guard lhs.format == rhs.format, lhs.version == rhs.version,
              lhs.storeId == rhs.storeId, lhs.mapName == rhs.mapName,
              lhs.source == rhs.source, lhs.coordinateContract == rhs.coordinateContract,
              lhs.elements.count == rhs.elements.count,
              lhs.warnings.count == rhs.warnings.count
        else { return false }
        for (left, right) in zip(lhs.elements, rhs.elements) where left != right {
            return false
        }
        for (left, right) in zip(lhs.warnings, rhs.warnings) where left != right {
            return false
        }
        return true
    }
}

/// V2 canonical business payload (V1R1 §6.7).
///
/// Contract: the business payload contains ONLY business fields that are
/// invariant across formats. It never contains:
/// - original filename
/// - source file SHA
/// - source row numbers
/// - localized warning messages
/// - format-specific raw representations
///
/// Element identity priority: the official source id when present,
/// otherwise a canonical hash of geometry + business identity. Row
/// numbers are never part of an element id.
struct CanonicalPriorMapBusinessSourceV2 {
    static let formatValue = "MarketScannerPriorMapSource"
    static let versionValue = 2

    var storeID: String
    var mapName: String
    var coordinateContract: CoordinateContract
    var elements: [PriorMapSourceElement]

    var payload: [String: Any] {
        return [
            "format": Self.formatValue,
            "version": Self.versionValue,
            "store_id": storeID,
            "map_name": mapName,
            "coordinate_contract": coordinateContract.canonicalPayload,
            "elements": elements.map { element in
                CanonicalPriorMapBusinessSourceV2.elementPayload(
                    element, storeID: storeID, mapName: mapName)
            },
        ]
    }

    /// Business payload of one element; unknown raw fields and audit-only
    /// fields (source rows, raw representation) are excluded.
    static func elementPayload(
        _ element: PriorMapSourceElement,
        storeID: String,
        mapName: String
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "id": stableElementID(for: element, storeID: storeID, mapName: mapName),
            "floor_id": element.floorId,
            "shape_type": element.shapeType,
            "visible": element.visible,
            "locked": element.locked,
            "code": element.code,
            "cross_code": element.crossCode,
            "row_flag": element.rowFlag,
        ]
        if let subsection = element.subsection {
            payload["subsection"] = subsection
        } else {
            payload["subsection"] = NSNull()
        }
        if let geometry = element.geometry {
            payload["geometry"] = geometry
        }
        if let bounds = element.bounds {
            payload["bounds"] = bounds
        }
        if let centerM = element.centerM {
            payload["center_m"] = centerM
        }
        if let yawRad = element.yawRad {
            payload["yaw_rad"] = yawRad
        }
        return payload
    }

    /// Stable, row-independent element id: the official source id when
    /// present and unique, otherwise a canonical hash over the business
    /// identity (shape type, floor, code, geometry).
    static func stableElementID(
        for element: PriorMapSourceElement,
        storeID: String,
        mapName: String
    ) -> String {
        if let official = officialSourceID(of: element),
           !official.isEmpty {
            return official
        }
        var identity: [String: Any] = [
            "shape_type": element.shapeType,
            "floor_id": element.floorId,
            "code": element.code,
            "cross_code": element.crossCode,
        ]
        if let geometry = element.geometry {
            identity["geometry"] = geometry
        }
        if let bounds = element.bounds {
            identity["bounds"] = bounds
        }
        if let centerM = element.centerM {
            identity["center_m"] = centerM
        }
        if let yawRad = element.yawRad {
            identity["yaw_rad"] = yawRad
        }
        let context: [String: Any] = [
            "store_id": storeID,
            "map_name": mapName,
            "identity": identity,
        ]
        let data = (try? CanonicalJSONEncoder.encode(context)) ?? Data()
        return "e-" + CanonicalSourceHasher.sha256(data).prefix(20)
    }

    /// Official source id: the `sourceId` / `source_id` / `id` raw field
    /// when the source document declares one.
    private static func officialSourceID(of element: PriorMapSourceElement) -> String? {
        if let value = element.source["sourceId"] as? String, !value.isEmpty {
            return value
        }
        if let value = element.source["source_id"] as? String, !value.isEmpty {
            return value
        }
        if let value = element.source["id"] as? String, !value.isEmpty {
            return value
        }
        if let value = element.source["id"] as? Int {
            return String(value)
        }
        return nil
    }
}

/// Audit record of one import run (V1R1 §6.7). Separate from the
/// business payload: keeps source rows, warnings and the original raw
/// fields without polluting the format-independent digest.
struct MapImportAudit: Equatable {
    var format: String
    var sourceRows: [Int]
    var warnings: [MapSourceWarning]
    var rawFields: [[String: Any]]

    var payload: [String: Any] {
        return [
            "format": "MarketScannerMapImportAudit",
            "version": 1,
            "source_format": format,
            "source_rows": sourceRows,
            "warning_count": warnings.count,
            "warnings": warnings.map { $0.canonicalPayload },
            "raw_field_count": rawFields.count,
            "raw_fields": rawFields,
        ]
    }

    static func == (lhs: MapImportAudit, rhs: MapImportAudit) -> Bool {
        guard lhs.format == rhs.format, lhs.sourceRows == rhs.sourceRows,
              lhs.warnings == rhs.warnings,
              lhs.rawFields.count == rhs.rawFields.count
        else { return false }
        return JSONValueComparer.equal(lhs.rawFields, rhs.rawFields)
    }
}

/// Immutable identity of the imported source document.
struct MapSourceIdentity: Equatable {
    var originalFormat: String
    var originalFilename: String
    var sourceFileSha256: String
    var canonicalSourceSha256: String
}

/// User-facing coordinate preset of the original document. V1 supports
/// exactly two presets; the app never asks the user to type matrices.
struct CoordinateContract: Equatable {
    enum Origin: String, Equatable {
        case topLeft = "top_left"
        case bottomLeft = "bottom_left"
    }

    /// Source unit of length; V1 always imports centimetres.
    var unit: String
    /// Source origin preset chosen by the user during the import wizard.
    var origin: Origin
    var xAxis: String
    var yAxis: String
    /// Source rotation convention: clockwise degrees.
    var rotationDirection: String

    static let topLeft: CoordinateContract = CoordinateContract(
        unit: "centimetre",
        origin: .topLeft,
        xAxis: "right",
        yAxis: "down",
        rotationDirection: "clockwise_degrees"
    )

    static let bottomLeft: CoordinateContract = CoordinateContract(
        unit: "centimetre",
        origin: .bottomLeft,
        xAxis: "right",
        yAxis: "up",
        rotationDirection: "clockwise_degrees"
    )

    var canonicalPayload: [String: Any] {
        return [
            "unit": unit,
            "origin": origin.rawValue,
            "x_axis": xAxis,
            "y_axis": yAxis,
            "rotation_direction": rotationDirection,
        ]
    }
}

/// One normalized map element, structurally identical to the PC
/// `_normalized_element` output so the mobile compiler and the PC golden
/// oracle share one element contract.
struct PriorMapSourceElement: Equatable {
    var id: String
    var sourceRow: Int
    var floorId: String
    var shapeType: String
    var visible: Bool
    var locked: Bool
    var code: String
    var crossCode: String
    var rowFlag: String
    var subsection: String?
    var geometry: [String: Any]?
    var bounds: [String: Double]?
    var centerM: [Double]?
    var yawRad: Double?
    /// Raw business fields preserved verbatim from the source document.
    var source: [String: Any]

    var canonicalPayload: [String: Any] {
        var payload: [String: Any] = [
            "id": id,
            "source_row": sourceRow,
            "floor_id": floorId,
            "shape_type": shapeType,
            "visible": visible,
            "locked": locked,
            "code": code,
            "cross_code": crossCode,
            "row_flag": rowFlag,
            "source": source,
        ]
        if let subsection = subsection {
            payload["subsection"] = subsection
        } else {
            payload["subsection"] = NSNull()
        }
        if let geometry = geometry {
            payload["geometry"] = geometry
        }
        if let bounds = bounds {
            payload["bounds"] = bounds
        }
        if let centerM = centerM {
            payload["center_m"] = centerM
        }
        if let yawRad = yawRad {
            payload["yaw_rad"] = yawRad
        }
        return payload
    }

    init(
        id: String,
        sourceRow: Int,
        floorId: String,
        shapeType: String,
        visible: Bool,
        locked: Bool,
        code: String,
        crossCode: String,
        rowFlag: String,
        subsection: String?,
        geometry: [String: Any]?,
        bounds: [String: Double]?,
        centerM: [Double]?,
        yawRad: Double?,
        source: [String: Any]
    ) {
        self.id = id
        self.sourceRow = sourceRow
        self.floorId = floorId
        self.shapeType = shapeType
        self.visible = visible
        self.locked = locked
        self.code = code
        self.crossCode = crossCode
        self.rowFlag = rowFlag
        self.subsection = subsection
        self.geometry = geometry
        self.bounds = bounds
        self.centerM = centerM
        self.yawRad = yawRad
        self.source = source
    }

    static func == (lhs: PriorMapSourceElement, rhs: PriorMapSourceElement) -> Bool {
        guard lhs.id == rhs.id, lhs.sourceRow == rhs.sourceRow,
              lhs.floorId == rhs.floorId, lhs.shapeType == rhs.shapeType,
              lhs.visible == rhs.visible, lhs.locked == rhs.locked,
              lhs.code == rhs.code, lhs.crossCode == rhs.crossCode,
              lhs.rowFlag == rhs.rowFlag, lhs.subsection == rhs.subsection,
              lhs.bounds == rhs.bounds, lhs.centerM == rhs.centerM,
              lhs.yawRad == rhs.yawRad
        else { return false }
        return JSONValueComparer.equal(lhs.geometry, rhs.geometry)
            && JSONValueComparer.equal(lhs.source, rhs.source)
    }
}

/// Non-fatal import observation, structurally identical to the PC
/// warning record.
struct MapSourceWarning: Equatable {
    var code: String
    var row: Int
    var floor: String
    var shapeType: String?
    var message: String

    var canonicalPayload: [String: Any] {
        var payload: [String: Any] = [
            "code": code,
            "row": row,
            "floor": floor,
            "message": message,
        ]
        if let shapeType = shapeType {
            payload["shape_type"] = shapeType
        }
        return payload
    }
}

/// Type-sensitive deep comparison for JSON-ish `[String: Any]` trees.
enum JSONValueComparer {
    static func equal(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case (let left as NSNull, let right as NSNull):
            return left == right
        case (let left as Bool, let right as Bool):
            return left == right
        case (let left as Int, let right as Int):
            return left == right
        case (let left as Double, let right as Double):
            return left == right
        case (let left as String, let right as String):
            return left == right
        case (let left as [Any], let right as [Any]):
            guard left.count == right.count else { return false }
            return zip(left, right).allSatisfy { equal($0, $1) }
        case (let left as [String: Any], let right as [String: Any]):
            guard left.count == right.count else { return false }
            for (key, leftValue) in left {
                guard let rightValue = right[key] else { return false }
                if !equal(leftValue, rightValue) { return false }
            }
            return true
        case (let left as NSNumber, let right as NSNumber):
            return left.doubleValue == right.doubleValue
        default:
            return false
        }
    }
}
