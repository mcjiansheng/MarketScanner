import Darwin
import Foundation

/// macOS 14 rejects renaming a directory whose root mode has no write bit,
/// even when both names are children of the same writable parent.  This
/// helper implements the only safe publication sequence available for an
/// immutable directory on that platform:
///
/// 1. all payload files and nested directories are already frozen;
/// 2. the root directory is temporarily owner-writable;
/// 3. an exclusive same-parent rename publishes the pathname;
/// 4. the still-open, inode-bound directory descriptor freezes that exact
///    directory to 0555 and fsyncs it;
/// 5. the destination pathname is checked against the bound dev/inode and
///    the parent directory is fsynced.
///
/// The rename itself is not an application commit point.  Callers must keep
/// a durable transaction intent/reference and must not expose the destination
/// to production readers until their own exact tree/hash validation succeeds.
enum ImmutableDirectoryPublication {
    struct Identity: Equatable {
        let device: UInt64
        let inode: UInt64
    }

    enum PublicationError: Error, LocalizedError {
        case invalidPath(String)
        case cannotOpen(String)
        case invalidDirectory(String)
        case unexpectedMode(String)
        case destinationExists(String)
        case cannotThaw(String)
        case cannotRename(String)
        case cannotFreeze(String)
        case identityChanged(String)
        case cannotSync(String)

        var errorDescription: String? {
            switch self {
            case .invalidPath(let detail): return "invalid directory publication path: \(detail)"
            case .cannotOpen(let detail): return "cannot open directory publication path: \(detail)"
            case .invalidDirectory(let detail): return "directory publication source is invalid: \(detail)"
            case .unexpectedMode(let detail): return "directory publication mode is invalid: \(detail)"
            case .destinationExists(let detail): return "directory publication destination exists: \(detail)"
            case .cannotThaw(let detail): return "cannot make directory root renameable: \(detail)"
            case .cannotRename(let detail): return "cannot publish directory: \(detail)"
            case .cannotFreeze(let detail): return "cannot freeze published directory: \(detail)"
            case .identityChanged(let detail): return "published directory identity changed: \(detail)"
            case .cannotSync(let detail): return "cannot sync directory publication: \(detail)"
            }
        }
    }

    static let immutableMode: mode_t = 0o555
    static let renameableMode: mode_t = 0o755

    /// Returns the no-follow dev/inode identity after requiring a real
    /// directory whose root mode is one of `allowedModes`.
    static func identity(
        of directory: URL,
        allowedModes: Set<mode_t>
    ) throws -> Identity {
        let opened = try openBoundDirectory(directory)
        defer { _ = close(opened.descriptor) }
        let mode = opened.metadata.st_mode & mode_t(0o777)
        guard allowedModes.contains(mode) else {
            throw PublicationError.unexpectedMode(
                "\(directory.path) mode=\(String(mode, radix: 8))")
        }
        return Identity(
            device: UInt64(opened.metadata.st_dev),
            inode: UInt64(opened.metadata.st_ino))
    }

    /// Exclusively renames a sibling directory and leaves the destination
    /// root frozen at 0555.  A frozen source is thawed only at the root; a
    /// prepared 0755 source is renamed directly.  Payload modes are never
    /// changed here.
    @discardableResult
    static func publish(
        source: URL,
        destination: URL,
        expectedIdentity: Identity? = nil,
        afterRootThawBeforeRename: (() throws -> Void)? = nil,
        afterRenameBeforeFreeze: (() throws -> Void)? = nil,
        afterFreezeBeforeDirectorySync: (() throws -> Void)? = nil,
        afterFreezeBeforeParentSync: (() throws -> Void)? = nil
    ) throws -> Identity {
        let parent = source.deletingLastPathComponent().standardizedFileURL
        guard destination.deletingLastPathComponent().standardizedFileURL == parent,
              isSafeBasename(source.lastPathComponent),
              isSafeBasename(destination.lastPathComponent),
              source.lastPathComponent != destination.lastPathComponent else {
            throw PublicationError.invalidPath(
                "source and destination must be distinct safe siblings")
        }

        let openedParent = try openBoundDirectory(parent)
        let parentDescriptor = openedParent.descriptor
        defer { _ = close(parentDescriptor) }

        let sourceDescriptor = openat(
            parentDescriptor,
            source.lastPathComponent,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard sourceDescriptor >= 0 else {
            throw PublicationError.cannotOpen(
                "source \(source.path): \(errnoText())")
        }
        defer { _ = close(sourceDescriptor) }

        var sourceMetadata = stat()
        guard fstat(sourceDescriptor, &sourceMetadata) == 0,
              (sourceMetadata.st_mode & S_IFMT) == S_IFDIR else {
            throw PublicationError.invalidDirectory(source.path)
        }
        var sourcePathMetadata = stat()
        guard fstatat(
            parentDescriptor,
            source.lastPathComponent,
            &sourcePathMetadata,
            AT_SYMLINK_NOFOLLOW) == 0,
              sameDirectoryIdentity(sourceMetadata, sourcePathMetadata) else {
            throw PublicationError.identityChanged(
                "source changed while opening \(source.path)")
        }
        let identity = Identity(
            device: UInt64(sourceMetadata.st_dev),
            inode: UInt64(sourceMetadata.st_ino))
        if let expectedIdentity, expectedIdentity != identity {
            throw PublicationError.identityChanged(
                "source dev/inode does not match durable intent")
        }

        var destinationMetadata = stat()
        if fstatat(
            parentDescriptor,
            destination.lastPathComponent,
            &destinationMetadata,
            AT_SYMLINK_NOFOLLOW) == 0 {
            throw PublicationError.destinationExists(destination.path)
        }
        guard errno == ENOENT else {
            throw PublicationError.cannotOpen(
                "destination \(destination.path): \(errnoText())")
        }

        let originalMode = sourceMetadata.st_mode & mode_t(0o777)
        guard originalMode == immutableMode || originalMode == renameableMode else {
            throw PublicationError.unexpectedMode(
                "\(source.path) mode=\(String(originalMode, radix: 8))")
        }
        let thawed = originalMode == immutableMode
        if thawed {
            guard fchmod(sourceDescriptor, renameableMode) == 0 else {
                throw PublicationError.cannotThaw(
                    "\(source.path): \(errnoText())")
            }
            guard fsync(sourceDescriptor) == 0 else {
                let syncError = errnoText()
                _ = fchmod(sourceDescriptor, immutableMode)
                _ = fsync(sourceDescriptor)
                throw PublicationError.cannotSync(
                    "thawed source \(source.path): \(syncError)")
            }
            do {
                try afterRootThawBeforeRename?()
            } catch {
                guard fchmod(sourceDescriptor, immutableMode) == 0,
                      fsync(sourceDescriptor) == 0 else {
                    throw PublicationError.cannotFreeze(
                        "cannot restore source after pre-rename failure: \(errnoText())")
                }
                throw error
            }
        }

        do {
            try requireBoundDirectoryPath(
                descriptor: parentDescriptor,
                url: parent,
                expectedMetadata: openedParent.metadata,
                context: "publication parent before rename")
            var sourceBeforeRename = stat()
            var openedBeforeRename = stat()
            guard fstat(sourceDescriptor, &openedBeforeRename) == 0,
                  fstatat(
                    parentDescriptor,
                    source.lastPathComponent,
                    &sourceBeforeRename,
                    AT_SYMLINK_NOFOLLOW) == 0,
                  sameDirectoryIdentity(sourceMetadata, openedBeforeRename),
                  sameDirectoryIdentity(sourceMetadata, sourceBeforeRename),
                  (openedBeforeRename.st_mode & mode_t(0o777))
                    == renameableMode,
                  (sourceBeforeRename.st_mode & mode_t(0o777))
                    == renameableMode else {
                throw PublicationError.identityChanged(
                    "source changed before exclusive rename")
            }
        } catch {
            if thawed {
                guard fchmod(sourceDescriptor, immutableMode) == 0,
                      fsync(sourceDescriptor) == 0 else {
                    throw PublicationError.cannotFreeze(
                        "cannot restore source after binding failure: \(errnoText())")
                }
            }
            throw error
        }

        guard renameatx_np(
            parentDescriptor,
            source.lastPathComponent,
            parentDescriptor,
            destination.lastPathComponent,
            UInt32(RENAME_EXCL)) == 0 else {
            let renameError = errnoText()
            if thawed {
                guard fchmod(sourceDescriptor, immutableMode) == 0,
                      fsync(sourceDescriptor) == 0 else {
                    throw PublicationError.cannotFreeze(
                        "rename failed (\(renameError)) and source refreeze failed: \(errnoText())")
                }
            }
            throw PublicationError.cannotRename(
                "\(source.lastPathComponent) -> \(destination.lastPathComponent): \(renameError)")
        }

        // A real process exit here deliberately leaves a 0755 destination.
        // The caller's durable intent is the only authority allowed to
        // recover that state.  A thrown test fault models the same boundary.
        try afterRenameBeforeFreeze?()

        guard fchmod(sourceDescriptor, immutableMode) == 0 else {
            throw PublicationError.cannotFreeze(
                "\(destination.path): \(errnoText())")
        }
        try afterFreezeBeforeDirectorySync?()
        guard fsync(sourceDescriptor) == 0 else {
            throw PublicationError.cannotSync(
                "published directory \(destination.path): \(errnoText())")
        }

        var destinationAfter = stat()
        var openedAfter = stat()
        guard fstat(sourceDescriptor, &openedAfter) == 0,
              fstatat(
                parentDescriptor,
                destination.lastPathComponent,
                &destinationAfter,
                AT_SYMLINK_NOFOLLOW) == 0,
              sameDirectoryIdentity(sourceMetadata, openedAfter),
              sameDirectoryIdentity(sourceMetadata, destinationAfter),
              (openedAfter.st_mode & mode_t(0o777)) == immutableMode,
              (destinationAfter.st_mode & mode_t(0o777)) == immutableMode else {
            throw PublicationError.identityChanged(
                "destination is not the frozen source inode")
        }
        var sourceAfter = stat()
        let sourceLookup = fstatat(
            parentDescriptor,
            source.lastPathComponent,
            &sourceAfter,
            AT_SYMLINK_NOFOLLOW)
        guard sourceLookup != 0 else {
            throw PublicationError.identityChanged(
                "source basename was recreated during publication")
        }
        guard errno == ENOENT else {
            throw PublicationError.cannotOpen(
                "cannot verify removed source basename: \(errnoText())")
        }

        try afterFreezeBeforeParentSync?()
        guard fsync(parentDescriptor) == 0 else {
            throw PublicationError.cannotSync(
                "parent \(parent.path): \(errnoText())")
        }
        try requireBoundDirectoryPath(
            descriptor: parentDescriptor,
            url: parent,
            expectedMetadata: openedParent.metadata,
            context: "publication parent after sync")
        var finalDestination = stat()
        var finalOpened = stat()
        guard fstat(sourceDescriptor, &finalOpened) == 0,
              fstatat(
                parentDescriptor,
                destination.lastPathComponent,
                &finalDestination,
                AT_SYMLINK_NOFOLLOW) == 0,
              sameDirectoryIdentity(sourceMetadata, finalOpened),
              sameDirectoryIdentity(sourceMetadata, finalDestination),
              (finalOpened.st_mode & mode_t(0o777)) == immutableMode,
              (finalDestination.st_mode & mode_t(0o777)) == immutableMode else {
            throw PublicationError.identityChanged(
                "destination changed after publication parent sync")
        }
        var finalSource = stat()
        let finalSourceLookup = fstatat(
            parentDescriptor,
            source.lastPathComponent,
            &finalSource,
            AT_SYMLINK_NOFOLLOW)
        guard finalSourceLookup != 0 else {
            throw PublicationError.identityChanged(
                "source basename was recreated after publication parent sync")
        }
        guard errno == ENOENT else {
            throw PublicationError.cannotOpen(
                "cannot verify final source basename absence: \(errnoText())")
        }
        return identity
    }

    /// Completes the freeze side of an interrupted publication.  Callers
    /// may invoke this only after a durable business-layer intent/diagnostic
    /// has bound `expectedIdentity` to this pathname.
    static func freezeInterruptedDestination(
        _ directory: URL,
        expectedIdentity: Identity,
        afterFreezeBeforeParentSync: (() throws -> Void)? = nil
    ) throws {
        let parent = directory.deletingLastPathComponent().standardizedFileURL
        guard isSafeBasename(directory.lastPathComponent) else {
            throw PublicationError.invalidPath(
                "interrupted destination must have a safe basename")
        }
        let openedParent = try openBoundDirectory(parent)
        let parentDescriptor = openedParent.descriptor
        defer { _ = close(parentDescriptor) }
        let descriptor = openat(
            parentDescriptor,
            directory.lastPathComponent,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw PublicationError.cannotOpen(
                "interrupted destination \(directory.path): \(errnoText())")
        }
        defer { _ = close(descriptor) }
        var opened = stat()
        var pathBefore = stat()
        guard fstat(descriptor, &opened) == 0,
              (opened.st_mode & S_IFMT) == S_IFDIR,
              fstatat(
                parentDescriptor,
                directory.lastPathComponent,
                &pathBefore,
                AT_SYMLINK_NOFOLLOW) == 0,
              sameDirectoryIdentity(opened, pathBefore) else {
            throw PublicationError.identityChanged(
                "interrupted destination changed while opening")
        }
        let actualIdentity = Identity(
            device: UInt64(opened.st_dev),
            inode: UInt64(opened.st_ino))
        guard actualIdentity == expectedIdentity else {
            throw PublicationError.identityChanged(
                "interrupted destination dev/inode does not match durable intent")
        }
        try requireBoundDirectoryPath(
            descriptor: parentDescriptor,
            url: parent,
            expectedMetadata: openedParent.metadata,
            context: "interrupted publication parent before freeze")
        let mode = opened.st_mode & mode_t(0o777)
        guard mode == renameableMode || mode == immutableMode else {
            throw PublicationError.unexpectedMode(
                "\(directory.path) mode=\(String(mode, radix: 8))")
        }
        if mode != immutableMode {
            guard fchmod(descriptor, immutableMode) == 0 else {
                throw PublicationError.cannotFreeze(
                    "\(directory.path): \(errnoText())")
            }
        }
        // Always fsync the bound directory, including an already-0555 root.
        // A real process may have died after fchmod(0555) but before the
        // original directory fsync completed.
        guard fsync(descriptor) == 0 else {
            throw PublicationError.cannotSync(
                "\(directory.path): \(errnoText())")
        }

        var pathAfter = stat()
        var openedAfter = stat()
        guard fstat(descriptor, &openedAfter) == 0,
              fstatat(
                parentDescriptor,
                directory.lastPathComponent,
                &pathAfter,
                AT_SYMLINK_NOFOLLOW) == 0,
              sameDirectoryIdentity(opened, openedAfter),
              sameDirectoryIdentity(opened, pathAfter),
              (openedAfter.st_mode & mode_t(0o777)) == immutableMode,
              (pathAfter.st_mode & mode_t(0o777)) == immutableMode else {
            throw PublicationError.identityChanged(
                "interrupted destination changed while freezing")
        }
        try afterFreezeBeforeParentSync?()

        guard fsync(parentDescriptor) == 0 else {
            throw PublicationError.cannotSync(
                "parent of \(directory.path): \(errnoText())")
        }
        try requireBoundDirectoryPath(
            descriptor: parentDescriptor,
            url: parent,
            expectedMetadata: openedParent.metadata,
            context: "interrupted publication parent after sync")
        var finalPath = stat()
        var finalOpened = stat()
        guard fstat(descriptor, &finalOpened) == 0,
              fstatat(
                parentDescriptor,
                directory.lastPathComponent,
                &finalPath,
                AT_SYMLINK_NOFOLLOW) == 0,
              sameDirectoryIdentity(opened, finalOpened),
              sameDirectoryIdentity(opened, finalPath),
              (finalOpened.st_mode & mode_t(0o777)) == immutableMode,
              (finalPath.st_mode & mode_t(0o777)) == immutableMode else {
            throw PublicationError.identityChanged(
                "interrupted destination changed after parent sync")
        }
    }

    private static func openBoundDirectory(
        _ directory: URL
    ) throws -> (descriptor: Int32, metadata: stat) {
        var pathMetadata = stat()
        guard lstat(directory.path, &pathMetadata) == 0,
              (pathMetadata.st_mode & S_IFMT) == S_IFDIR else {
            throw PublicationError.invalidDirectory(directory.path)
        }
        let descriptor = open(
            directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw PublicationError.cannotOpen(
                "\(directory.path): \(errnoText())")
        }
        var openedMetadata = stat()
        guard fstat(descriptor, &openedMetadata) == 0,
              (openedMetadata.st_mode & S_IFMT) == S_IFDIR,
              sameDirectoryIdentity(pathMetadata, openedMetadata) else {
            _ = close(descriptor)
            throw PublicationError.identityChanged(
                "\(directory.path) changed while opening")
        }
        return (descriptor, openedMetadata)
    }

    private static func sameDirectoryIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        return (rhs.st_mode & S_IFMT) == S_IFDIR
            && lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
    }

    private static func requireBoundDirectoryPath(
        descriptor: Int32,
        url: URL,
        expectedMetadata: stat,
        context: String
    ) throws {
        var openedMetadata = stat()
        var pathMetadata = stat()
        guard fstat(descriptor, &openedMetadata) == 0,
              lstat(url.path, &pathMetadata) == 0,
              sameDirectoryIdentity(expectedMetadata, openedMetadata),
              sameDirectoryIdentity(expectedMetadata, pathMetadata) else {
            throw PublicationError.identityChanged(
                "\(context) dev/inode/path binding changed")
        }
    }

    private static func isSafeBasename(_ value: String) -> Bool {
        return !value.isEmpty && value != "." && value != ".."
            && !value.contains("/") && !value.contains("\\")
            && !value.utf8.contains(0)
    }

    private static func errnoText() -> String {
        return String(cString: strerror(errno))
    }
}
