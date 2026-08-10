import UIKit
import UniformTypeIdentifiers
import Darwin

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
    private let onStagingStarted: (() -> Void)?
    private let pickerViewController: UIDocumentPickerViewController

    /// Provider copies can block on file-provider hydration, descriptor I/O
    /// and fsync. UIDocumentPickerDelegate callbacks arrive on the main
    /// thread, so the complete security-scoped staging transaction runs on
    /// this dedicated serial queue and only its result returns to UIKit.
    private static let stagingQueue = DispatchQueue(
        label: "MarketScanner.MapSourceDocumentPicker.staging",
        qos: .userInitiated)

    init(
        preparedViewController: UIDocumentPickerViewController? = nil,
        onStagingStarted: (() -> Void)? = nil,
        onResult: @escaping (PickedOutcome) -> Void
    ) {
        precondition(Thread.isMainThread)
        self.pickerViewController = preparedViewController
            ?? Self.makePreparedViewController()
        self.onStagingStarted = onStagingStarted
        self.onResult = onResult
        super.init()
        pickerViewController.delegate = self
    }

    /// UTType lookup and the Files/FileProvider controller both have a
    /// measurable one-time initialization cost on real devices. Keep the
    /// immutable type list cached and allow the import page to construct one
    /// picker during an idle main-run-loop turn instead of inside the tap.
    private static let cachedSupportedTypes: [UTType] = [
        UTType(filenameExtension: "xlsx", conformingTo: .data) ?? .data,
        .commaSeparatedText,
        .json,
    ]

    static func supportedTypes() -> [UTType] {
        return cachedSupportedTypes
    }

    static func makePreparedViewController()
        -> UIDocumentPickerViewController {
        precondition(Thread.isMainThread)
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: cachedSupportedTypes,
            asCopy: true)
        picker.allowsMultipleSelection = false
        picker.loadViewIfNeeded()
        return picker
    }

    /// Presents the document picker; the caller must keep a strong
    /// reference to the picker object until `onResult` fires.
    func present(from viewController: UIViewController) {
        precondition(Thread.isMainThread)
        pickerViewController.delegate = self
        viewController.present(pickerViewController, animated: true)
    }

    func documentPicker(
        _ controller: UIDocumentPickerViewController,
        didPickDocumentsAt urls: [URL]
    ) {
        guard let url = urls.first else {
            deliver(.cancelled)
            return
        }
        let originalFilename = url.lastPathComponent
        onStagingStarted?()
        Self.stagingQueue.async { [self] in
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let outcome: PickedOutcome
            do {
                // Staging contract (V1R1 §6.1):
                // security-scoped provider -> private temp file with
                // exclusive creation -> stream copy -> fsync -> close ->
                // stop security scope. The importer performs the one
                // authoritative stable read and source SHA calculation.
                let staging = try Self.stagingURL(
                    originalFilename: originalFilename)
                try Self.streamCopy(from: url, to: staging)
                outcome = .staged(
                    staging, originalFilename: originalFilename)
            } catch {
                // Copy failed: NO map record is created and the provider URL
                // is never returned to the pipeline.
                let reason = (error as? MapSourceImportError)?.message
                    ?? error.localizedDescription
                outcome = .failed(.copyFailed(reason: reason))
            }
            deliver(outcome)
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        deliver(.cancelled)
    }

    /// UI/coordinator callbacks keep their historical main-thread contract
    /// even though staging now completes on a background queue.
    private func deliver(_ outcome: PickedOutcome) {
        if Thread.isMainThread {
            onResult(outcome)
        } else {
            DispatchQueue.main.async { [self] in
                onResult(outcome)
            }
        }
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

    /// Stream copy with descriptor-level stable-source validation and
    /// exclusive destination creation. Both data and directory entries
    /// are synced before the staged path is exposed to the importer.
    private static func streamCopy(from source: URL, to destination: URL) throws {
        let sourceDescriptor = open(
            source.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard sourceDescriptor >= 0 else {
            throw MapSourceImportError.copyFailed(
                reason: "cannot open provider file without following links")
        }
        defer { _ = close(sourceDescriptor) }
        var sourceBefore = stat()
        guard fstat(sourceDescriptor, &sourceBefore) == 0,
              (sourceBefore.st_mode & S_IFMT) == S_IFREG,
              sourceBefore.st_size >= 0 else {
            throw MapSourceImportError.copyFailed(
                reason: "provider source is not a regular file")
        }
        guard sourceBefore.st_size <= MapSourceImportLimits.maximumSourceFileBytes else {
            throw MapSourceImportError.fileTooLarge(
                limitBytes: MapSourceImportLimits.maximumSourceFileBytes)
        }

        let destinationDescriptor = open(
            destination.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600))
        guard destinationDescriptor >= 0 else {
            throw MapSourceImportError.copyFailed(
                reason: "cannot exclusively create staging file")
        }
        var keepDestination = false
        var destinationNeedsClose = true
        defer {
            if destinationNeedsClose { _ = close(destinationDescriptor) }
            if !keepDestination { try? FileManager.default.removeItem(at: destination) }
        }

        var destinationStat = stat()
        guard fstat(destinationDescriptor, &destinationStat) == 0,
              (destinationStat.st_mode & S_IFMT) == S_IFREG,
              destinationStat.st_nlink == 1 else {
            throw MapSourceImportError.copyFailed(
                reason: "staging destination is not a single regular file")
        }

        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        var copied: Int64 = 0
        while true {
            let readCount = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                while true {
                    let result = Darwin.read(
                        sourceDescriptor, rawBuffer.baseAddress, rawBuffer.count)
                    if result < 0 && errno == EINTR { continue }
                    return result
                }
            }
            guard readCount >= 0 else {
                throw MapSourceImportError.copyFailed(reason: "provider read failed")
            }
            if readCount == 0 { break }
            copied += Int64(readCount)
            if copied > MapSourceImportLimits.maximumSourceFileBytes {
                throw MapSourceImportError.fileTooLarge(
                    limitBytes: MapSourceImportLimits.maximumSourceFileBytes)
            }
            var written = 0
            while written < readCount {
                let result = buffer.withUnsafeBytes { rawBuffer -> Int in
                    while true {
                        let address = rawBuffer.baseAddress!.advanced(by: written)
                        let value = Darwin.write(
                            destinationDescriptor, address, readCount - written)
                        if value < 0 && errno == EINTR { continue }
                        return value
                    }
                }
                guard result > 0 else {
                    throw MapSourceImportError.copyFailed(
                        reason: "staging write failed")
                }
                written += result
            }
        }

        var sourceAfter = stat()
        guard fstat(sourceDescriptor, &sourceAfter) == 0,
              sourceAfter.st_dev == sourceBefore.st_dev,
              sourceAfter.st_ino == sourceBefore.st_ino,
              sourceAfter.st_size == sourceBefore.st_size,
              sourceAfter.st_mtimespec.tv_sec == sourceBefore.st_mtimespec.tv_sec,
              sourceAfter.st_mtimespec.tv_nsec == sourceBefore.st_mtimespec.tv_nsec,
              sourceAfter.st_ctimespec.tv_sec == sourceBefore.st_ctimespec.tv_sec,
              sourceAfter.st_ctimespec.tv_nsec == sourceBefore.st_ctimespec.tv_nsec,
              copied == sourceBefore.st_size else {
            throw MapSourceImportError.copyFailed(
                reason: "provider source changed while it was copied")
        }
        guard fsync(destinationDescriptor) == 0 else {
            throw MapSourceImportError.copyFailed(
                reason: "staging data sync failed")
        }
        guard close(destinationDescriptor) == 0 else {
            throw MapSourceImportError.copyFailed(
                reason: "staging close failed")
        }
        destinationNeedsClose = false

        let parentDescriptor = open(
            destination.deletingLastPathComponent().path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parentDescriptor >= 0 else {
            throw MapSourceImportError.copyFailed(
                reason: "cannot open staging directory for sync")
        }
        defer { _ = close(parentDescriptor) }
        guard fsync(parentDescriptor) == 0 else {
            throw MapSourceImportError.copyFailed(
                reason: "staging directory sync failed")
        }
        keepDestination = true
    }
}
