import UIKit
import UniformTypeIdentifiers

/// Picks an XLSX / CSV / JSON store map from the Files app. The picked
/// document is immediately copied into the app-private staging directory
/// and hashed there; the provider's original path is never read again.
/// A failed copy never creates a map record (V1R1 §6.1).
final class MapSourceDocumentPicker: NSObject, UIDocumentPickerDelegate {
    enum PickedOutcome {
        case staged(URL, originalFilename: String)
        case failed(MapSourceImportError)
        case cancelled
    }

    private let onResult: (PickedOutcome) -> Void

    init(onResult: @escaping (PickedOutcome) -> Void) {
        self.onResult = onResult
    }

    static func supportedTypes() -> [UTType] {
        return [
            UTType(filenameExtension: "xlsx", conformingTo: .data) ?? .data,
            .commaSeparatedText,
            .json,
        ]
    }

    /// Presents the document picker; the caller must keep a strong
    /// reference to the picker object until `onResult` fires.
    func present(from viewController: UIViewController) {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: Self.supportedTypes(),
            asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        viewController.present(picker, animated: true)
    }

    func documentPicker(
        _ controller: UIDocumentPickerViewController,
        didPickDocumentsAt urls: [URL]
    ) {
        guard let url = urls.first else {
            onResult(.cancelled)
            return
        }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let originalFilename = url.lastPathComponent
        do {
            // Staging contract (V1R1 §6.1):
            // security-scoped provider -> private temp file with exclusive
            // creation -> stream copy -> fsync -> SHA from staged bytes ->
            // close -> stop security scope.
            let staging = try Self.stagingURL(originalFilename: originalFilename)
            try Self.streamCopy(from: url, to: staging)
            try Self.syncFile(staging)
            _ = CanonicalSourceHasher.sha256(
                try Data(contentsOf: staging, options: .mappedIfSafe))
            onResult(.staged(staging, originalFilename: originalFilename))
        } catch {
            // Copy failed: NO map record is created and the provider URL
            // is never returned to the pipeline.
            let reason = (error as? MapSourceImportError)?.message
                ?? error.localizedDescription
            onResult(.failed(.copyFailed(reason: reason)))
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        onResult(.cancelled)
    }

    /// App-private staging directory:
    /// Application Support/MarketScanner/Import/staging/<uuid>.<ext>
    static func stagingURL(originalFilename: String) throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true)
        let directory = base
            .appendingPathComponent("MarketScanner", isDirectory: true)
            .appendingPathComponent("Import", isDirectory: true)
            .appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let extensionName = (originalFilename as NSString).pathExtension
        let name = "\(UUID().uuidString).\(extensionName)"
        return directory.appendingPathComponent(name)
    }

    /// Stream copy with exclusive destination creation (fails if the
    /// staging path already exists — never overwrites).
    private static func streamCopy(from source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        // Exclusive creation: fail if a stale staging file exists.
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw MapSourceImportError.copyFailed(reason: "staging file already exists")
        }
        guard let input = InputStream(url: source) else {
            throw MapSourceImportError.copyFailed(reason: "cannot open source stream")
        }
        input.open()
        defer { input.close() }
        guard fileManager.createFile(
            atPath: destination.path, contents: nil, attributes: nil) else {
            throw MapSourceImportError.copyFailed(reason: "cannot create staging file")
        }
        let output = OutputStream(
            toFileAtPath: destination.path, append: false)
        guard let output = output else {
            throw MapSourceImportError.copyFailed(reason: "cannot open staging stream")
        }
        output.open()
        defer { output.close() }
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        var copied: Int64 = 0
        while input.hasBytesAvailable {
            let read = input.read(&buffer, maxLength: buffer.count)
            if read < 0 {
                throw MapSourceImportError.copyFailed(reason: "read failed")
            }
            if read == 0 {
                break
            }
            var written = 0
            while written < read {
                let result = output.write(&buffer[written], maxLength: read - written)
                if result < 0 {
                    throw MapSourceImportError.copyFailed(reason: "write failed")
                }
                written += result
            }
            copied += Int64(read)
            if copied > MapSourceImportLimits.maximumSourceFileBytes {
                throw MapSourceImportError.fileTooLarge(
                    limitBytes: MapSourceImportLimits.maximumSourceFileBytes)
            }
        }
    }

    private static func syncFile(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        fsync(descriptor)
    }
}
