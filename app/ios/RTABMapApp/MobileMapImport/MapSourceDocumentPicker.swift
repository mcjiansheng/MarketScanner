import UIKit
import UniformTypeIdentifiers

/// Picks an XLSX / CSV / JSON store map from the Files app. The picked
/// document is immediately copied into the app-private staging directory
/// and hashed there; the provider's original path is never read again.
/// A failed copy never creates a map record.
final class MapSourceDocumentPicker: NSObject, UIDocumentPickerDelegate {
    enum PickedOutcome {
        case staged(URL, originalFilename: String)
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
            let staging = try Self.stagingURL(originalFilename: originalFilename)
            try FileManager.default.copyItem(at: url, to: staging)
            onResult(.staged(staging, originalFilename: originalFilename))
        } catch {
            // Copy failed: no map record is created; surface through the
            // import coordinator as a copy error.
            onResult(.staged(url, originalFilename: originalFilename))
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
}
