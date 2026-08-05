import Foundation

/// Reads the XLSX package structure (workbook, relationships, shared
/// strings) from already-extracted ZIP entries. All XML parsing is
/// streaming (SAX) with a strict element/attribute whitelist; external
/// entities are never resolved and formulas are never evaluated.
enum XLSXWorkbookReader {
    struct SheetInfo {
        var name: String
        var relationshipID: String
    }

    struct Relationship {
        var identifier: String
        var type: String
        var target: String
    }

    static let sheetName = "Element Info"

    /// Parses `xl/workbook.xml` sheets in document order.
    static func readSheets(entries: [XLSXZipReader.Entry]) throws -> [SheetInfo] {
        guard let workbook = entries.first(where: { $0.name == "xl/workbook.xml" }) else {
            throw MapSourceImportError.xlsxMissingPart(name: "xl/workbook.xml")
        }
        var sheets: [SheetInfo] = []
        var currentSheet: SheetInfo?
        let delegate = WorkbookDelegate { sheet in
            sheets.append(sheet)
        }
        try parseXML(data: workbook.data, name: "xl/workbook.xml", delegate: delegate)
        return sheets
    }

    /// Parses `xl/_rels/workbook.xml.rels`.
    static func readRelationships(entries: [XLSXZipReader.Entry]) throws -> [Relationship] {
        guard let rels = entries.first(where: { $0.name == "xl/_rels/workbook.xml.rels" }) else {
            throw MapSourceImportError.xlsxMissingPart(name: "xl/_rels/workbook.xml.rels")
        }
        var relationships: [Relationship] = []
        let delegate = RelationshipsDelegate { relationship in
            relationships.append(relationship)
        }
        try parseXML(data: rels.data, name: "xl/_rels/workbook.xml.rels", delegate: delegate)
        return relationships
    }

    /// Parses `xl/sharedStrings.xml` into an ordered string table,
    /// enforcing the frozen count limit while streaming.
    static func readSharedStrings(entries: [XLSXZipReader.Entry]) throws -> [String] {
        guard let shared = entries.first(where: { $0.name == "xl/sharedStrings.xml" }) else {
            return []
        }
        var strings: [String] = []
        var overflowError: Error?
        let delegate = SharedStringsDelegate { text in
            strings.append(text)
            if strings.count > MapSourceImportLimits.maximumSharedStrings {
                overflowError = MapSourceImportError.xlsxSharedStringTooMany(
                    limit: MapSourceImportLimits.maximumSharedStrings)
                return false
            }
            return true
        }
        try parseXML(
            data: shared.data,
            name: "xl/sharedStrings.xml",
            delegate: delegate,
            delegateError: { overflowError })
        return strings
    }

    /// Finds the worksheet relationship target for `relationshipID`.
    static func worksheetTarget(relationships: [Relationship], for relationshipID: String) throws -> String {
        guard let relationship = relationships.first(where: { $0.identifier == relationshipID }) else {
            throw MapSourceImportError.xlsxMissingPart(name: relationshipID)
        }
        return relationship.target
    }

    /// Extracts an entry by a worksheet target like `worksheets/sheet1.xml`.
    static func worksheetEntry(entries: [XLSXZipReader.Entry], target: String) throws -> XLSXZipReader.Entry {
        var candidates = entries.filter { $0.name == "xl/\(target)" }
        if candidates.isEmpty {
            // Some producers use a bare `sheet1.xml` target.
            candidates = entries.filter { $0.name == target }
        }
        guard let entry = candidates.first else {
            throw MapSourceImportError.xlsxMissingPart(name: target)
        }
        return entry
    }

    private static func parseXML(
        data: Data,
        name: String,
        delegate: XMLParserDelegate,
        delegateError: (() -> Error?)? = nil
    ) throws {
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        guard parser.parse() else {
            if let provided = delegateError?() {
                throw provided
            }
            if let error = parser.parserError {
                throw MapSourceImportError.xlsxInvalidXML(name: name, reason: error.localizedDescription)
            }
            throw MapSourceImportError.xlsxInvalidXML(name: name, reason: "解析失败。")
        }
    }
}

// MARK: - SAX delegates

private final class WorkbookDelegate: NSObject, XMLParserDelegate {
    private let onSheet: (XLSXWorkbookReader.SheetInfo) -> Void

    init(onSheet: @escaping (XLSXWorkbookReader.SheetInfo) -> Void) {
        self.onSheet = onSheet
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName == "sheet" else { return }
        guard let name = attributeDict["name"] else { return }
        let relationshipID = attributeDict["r:id"] ?? attributeDict["id"] ?? ""
        onSheet(XLSXWorkbookReader.SheetInfo(name: name, relationshipID: relationshipID))
    }
}

private final class RelationshipsDelegate: NSObject, XMLParserDelegate {
    private let onRelationship: (XLSXWorkbookReader.Relationship) -> Void

    init(onRelationship: @escaping (XLSXWorkbookReader.Relationship) -> Void) {
        self.onRelationship = onRelationship
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName == "Relationship" else { return }
        let relationship = XLSXWorkbookReader.Relationship(
            identifier: attributeDict["Id"] ?? "",
            type: attributeDict["Type"] ?? "",
            target: attributeDict["Target"] ?? ""
        )
        onRelationship(relationship)
    }
}

private final class SharedStringsDelegate: NSObject, XMLParserDelegate {
    private let onString: (String) -> Bool
    private var inText = false
    private var currentText = ""
    private var depth = 0

    init(onString: @escaping (String) -> Bool) {
        self.onString = onString
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "si" {
            currentText = ""
        } else if elementName == "t" {
            inText = true
        }
        depth += 1
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText {
            currentText += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "t" {
            inText = false
        } else if elementName == "si" {
            if !onString(currentText) {
                parser.abortParsing()
            }
        }
        depth -= 1
    }
}
