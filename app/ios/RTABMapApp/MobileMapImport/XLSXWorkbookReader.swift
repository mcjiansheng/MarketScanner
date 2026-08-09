import Foundation

private func xlsxWorkbookXMLLocalName(_ qualified: String) -> String {
    return qualified.split(separator: ":").last.map(String.init) ?? qualified
}

/// Reads the XLSX package structure (workbook, relationships, shared
/// strings) from already-extracted ZIP entries. All XML parsing is
/// streaming (SAX) with a strict element/attribute whitelist; external
/// entities are never resolved and formulas are never evaluated.
enum XLSXWorkbookReader {
    static let spreadsheetNamespace =
        "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    static let packageRelationshipsNamespace =
        "http://schemas.openxmlformats.org/package/2006/relationships"

    struct SheetInfo {
        var name: String
        var relationshipID: String
    }

    struct Relationship {
        var identifier: String
        var type: String
        var target: String
        var targetMode: String?

        init(
            identifier: String,
            type: String,
            target: String,
            targetMode: String? = nil
        ) {
            self.identifier = identifier
            self.type = type
            self.target = target
            self.targetMode = targetMode
        }
    }

    static let sheetName = "Element Info"

    /// Parses `xl/workbook.xml` sheets in document order.
    static func readSheets(entries: [XLSXZipReader.Entry]) throws -> [SheetInfo] {
        guard let workbook = entries.first(where: { $0.name == "xl/workbook.xml" }) else {
            throw MapSourceImportError.xlsxMissingPart(name: "xl/workbook.xml")
        }
        var sheets: [SheetInfo] = []
        var overflowError: Error?
        let delegate = WorkbookDelegate { sheet in
            sheets.append(sheet)
            if sheets.count > MapSourceImportLimits.maximumWorkbookSheets {
                overflowError = MapSourceImportError.xlsxInvalidXML(
                    name: "xl/workbook.xml",
                    reason: "工作簿 sheet 记录超过冻结上限。")
                return false
            }
            return true
        }
        try parseXML(
            data: workbook.data, name: "xl/workbook.xml", delegate: delegate,
            delegateError: { overflowError ?? delegate.error })
        return sheets
    }

    /// Parses `xl/_rels/workbook.xml.rels`.
    static func readRelationships(entries: [XLSXZipReader.Entry]) throws -> [Relationship] {
        guard let rels = entries.first(where: { $0.name == "xl/_rels/workbook.xml.rels" }) else {
            throw MapSourceImportError.xlsxMissingPart(name: "xl/_rels/workbook.xml.rels")
        }
        var relationships: [Relationship] = []
        var overflowError: Error?
        let delegate = RelationshipsDelegate { relationship in
            relationships.append(relationship)
            if relationships.count
                > MapSourceImportLimits.maximumWorkbookRelationships {
                overflowError = MapSourceImportError.xlsxInvalidXML(
                    name: "xl/_rels/workbook.xml.rels",
                    reason: "工作簿 Relationship 记录超过冻结上限。")
                return false
            }
            return true
        }
        try parseXML(
            data: rels.data, name: "xl/_rels/workbook.xml.rels",
            delegate: delegate,
            delegateError: { overflowError ?? delegate.error })
        var seenIdentifiers: Set<String> = []
        for relationship in relationships {
            guard !relationship.identifier.isEmpty,
                  !relationship.type.isEmpty,
                  !relationship.target.isEmpty,
                  relationship.targetMode == nil
                    || relationship.targetMode == "Internal",
                  seenIdentifiers.insert(relationship.identifier).inserted else {
                throw MapSourceImportError.xlsxInvalidXML(
                    name: "xl/_rels/workbook.xml.rels",
                    reason: "工作簿关系缺少字段或包含重复 ID。")
            }
        }
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
            delegateError: { overflowError ?? delegate.error })
        return strings
    }

    /// Finds the worksheet relationship target for `relationshipID`.
    static func worksheetTarget(relationships: [Relationship], for relationshipID: String) throws -> String {
        let matches = relationships.filter { $0.identifier == relationshipID }
        guard matches.count == 1, let relationship = matches.first else {
            throw MapSourceImportError.xlsxMissingPart(name: relationshipID)
        }
        guard relationship.type.hasSuffix("/worksheet") else {
            throw MapSourceImportError.xlsxInvalidXML(
                name: "xl/_rels/workbook.xml.rels",
                reason: "工作表关系类型无效：\(relationshipID)")
        }
        try validateWorksheetTarget(relationship.target)
        return relationship.target
    }

    /// Every workbook sheet must own one distinct relationship and resolve
    /// to one distinct ZIP worksheet part. Aliasing Basic/Element/Shelf (or
    /// any other sheet) to the same authority makes sheet-name semantics
    /// dependent on workbook indirection and is rejected fail-closed.
    static func validateSheetAuthorities(
        sheets: [SheetInfo],
        relationships: [Relationship],
        entries: [XLSXZipReader.Entry]
    ) throws {
        guard sheets.count <= MapSourceImportLimits.maximumWorkbookSheets,
              relationships.count
                <= MapSourceImportLimits.maximumWorkbookRelationships else {
            throw MapSourceImportError.xlsxInvalidXML(
                name: "xl/workbook.xml",
                reason: "工作簿 sheet/Relationship 记录超过冻结上限。")
        }
        var relationshipsByID: [String: Relationship] = [:]
        relationshipsByID.reserveCapacity(relationships.count)
        for relationship in relationships {
            guard !relationship.identifier.isEmpty,
                  !relationship.type.isEmpty,
                  !relationship.target.isEmpty,
                  relationship.targetMode == nil
                    || relationship.targetMode == "Internal",
                  relationshipsByID[relationship.identifier] == nil else {
                throw MapSourceImportError.xlsxInvalidXML(
                    name: "xl/_rels/workbook.xml.rels",
                    reason: "工作簿关系缺少字段或包含重复 ID。")
            }
            relationshipsByID[relationship.identifier] = relationship
        }
        let entriesByName = Dictionary(grouping: entries, by: { $0.name })
        var names = Set<String>()
        var relationshipIDs = Set<String>()
        var entryNames = Set<String>()
        for sheet in sheets {
            guard !sheet.name.isEmpty,
                  !sheet.relationshipID.isEmpty,
                  names.insert(sheet.name).inserted,
                  relationshipIDs.insert(sheet.relationshipID).inserted else {
                throw MapSourceImportError.xlsxInvalidXML(
                    name: "xl/workbook.xml",
                    reason: "工作表名称或关系 ID 缺失/重复。")
            }
            guard let relationship = relationshipsByID[sheet.relationshipID]
            else {
                throw MapSourceImportError.xlsxMissingPart(
                    name: sheet.relationshipID)
            }
            guard relationship.type.hasSuffix("/worksheet") else {
                throw MapSourceImportError.xlsxInvalidXML(
                    name: "xl/_rels/workbook.xml.rels",
                    reason: "工作表关系类型无效：\(sheet.relationshipID)")
            }
            try validateWorksheetTarget(relationship.target)
            let candidateNames = Set([
                "xl/\(relationship.target)", relationship.target,
            ])
            let candidates = candidateNames.flatMap {
                entriesByName[$0] ?? []
            }
            guard candidates.count == 1, let entry = candidates.first else {
                if candidates.count > 1 {
                    throw MapSourceImportError.xlsxInvalidXML(
                        name: "xl/_rels/workbook.xml.rels",
                        reason: "工作表关系目标存在歧义：\(relationship.target)")
                }
                throw MapSourceImportError.xlsxMissingPart(
                    name: relationship.target)
            }
            guard entryNames.insert(entry.name).inserted else {
                throw MapSourceImportError.xlsxInvalidXML(
                    name: "xl/workbook.xml",
                    reason: "多个工作表指向同一 worksheet authority。")
            }
        }
    }

    private static func validateWorksheetTarget(_ target: String) throws {
        guard !target.hasPrefix("/"), !target.hasPrefix("\\"),
              !target.contains("\\"), !target.contains(":"),
              !target.split(separator: "/", omittingEmptySubsequences: false)
                .contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else {
            throw MapSourceImportError.xlsxInvalidXML(
                name: "xl/_rels/workbook.xml.rels",
                reason: "工作表关系目标不安全：\(target)")
        }
    }

    /// Extracts an entry by a worksheet target like `worksheets/sheet1.xml`.
    static func worksheetEntry(entries: [XLSXZipReader.Entry], target: String) throws -> XLSXZipReader.Entry {
        let candidateNames = Set(["xl/\(target)", target])
        let candidates = entries.filter { candidateNames.contains($0.name) }
        guard candidates.count == 1, let entry = candidates.first else {
            if candidates.count > 1 {
                throw MapSourceImportError.xlsxInvalidXML(
                    name: "xl/_rels/workbook.xml.rels",
                    reason: "工作表关系目标存在歧义：\(target)")
            }
            throw MapSourceImportError.xlsxMissingPart(name: target)
        }
        return entry
    }

    static func validateXMLDeclarations(data: Data, name: String) throws {
        if containsASCIIInsensitive(data, token: Array("<!DOCTYPE".utf8))
            || containsASCIIInsensitive(data, token: Array("<!ENTITY".utf8)) {
            throw MapSourceImportError.xlsxInvalidXML(
                name: name, reason: "不支持 DOCTYPE/ENTITY XML 声明。")
        }
    }

    private static func containsASCIIInsensitive(
        _ data: Data,
        token: [UInt8]
    ) -> Bool {
        guard !token.isEmpty, data.count >= token.count else { return false }
        let bytes = [UInt8](data)
        for start in 0...(bytes.count - token.count) {
            var matches = true
            for offset in token.indices {
                let value = bytes[start + offset]
                let upper = (97...122).contains(value) ? value - 32 : value
                if upper != token[offset] {
                    matches = false
                    break
                }
            }
            if matches { return true }
        }
        return false
    }

    private static func parseXML(
        data: Data,
        name: String,
        delegate: XMLParserDelegate,
        delegateError: (() -> Error?)? = nil
    ) throws {
        try validateXMLDeclarations(data: data, name: name)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
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
    var error: Error?
    private let onSheet: (XLSXWorkbookReader.SheetInfo) -> Bool
    private var stack: [String] = []

    init(onSheet: @escaping (XLSXWorkbookReader.SheetInfo) -> Bool) {
        self.onSheet = onSheet
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let localName = xlsxWorkbookXMLLocalName(elementName)
        guard error == nil else { return }
        if stack.isEmpty,
           (localName != "workbook"
            || namespaceURI != XLSXWorkbookReader.spreadsheetNamespace) {
            fail(parser, reason: "workbook 根元素或命名空间无效。")
            return
        }
        if localName == "sheets",
           (namespaceURI != XLSXWorkbookReader.spreadsheetNamespace
            || stack != ["workbook"]) {
            fail(parser, reason: "sheets 不在 workbook 权威路径。")
            return
        }
        if localName == "sheet" {
            guard namespaceURI == XLSXWorkbookReader.spreadsheetNamespace,
                  stack == ["workbook", "sheets"],
                  let name = attributeDict["name"] else {
                fail(parser, reason: "sheet 不在 workbook/sheets 权威路径。")
                return
            }
            let relationshipID = attributeDict["r:id"] ?? ""
            if !onSheet(XLSXWorkbookReader.SheetInfo(
                name: name, relationshipID: relationshipID)) {
                parser.abortParsing()
                return
            }
        }
        stack.append(localName)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if !stack.isEmpty { stack.removeLast() }
    }

    private func fail(_ parser: XMLParser, reason: String) {
        error = MapSourceImportError.xlsxInvalidXML(
            name: "xl/workbook.xml", reason: reason)
        parser.abortParsing()
    }
}

private final class RelationshipsDelegate: NSObject, XMLParserDelegate {
    var error: Error?
    private let onRelationship: (XLSXWorkbookReader.Relationship) -> Bool
    private var stack: [String] = []

    init(onRelationship: @escaping (XLSXWorkbookReader.Relationship) -> Bool) {
        self.onRelationship = onRelationship
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let localName = xlsxWorkbookXMLLocalName(elementName)
        guard error == nil else { return }
        if stack.isEmpty,
           (localName != "Relationships"
            || namespaceURI
                != XLSXWorkbookReader.packageRelationshipsNamespace) {
            fail(parser, reason: "Relationships 根元素或命名空间无效。")
            return
        }
        if localName == "Relationship" {
            guard namespaceURI
                    == XLSXWorkbookReader.packageRelationshipsNamespace,
                  stack == ["Relationships"] else {
                fail(parser, reason: "Relationship 不在权威根路径。")
                return
            }
            let relationship = XLSXWorkbookReader.Relationship(
                identifier: attributeDict["Id"] ?? "",
                type: attributeDict["Type"] ?? "",
                target: attributeDict["Target"] ?? "",
                targetMode: attributeDict["TargetMode"])
            if !onRelationship(relationship) {
                parser.abortParsing()
                return
            }
        }
        stack.append(localName)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if !stack.isEmpty { stack.removeLast() }
    }

    private func fail(_ parser: XMLParser, reason: String) {
        error = MapSourceImportError.xlsxInvalidXML(
            name: "xl/_rels/workbook.xml.rels", reason: reason)
        parser.abortParsing()
    }
}

private final class SharedStringsDelegate: NSObject, XMLParserDelegate {
    var error: Error?
    private let onString: (String) -> Bool
    private var inText = false
    private var currentText = ""
    private var currentUTF8Bytes = 0
    private var depth = 0
    private var stack: [String] = []

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
        let localName = xlsxWorkbookXMLLocalName(elementName)
        guard error == nil else { return }
        if stack.isEmpty,
           (localName != "sst"
            || namespaceURI != XLSXWorkbookReader.spreadsheetNamespace) {
            fail(parser, reason: "sharedStrings 根元素或命名空间无效。")
            return
        }
        if localName == "si" {
            guard namespaceURI == XLSXWorkbookReader.spreadsheetNamespace,
                  stack == ["sst"] else {
                fail(parser, reason: "shared string 不在 sst 权威路径。")
                return
            }
            currentText = ""
            currentUTF8Bytes = 0
        } else if localName == "t" {
            guard namespaceURI == XLSXWorkbookReader.spreadsheetNamespace,
                  stack.contains("si") else {
                fail(parser, reason: "shared string text 不在 si 中。")
                return
            }
            inText = true
        }
        stack.append(localName)
        depth += 1
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText {
            currentUTF8Bytes += string.lengthOfBytes(using: .utf8)
            if currentUTF8Bytes > Int(MapSourceImportLimits.maximumCellBytes) {
                fail(parser, reason: "共享字符串超过 1 MiB 单元格上限。")
                return
            }
            currentText += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let localName = xlsxWorkbookXMLLocalName(elementName)
        if localName == "t" {
            inText = false
        } else if localName == "si" {
            if !onString(currentText) {
                parser.abortParsing()
            }
        }
        if !stack.isEmpty { stack.removeLast() }
        depth -= 1
    }

    private func fail(_ parser: XMLParser, reason: String) {
        if error == nil {
            error = MapSourceImportError.xlsxInvalidXML(
                name: "xl/sharedStrings.xml", reason: reason)
        }
        parser.abortParsing()
    }
}
