"""Source-level regression contracts for the unified mobile scan UX.

These checks complement the Swift package/integrity host tests. They protect
the production routing and main-thread boundaries that previously caused the
field-reported 3-9 second navigation freezes and the two separate scan-start
failures.
"""

from __future__ import annotations

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[3]


class MobileScanUXContractTests(unittest.TestCase):
    def source(self, relative: str) -> str:
        return (ROOT / relative).read_text(encoding="utf-8")

    def test_optional_scan_display_name_flows_without_becoming_path_authority(
        self,
    ) -> None:
        coordinator = self.source(
            "app/ios/RTABMapApp/MobileOnlyWorkflow/"
            "MobileOnlyWorkflowCoordinator.swift"
        )
        setup = self.source(
            "app/ios/RTABMapApp/MobileOnlyWorkflow/UI/"
            "MobileScanSetupViewController.swift"
        )
        processing = self.source(
            "app/ios/RTABMapApp/MobileOnlyWorkflow/UI/"
            "MobileProcessingViewController.swift"
        )
        core = self.source(
            "app/ios/RTABMapApp/PriorMapLocalizationCore.swift"
        )
        session = self.source(
            "app/ios/RTABMapApp/SupermarketScanSession.swift"
        )
        host = self.source("app/ios/RTABMapApp/ViewController.swift")

        self.assertIn("var scanDisplayName: String", coordinator)
        self.assertIn("enum MarketScannerScanName", core)
        self.assertIn("static let maximumLength = 64", core)
        self.assertIn('static let metadataKey = "scanDisplayName"', core)
        self.assertIn("static func sanitize(_ raw: String?)", core)
        self.assertIn("static func effectiveName(", core)
        self.assertIn("let scanDisplayName: String?", core)
        self.assertIn("scanDisplayName: String? = nil", core)

        self.assertIn('sectionLabel("扫描名称（可选）")', setup)
        self.assertIn('scanNameField.accessibilityLabel = "扫描名称"', setup)
        self.assertIn("MarketScannerScanName.effectiveName(", setup)
        self.assertIn("scanDisplayName: scanDisplayName", setup)

        self.assertGreaterEqual(
            session.count("scanDisplayName: scanConfiguration.scanDisplayName"),
            1,
        )
        self.assertIn(
            "scanDisplayName: scanSession.scanConfiguration.scanDisplayName",
            host,
        )
        self.assertIn("scanDisplayName: resolvedScanDisplayName", host)
        self.assertIn("MarketScannerScanName.sanitize(name)", processing)

        directory_start = session.index("func startNewSessionIfNeeded()")
        directory_end = session.index("func resetCurrentSegment()", directory_start)
        self.assertNotIn(
            "scanDisplayName",
            session[directory_start:directory_end],
            "display metadata must never change the canonical session path",
        )

    def test_primary_scan_route_does_not_reach_legacy_wizard(self) -> None:
        source = self.source("app/ios/RTABMapApp/ViewController.swift")
        start = source.index("private func presentNewScanModePicker()")
        end = source.index("private func preparePriorMapLocalization", start)
        route = source[start:end]
        self.assertIn("MobileMapLibraryViewController(", route)
        self.assertIn("purpose: .selectForScan", route)
        self.assertNotIn("MobileScanSetupViewController", route)
        self.assertNotIn("PriorMapWizardViewController", route)
        self.assertNotIn("self.newScan(configuration:", route)

    def test_scan_selection_precedes_exact_package_loading(self) -> None:
        library = self.source(
            "app/ios/RTABMapApp/MobileOnlyWorkflow/UI/"
            "MobileMapLibraryViewController.swift"
        )
        setup = self.source(
            "app/ios/RTABMapApp/MobileOnlyWorkflow/UI/"
            "MobileScanSetupViewController.swift"
        )
        self.assertIn("case selectForScan", library)
        self.assertIn('importButton.setTitle("导入新地图"', library)
        self.assertIn('title = purpose == .selectForScan ? "选择门店地图"', library)
        self.assertIn("MobileScanSetupViewController(", library)
        self.assertIn("selectedMap: maps[indexPath.row]", library)
        self.assertIn("private let selectedMap: MobileMapLibrary.MapEntry", setup)
        self.assertIn("init(selectedMap: MobileMapLibrary.MapEntry)", setup)
        self.assertIn("loadMap(selectedMap)", setup)
        self.assertNotIn("MobileMapLibrary.listRegisteredMaps()", setup)
        self.assertNotIn("UIPickerViewDataSource", setup)
        self.assertNotIn("private let mapPicker", setup)

    def test_map_library_and_setup_keep_heavy_io_off_main(self) -> None:
        library = self.source(
            "app/ios/RTABMapApp/MobileOnlyWorkflow/UI/"
            "MobileMapLibraryViewController.swift"
        )
        setup = self.source(
            "app/ios/RTABMapApp/MobileOnlyWorkflow/UI/"
            "MobileScanSetupViewController.swift"
        )
        picker = self.source(
            "app/ios/RTABMapApp/MobileMapImport/MapSourceDocumentPicker.swift"
        )
        self.assertIn("libraryQueue.async", library)
        self.assertIn("MobileMapLibrary.listRegisteredMaps()", library)
        self.assertNotIn("override func viewWillAppear", library)
        self.assertIn("loadQueue.async", setup)
        self.assertIn("PriorMapPackage.load", setup)
        self.assertIn("stagingQueue.async", picker)
        self.assertNotIn("CanonicalSourceHasher.sha256", picker)

    def test_import_cold_uikit_and_files_picker_are_prewarmed(self) -> None:
        library = self.source(
            "app/ios/RTABMapApp/MobileOnlyWorkflow/UI/"
            "MobileMapLibraryViewController.swift"
        )
        importer = self.source(
            "app/ios/RTABMapApp/MobileOnlyWorkflow/UI/"
            "MobileMapImportViewController.swift"
        )
        picker = self.source(
            "app/ios/RTABMapApp/MobileMapImport/MapSourceDocumentPicker.swift"
        )
        coordinator = self.source(
            "app/ios/RTABMapApp/MobileOnlyWorkflow/"
            "MobileOnlyWorkflowCoordinator.swift"
        )
        self.assertIn("prepareImportFlowIfIdle", library)
        self.assertIn("preparedImportController", library)
        self.assertIn("preparedImportMenu", library)
        self.assertIn("controller.prepareForPresentation()", library)
        self.assertIn("controller.loadViewIfNeeded()", library)
        self.assertGreaterEqual(
            library.count("self?.prepareImportFlowIfIdle()"),
            3,
        )
        self.assertIn("prepareDocumentPickerIfNeeded", importer)
        self.assertIn("preparedDocumentPicker", importer)
        self.assertIn("preparedDocumentPicker: picker", importer)
        self.assertIn("cachedSupportedTypes", picker)
        self.assertIn("makePreparedViewController", picker)
        self.assertIn("picker.loadViewIfNeeded()", picker)
        self.assertIn("alert.loadViewIfNeeded()", library)
        self.assertIn("preparedDocumentPicker:", coordinator)

        tap_start = importer.index("@objc private func importTapped()")
        tap_end = importer.index(
            "private func prepareDocumentPickerIfNeeded", tap_start
        )
        tap = importer[tap_start:tap_end]
        self.assertNotIn("UIDocumentPickerViewController(", tap)
        present_start = picker.index("func present(from")
        present_end = picker.index("func documentPicker(", present_start)
        self.assertNotIn(
            "UIDocumentPickerViewController(",
            picker[present_start:present_end],
        )

    def test_setup_binds_every_registry_identity_field_to_loaded_package(
        self,
    ) -> None:
        setup = self.source(
            "app/ios/RTABMapApp/MobileOnlyWorkflow/UI/"
            "MobileScanSetupViewController.swift"
        )
        load_start = setup.index("private func loadMap(")
        load_end = setup.index("private static func buildObstacleIndex", load_start)
        load = setup[load_start:load_end]
        for comparison in (
            "package.manifest.priorMapId == map.priorMapID",
            "package.packageSha256 == map.packageSHA256",
            "package.manifest.name == map.name",
            "package.manifest.floors.count == map.floorCount",
            "package.manifest.elementCount == map.elementCount",
            "package.manifest.canonicalSourceSha256",
            "== map.canonicalSourceSHA256",
        ):
            self.assertIn(comparison, load)

    def test_registry_rebuild_and_package_freeze_are_snapshot_fd_bound(
        self,
    ) -> None:
        library = self.source(
            "app/ios/RTABMapApp/MobileOnlyWorkflow/MobileMapLibrary.swift"
        )
        rebuild_start = library.index("static func rebuildRegistry()")
        rebuild_end = library.index("// MARK: - Safety", rebuild_start)
        rebuild = library[rebuild_start:rebuild_end]
        self.assertIn("PriorMapPackageSnapshotReader.read", rebuild)
        self.assertIn('snapshot.artifactsByName[', rebuild)
        self.assertIn("validatePackageSnapshot(", rebuild)
        self.assertNotIn("readManifest(", library)

        freeze_start = library.index("private static func makePackageImmutable(")
        freeze_end = library.index(
            "/// Descriptor-safe recursive freezer", freeze_start
        )
        freeze = library[freeze_start:freeze_end]
        self.assertIn("Set(names) == expectedFileNames", freeze)
        self.assertIn("AT_SYMLINK_NOFOLLOW", freeze)
        self.assertIn("O_NOFOLLOW", freeze)
        self.assertIn("openat(", freeze)
        self.assertIn("fchmod(", freeze)
        self.assertNotIn("chmod(", freeze.replace("fchmod(", ""))

    def test_both_map_sources_enter_one_library_and_setup(self) -> None:
        library_ui = self.source(
            "app/ios/RTABMapApp/MobileOnlyWorkflow/UI/"
            "MobileMapLibraryViewController.swift"
        )
        library = self.source(
            "app/ios/RTABMapApp/MobileOnlyWorkflow/MobileMapLibrary.swift"
        )
        self.assertIn("导入 XLSX / CSV / JSON", library_ui)
        self.assertIn("导入已有 PC 地图包", library_ui)
        self.assertIn("installVerifiedPackage", library_ui)
        self.assertIn("static func installVerifiedPackage", library)
        self.assertIn("let entry = try register(", library)
        self.assertIn("MobileScanSetupViewController(selectedMap:", library_ui)

        picker_start = library_ui.index(
            "private final class ExistingPriorMapPackagePicker"
        )
        picker = library_ui[picker_start:]
        self.assertIn("forOpeningContentTypes: [.folder]", picker)
        self.assertIn("asCopy: false", picker)
        self.assertNotIn("asCopy: true", picker)
        self.assertIn("startAccessingSecurityScopedResource", picker)
        self.assertIn("installVerifiedPackage", picker)
        self.assertIn("viewIfLoaded?.window != nil", picker)

        install_start = library.index("static func installVerifiedPackage(")
        install_end = library.index(
            "private static func verifyImportedStagingPackage", install_start
        )
        install = library[install_start:install_end]
        self.assertIn("try autoreleasepool", install)
        self.assertIn("let identity:", install)
        self.assertLess(
            install.index("try autoreleasepool"),
            install.index("verifyImportedStagingPackage"),
        )

        action_start = library_ui.index('title: "导入已有 PC 地图包"')
        action_end = library_ui.index('title: "取消"', action_start)
        action = library_ui[action_start:action_end]
        self.assertIn("self.preparedImportController = nil", action)
        self.assertIn("DispatchQueue.main.async", action)

    def test_scan_start_reuses_one_prepared_package(self) -> None:
        coordinator = self.source(
            "app/ios/RTABMapApp/MobileOnlyWorkflow/"
            "MobileOnlyWorkflowCoordinator.swift"
        )
        host = self.source("app/ios/RTABMapApp/ViewController.swift")
        start = host.index("func startMobileOnlyScan(")
        body = host[start:]
        self.assertIn("var preparedPackage: PriorMapPackage", coordinator)
        self.assertIn("case startingScan", self.source(
            "app/ios/RTABMapApp/MobileOnlyWorkflow/"
            "MobileOnlyWorkflowState.swift"
        ))
        self.assertIn("workQueue.addOperation(operation)", coordinator)
        execute_start = coordinator.index("private func executeScanStart(")
        rollback = coordinator.index("private func rollbackStartedScan", execute_start)
        execute_body = coordinator[execute_start:rollback]
        self.assertIn("let receipt = try host(configuration)", execute_body)
        self.assertNotIn("DispatchQueue.main.sync", execute_body)
        self.assertIn("configuration.preparedPackage", body)
        self.assertNotIn("MobileMapLibrary.map(", body)
        self.assertNotIn("PriorMapPackageIntegrity.validate(", body)

    def test_first_camera_permission_is_completed_before_workflow_commit(
        self,
    ) -> None:
        setup = self.source(
            "app/ios/RTABMapApp/MobileOnlyWorkflow/UI/"
            "MobileScanSetupViewController.swift"
        )
        entry_start = setup.index("@objc private func startScan()")
        authorized_start = setup.index(
            "private func startAuthorizedScan()", entry_start
        )
        entry = setup[entry_start:authorized_start]
        self.assertIn("AVCaptureDevice.authorizationStatus", entry)
        self.assertIn("case .authorized:", entry)
        self.assertIn("case .notDetermined:", entry)
        self.assertIn("case .denied, .restricted:", entry)
        self.assertNotIn("coordinator.beginScanSetup", entry)
        self.assertNotIn("coordinator.commitScanConfiguration", entry)

        permission_start = setup.index(
            "private func requestCameraPermissionAndResume()", authorized_start
        )
        authorized = setup[authorized_start:permission_start]
        self.assertIn("== .authorized", authorized)
        self.assertIn("coordinator.beginScanSetup", authorized)
        self.assertIn("coordinator.commitScanConfiguration", authorized)
        self.assertIn("guard coordinator.beginScanSetup", authorized)
        self.assertLess(
            authorized.index("guard coordinator.beginScanSetup"),
            authorized.index("coordinator.commitScanConfiguration"),
        )
        coordinator = self.source(
            "app/ios/RTABMapApp/MobileOnlyWorkflow/"
            "MobileOnlyWorkflowCoordinator.swift"
        )
        begin_setup = coordinator.split(
            "func beginScanSetup(map:", 1
        )[1].split("func commitScanConfiguration", 1)[0]
        self.assertIn("mutateContext: { context in", begin_setup)
        self.assertNotIn("persistContext()", begin_setup)

        notice_start = setup.index(
            "private func presentCameraPermissionNotice()", permission_start
        )
        permission = setup[permission_start:notice_start]
        self.assertIn("AVCaptureDevice.requestAccess", permission)
        self.assertIn("DispatchQueue.main.async", permission)
        self.assertIn("self.startScan()", permission)
        self.assertIn("self.formScrollView.isUserInteractionEnabled = true", permission)
        self.assertIn("self.navigationItem.leftBarButtonItem?.isEnabled = true", permission)

        host = self.source("app/ios/RTABMapApp/ViewController.swift")
        host_start = host.index("func startMobileOnlyScan(")
        host_body = host[host_start:]
        authorization_guard = host_body.index(
            "guard authorization == .authorized"
        )
        camera_start = host_body.index("guard self.startCamera()")
        self.assertLess(authorization_guard, camera_start)
        self.assertNotIn("AVCaptureDevice.requestAccess", host_body)

    def test_scan_receipt_commit_is_durable_and_recoverable(self) -> None:
        coordinator = self.source(
            "app/ios/RTABMapApp/MobileOnlyWorkflow/"
            "MobileOnlyWorkflowCoordinator.swift"
        )
        for contract in (
            "O_EXCL",
            "isSafeReceiptIdentifier",
            "persistContextRequired()",
            "context.sessionID = receipt.trackingSessionID",
            "context.segmentDirectory = receipt.segmentDirectory.path",
            "context.sourceDatabase = receipt.databaseURL.path",
            "context.scanReceipt = persistedReceipt.relativePath",
            "context.scanReceiptSHA256 = persistedReceipt.sha256",
            '"scan_receipt": context.scanReceipt',
            '"scan_receipt_sha256": context.scanReceiptSHA256',
            "hasValidPersistedScanCommit()",
        ):
            self.assertIn(contract, coordinator)

    def test_scan_recovery_fully_verifies_map_and_does_not_cache_registry(self) -> None:
        coordinator = self.source(
            "app/ios/RTABMapApp/MobileOnlyWorkflow/"
            "MobileOnlyWorkflowCoordinator.swift"
        )
        start = coordinator.index("private func isRegisteredMap(")
        end = coordinator.index("/// Attempts to resume", start)
        validator = coordinator[start:end]
        self.assertIn("MobileMapLibrary.map(", validator)
        self.assertNotIn("MobileMapLibrary.registeredMap(", validator)
        self.assertNotIn("activeMap =", validator)

        resume_start = coordinator.index("func attemptResume()")
        resume_end = coordinator.index(
            "private static func sessionMetadataIsFinalized", resume_start
        )
        resume = coordinator[resume_start:resume_end]
        self.assertIn("MobileMapLibrary.map(", resume)
        self.assertNotIn("activeMap ??", resume)

    def test_scan_start_cancellation_restores_setup_ui(self) -> None:
        coordinator = self.source(
            "app/ios/RTABMapApp/MobileOnlyWorkflow/"
            "MobileOnlyWorkflowCoordinator.swift"
        )
        setup = self.source(
            "app/ios/RTABMapApp/MobileOnlyWorkflow/UI/"
            "MobileScanSetupViewController.swift"
        )
        self.assertIn("func cancelScanStart()", coordinator)
        self.assertIn("onStartScan != nil, onRollbackScan != nil", coordinator)
        self.assertIn("rollbackStartedScan(receipt)", coordinator)
        self.assertIn("override func viewWillDisappear", setup)
        self.assertIn("coordinator.cancelScanStart()", setup)
        self.assertIn("case .cancelled:", setup)
        self.assertIn("case .interrupted:", setup)

    def test_scan_finalization_closes_or_restores_workflow_transaction(self) -> None:
        coordinator = self.source(
            "app/ios/RTABMapApp/MobileOnlyWorkflow/"
            "MobileOnlyWorkflowCoordinator.swift"
        )
        state = self.source(
            "app/ios/RTABMapApp/MobileOnlyWorkflow/"
            "MobileOnlyWorkflowState.swift"
        )
        host = self.source("app/ios/RTABMapApp/ViewController.swift")
        for method in (
            "func scanFinalizationBegan() -> Bool",
            "func scanFinalizationResumed()",
            "func scanFinalizationCompleted()",
        ):
            self.assertIn(method, coordinator)
        self.assertIn(
            "mutateContext: ((inout PersistedContext) -> Void)? = nil",
            coordinator,
        )
        self.assertIn(
            "return [.scanning, .snapshotting, .idle, .failed, .interrupted]",
            state,
        )
        finalization = host.split("private func finalizeStreamingScan(", 1)[1].split(
            "func stopMapping(", 1
        )[0]
        self.assertIn("scanFinalizationBegan()", finalization)
        self.assertIn("scanFinalizationResumed()", finalization)
        self.assertIn("scanFinalizationCompleted()", finalization)
        self.assertLess(
            finalization.index("scanSession.completeCurrentSession()"),
            finalization.index("scanFinalizationCompleted()"),
        )
        completed = coordinator.split(
            "func scanFinalizationCompleted()", 1
        )[1].split("func scanStartFailed", 1)[0]
        self.assertIn("mutateContext: { context in", completed)
        self.assertLess(
            completed.index('context.scanReceipt = ""'),
            completed.index("lastScanReceipt = nil"),
        )
        resume = coordinator.split("func attemptResume()", 1)[1].split(
            "private static func sessionMetadataIsFinalized", 1
        )[0]
        self.assertIn('liveCheckpoint == "scanning"', resume)
        self.assertIn('liveCheckpoint == "finalizing_scan"', resume)
        self.assertLess(
            resume.index('liveCheckpoint == "scanning"'),
            resume.index("beginProcessing("),
        )

    def test_barcode_start_failure_alert_is_deduplicated(self) -> None:
        host = self.source("app/ios/RTABMapApp/ViewController.swift")
        presenter = host.split(
            "private func presentPriceTagCaptureStartFailure", 1
        )[1].split("private func startPriceTagCapture", 1)[0]
        self.assertIn(
            "guard priceTagCaptureStartFailureAlert == nil else { return }",
            presenter,
        )
        self.assertIn("priceTagCaptureStartFailureAlert = alert", presenter)
        self.assertIn("priceTagCaptureStartFailureAlert = nil", presenter)

    def test_esl_overlay_text_is_anchored_outside_the_exact_scan_box(self) -> None:
        core = self.source(
            "app/ios/RTABMapApp/PriceTagCaptureCore.swift"
        )
        ui = self.source(
            "app/ios/RTABMapApp/PriceTagCaptureUI.swift"
        )
        self.assertIn("static let statusClearancePoints", core)
        self.assertIn("static let payloadClearancePoints", core)
        self.assertIn("private let scanTopGuide = UILayoutGuide()", ui)
        self.assertIn("private let scanBottomGuide = UILayoutGuide()", ui)
        self.assertIn(
            "multiplier: PriceTagCaptureLayout.normalizedScanRect.minY",
            ui,
        )
        self.assertIn(
            "multiplier: PriceTagCaptureLayout.normalizedScanRect.maxY",
            ui,
        )
        self.assertIn(
            "equalTo: scanTopGuide.bottomAnchor",
            ui,
        )
        self.assertIn(
            "equalTo: scanBottomGuide.bottomAnchor",
            ui,
        )
        self.assertNotIn(
            "statusLabel.bottomAnchor.constraint(equalTo: centerYAnchor",
            ui,
        )
        self.assertNotIn(
            "payloadLabel.topAnchor.constraint(equalTo: centerYAnchor",
            ui,
        )

    def test_historical_scan_export_is_visible_and_independent_of_processing(
        self,
    ) -> None:
        processing = self.source(
            "app/ios/RTABMapApp/MobileOnlyWorkflow/UI/"
            "MobileProcessingViewController.swift"
        )
        session = self.source(
            "app/ios/RTABMapApp/SupermarketScanSession.swift"
        )
        self.assertIn("UIDocumentPickerDelegate", processing)
        self.assertIn('UIImage(systemName: "square.and.arrow.up")', processing)
        self.assertIn('exportButton.accessibilityLabel = "导出原始扫描"', processing)
        self.assertIn("SupermarketScanSession.exportFinalizedCapture", processing)
        export_start = session.index("static func exportFinalizedCapture(")
        export_end = session.index(
            "private static func uniqueExternalExportRoot", export_start
        )
        export = session[export_start:export_end]
        self.assertIn('metadata["finalized"] as? Bool == true', export)
        self.assertIn('"live_checkpoint.json"', export)
        self.assertIn("databaseMetadata.st_nlink == 1", export)
        self.assertIn("localManifestBeforeCopy == exportManifest", export)
        self.assertIn("localManifestBeforeCopy == localManifestAfterCopy", export)
        self.assertIn("localCopyRetained: true", export)
        self.assertNotIn("removeLocalCaptureDirectory", export)

    def test_snapshot_database_validation_has_an_ios_compatible_fallback(
        self,
    ) -> None:
        snapshot = self.source(
            "app/ios/RTABMapApp/MobilePostProcessing/"
            "SessionSnapshotTransaction.swift"
        )
        self.assertIn("DatabaseValidationIdentity", snapshot)
        self.assertIn("hasRememberedDatabaseValidation", snapshot)
        self.assertIn("validateSnapshotDatabaseThroughPrivateCopy", snapshot)
        self.assertIn(".marketscanner-db-validation-", snapshot)
        self.assertIn("O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW", snapshot)
        self.assertIn("sameFileIdentity(sourceMetadata, sourceAfterValidation)", snapshot)
        self.assertIn("unlinkat(directoryDescriptor, validationName, 0)", snapshot)
        self.assertIn("file:/dev/fd/", snapshot)
        self.assertIn("forcePrivateDatabaseValidationCopyForTests", snapshot)

    def test_snapshot_committed_file_open_allows_only_ctime_stabilization(
        self,
    ) -> None:
        snapshot = self.source(
            "app/ios/RTABMapApp/MobilePostProcessing/"
            "SessionSnapshotTransaction.swift"
        )
        self.assertIn("sameFileIdentityIgnoringChangeTime", snapshot)
        self.assertIn("changeTimeDidNotMoveBackward", snapshot)
        self.assertIn(
            ".afterCommittedFileAuthorityReadBeforeOpen(basename)",
            snapshot,
        )
        self.assertIn(
            "sameFileIdentity(openedBefore, reboundPath)",
            snapshot,
        )
        self.assertIn(
            ".afterCommittedFileOpenBeforeRead(basename)",
            snapshot,
        )
        self.assertIn(
            "sameFileIdentity(openedBefore, openedAfter)",
            snapshot,
        )
        self.assertIn(
            "sameFileIdentity(openedBefore, pathAfter)",
            snapshot,
        )
        self.assertNotIn(
            "sameCommittedFileObject(pathBefore, openedBefore)",
            snapshot,
        )
        self.assertIn("fileIdentityDifferenceSummary", snapshot)

    def test_navigation_contract_has_root_close_and_push_back_stack(self) -> None:
        setup = self.source(
            "app/ios/RTABMapApp/MobileOnlyWorkflow/UI/"
            "MobileScanSetupViewController.swift"
        )
        importer = self.source(
            "app/ios/RTABMapApp/MobileOnlyWorkflow/UI/"
            "MobileMapImportViewController.swift"
        )
        self.assertIn("installRootCloseButtonIfNeeded", setup)
        self.assertIn("barButtonSystemItem: .close", setup)
        self.assertIn("pushViewController", importer)
        self.assertNotIn("setViewControllers([setup]", importer)

    def test_import_progress_reports_real_compiler_phases(self) -> None:
        compiler = self.source(
            "app/ios/RTABMapApp/MobilePriorMapCompiler/"
            "MobilePriorMapCompiler.swift"
        )
        coordinator = self.source(
            "app/ios/RTABMapApp/MobileOnlyWorkflow/"
            "MobileOnlyWorkflowCoordinator.swift"
        )
        for stage in (
            "正在生成道路图结构",
            "生成结构距离场",
            "正在生成空间索引",
            "生成地图预览",
            "正在执行生产完整性校验",
            "正在同步地图工件到存储",
        ):
            self.assertIn(stage, compiler)
        self.assertIn("bounded * 0.62", coordinator)
        self.assertIn("地图已编译、验证并注册", coordinator)

    def test_import_progress_is_hidden_until_a_file_is_selected(self) -> None:
        importer = self.source(
            "app/ios/RTABMapApp/MobileOnlyWorkflow/UI/"
            "MobileMapImportViewController.swift"
        )
        self.assertIn("percentLabel.isHidden = true", importer)
        self.assertIn("progressView.isHidden = true", importer)
        self.assertIn("elapsedLabel.isHidden = true", importer)
        self.assertIn("case .stagingMapSource:", importer)
        staging = importer.index("case .stagingMapSource:")
        importing = importer.index("case .importingMap:", staging)
        self.assertIn("setProgressUIVisible(true)", importer[staging:importing])
        tap_start = importer.index("@objc private func importTapped()")
        status_start = importer.index("private func updateStatus", tap_start)
        tap = importer[tap_start:status_start]
        self.assertIn("setProgressUIVisible(false)", tap)
        self.assertNotIn("startElapsedTimer()", tap)

    def test_vision_barcode_bounds_are_normalized_with_the_actual_request(
        self,
    ) -> None:
        scanner = self.source(
            "app/ios/RTABMapApp/PriceTagVisionScanner.swift"
        )
        capture = self.source(
            "app/ios/RTABMapApp/PriceTagCaptureCore.swift"
        )
        candidates_start = scanner.index("private static func candidates(")
        candidates_end = scanner.index(
            "static func captureOrientation", candidates_start
        )
        candidates = scanner[candidates_start:candidates_end]
        self.assertIn(
            "PriceTagVisionBoundingBoxNormalizer.fullImageBounds",
            candidates,
        )
        self.assertIn(
            "requestRegionOfInterest: request.regionOfInterest",
            candidates,
        )
        self.assertIn("requestRevision: Int(request.revision)", candidates)
        self.assertIn("visionBounds: fullImageBounds", candidates)
        self.assertNotIn("visionBounds: observation.boundingBox", candidates)
        self.assertIn("if requestRevision == 1", capture)
        self.assertIn(
            "roi.origin.x + observation.origin.x * roi.width",
            capture,
        )
        self.assertIn(
            "roi.origin.y + observation.origin.y * roi.height",
            capture,
        )
        self.assertIn("private static let boundaryEpsilon", capture)
        self.assertNotIn(".standardized", capture)
        self.assertIn("minimumROIIntersectionRatio: 0.80", capture)

    def test_historical_processing_rejection_has_typed_admission_and_ui_rollback(
        self,
    ) -> None:
        coordinator = self.source(
            "app/ios/RTABMapApp/MobileOnlyWorkflow/"
            "MobileOnlyWorkflowCoordinator.swift"
        )
        state = self.source(
            "app/ios/RTABMapApp/MobileOnlyWorkflow/"
            "MobileOnlyWorkflowState.swift"
        )
        processing_ui = self.source(
            "app/ios/RTABMapApp/MobileOnlyWorkflow/UI/"
            "MobileProcessingViewController.swift"
        )

        begin_start = coordinator.index("func beginProcessing(")
        begin_end = coordinator.index(
            "private func executeProcessing", begin_start
        )
        begin = coordinator[begin_start:begin_end]
        self.assertIn(
            ") -> Result<String, MobileOnlyWorkflowError>", begin
        )
        self.assertIn("MobileHistoricalProcessingAdmission.evaluate", begin)
        self.assertGreaterEqual(
            begin.count("releaseProcessingAdmission(admissionID)"), 3
        )
        self.assertIn("return .failure(error)", begin)
        self.assertIn("return .failure(workflowError)", begin)
        self.assertIn("return .success(taskID)", begin)
        self.assertEqual(begin.count("workQueue.addOperation(operation)"), 1)
        self.assertNotIn("notifyProcessing", begin)

        release_start = coordinator.index(
            "private func releaseProcessingAdmission"
        )
        release_end = coordinator.index(
            "private func transitionToPipelineFraction", release_start
        )
        release = coordinator[release_start:release_end]
        self.assertIn("processingAdmissionOwner == admissionID", release)
        self.assertIn("processingAdmissionOwner = nil", release)
        self.assertIn("processingBusy = false", release)

        self.assertIn("enum MobileHistoricalProcessingAdmission", state)
        self.assertIn("processingBusy: Bool", state)
        self.assertIn("currentState != .finalizingScan", state)
        map_ready_start = state.index("case .mapReady:")
        map_ready_end = state.index("case .configuringScan:", map_ready_start)
        self.assertNotIn(".snapshotting", state[map_ready_start:map_ready_end])

        select_start = processing_ui.index(
            "func tableView(_ tableView: UITableView, didSelectRowAt"
        )
        select_end = processing_ui.index(
            "@objc private func exportButtonTapped", select_start
        )
        selection = processing_ui[select_start:select_end]
        self.assertIn(
            "let admission = coordinator.beginProcessing", selection
        )
        self.assertIn("switch admission", selection)
        self.assertIn("case .failure(let error):", selection)
        failure = selection.split("case .failure(let error):", 1)[1]
        self.assertIn("processing = false", failure)
        self.assertIn("updateBusyPresentation()", failure)
        self.assertIn("progressView.setProgress(0", failure)
        self.assertIn("无法开始处理", failure)

        busy_start = processing_ui.index("private func updateBusyPresentation()")
        busy_end = processing_ui.index("private func presentNotice", busy_start)
        busy = processing_ui[busy_start:busy_end]
        self.assertIn("leftBarButtonItem?.isEnabled = !isBusy", busy)
        self.assertIn("isModalInPresentation = isBusy", busy)
        self.assertIn("tableView.isUserInteractionEnabled = !isBusy", busy)

        execute_start = coordinator.index("private func executeProcessing")
        execute_end = coordinator.index(
            "private func releaseProcessingAdmission", execute_start
        )
        execute = coordinator[execute_start:execute_end]
        self.assertIn("notifyProcessing(.failure(.cancelled))", execute)
        self.assertIn(
            "error as? SessionSnapshotTransaction.SessionError",
            execute,
        )
        self.assertIn(
            "MobileOnlyWorkflowError.snapshotFailed(",
            execute,
        )
        self.assertIn(
            "self.statusLabel.text = error.localizedDescription",
            processing_ui,
        )
        self.assertNotIn(
            'self.statusLabel.text = "处理失败：\\(error.localizedDescription)"',
            processing_ui,
        )

    def test_normal_lifecycle_callbacks_do_not_force_crash(self) -> None:
        host = self.source("app/ios/RTABMapApp/ViewController.swift")
        scroller = self.source(
            "app/ios/RTABMapApp/VerticalScrollerView.swift"
        )
        database_view = self.source("app/ios/RTABMapApp/DatabaseView.swift")
        coordinator = self.source(
            "app/ios/RTABMapApp/MobileOnlyWorkflow/"
            "MobileOnlyWorkflowCoordinator.swift"
        )
        capture_core = self.source(
            "app/ios/RTABMapApp/PriceTagCaptureCore.swift"
        )
        processing_pipeline = self.source(
            "app/ios/RTABMapApp/MobileOnlyWorkflow/"
            "MobileProcessingPipeline.swift"
        )
        recovery_parser = self.source(
            "app/ios/RTABMapApp/RecoveryLifecycleEvidenceParser.swift"
        )
        session = self.source(
            "app/ios/RTABMapApp/SupermarketScanSession.swift"
        )
        burst_parser = self.source(
            "app/ios/RTABMapApp/MobilePostProcessing/"
            "TagObservationBurstEvidenceParser.swift"
        )
        prior_map = self.source(
            "app/ios/RTABMapApp/PriorMapLocalization.swift"
        )
        capture_ui = self.source(
            "app/ios/RTABMapApp/PriceTagCaptureUI.swift"
        )
        library_ui = self.source(
            "app/ios/RTABMapApp/MobileOnlyWorkflow/UI/"
            "MobileMapLibraryViewController.swift"
        )
        setup_ui = self.source(
            "app/ios/RTABMapApp/MobileOnlyWorkflow/UI/"
            "MobileScanSetupViewController.swift"
        )
        native_bridge = self.source("app/ios/RTABMapApp/RTABMap.swift")
        import_coordinator = self.source(
            "app/ios/RTABMapApp/MobileMapImport/"
            "MapSourceImportCoordinator.swift"
        )

        location_start = host.index(
            "func locationManager(_ manager: CLLocationManager, "
            "didUpdateLocations locations: [CLLocation])"
        )
        location_end = host.index(
            "func locationManager(_ manager: CLLocationManager, "
            "didFailWithError error: Error)",
            location_start,
        )
        location = host[location_start:location_end]
        self.assertIn("guard let location = locations.last", location)
        self.assertIn("gps_empty_update_ignored", location)
        self.assertNotIn("locations.last!", location)

        orientation_start = host.index(
            "var statusBarOrientation: UIInterfaceOrientation?"
        )
        orientation_end = host.index("deinit {", orientation_start)
        orientation = host[orientation_start:orientation_end]
        self.assertIn("viewIfLoaded?.window?.windowScene", orientation)
        self.assertIn("UIApplication.shared.connectedScenes", orientation)
        self.assertNotIn("fatalError", orientation)
        self.assertNotIn("UIApplication.shared.windows.first", orientation)

        selection_start = host.index(
            "func verticalScrollerView(_ horizontalScrollerView: "
            "VerticalScrollerView, didSelectViewAt index: Int)"
        )
        selection_end = host.index(
            "extension ViewController: VerticalViewDataSource",
            selection_start,
        )
        selection = host[selection_start:selection_end]
        self.assertIn("databases.indices.contains(index)", selection)
        self.assertIn("as? DatabaseView", selection)
        self.assertNotIn("as! DatabaseView", selection)

        self.assertIn("contentViews.indices.contains(index)", scroller)
        self.assertIn("func view(at index: Int) -> UIView?", scroller)

        self.assertNotIn("try!", database_view)
        self.assertNotIn("contentModificationDate!", database_view)
        self.assertIn("try FileManager.default.url", coordinator)
        self.assertNotIn("try! FileManager.default.url", coordinator)
        self.assertNotIn("assertionFailure(message)", capture_core)
        self.assertNotIn(
            'preconditionFailure("committed result handled before snapshot switch")',
            processing_pipeline,
        )
        self.assertNotIn('($0["id"] as! String, $0)', processing_pipeline)

        self.assertNotIn("as! String", recovery_parser)
        self.assertNotIn("precondition(!frameSamples.isEmpty)", session)
        self.assertIn("guard !frameSamples.isEmpty else { return nil }", session)
        self.assertNotIn("precondition(!frames.isEmpty)", burst_parser)
        self.assertIn("static func recomputeSummary", burst_parser)
        self.assertIn(")? {", burst_parser)

        self.assertNotIn("precondition(commitManualPosition", prior_map)
        self.assertIn("guard commitManualPosition(candidate) else", prior_map)
        self.assertIn("guard let floor = package.manifest.floors.first", prior_map)
        for shipping_ui in (prior_map, capture_ui, library_ui, setup_ui):
            self.assertNotIn("fatalError(\"init(coder:)", shipping_ui)
        self.assertNotIn(
            "fatalError(\"MobileMapLibraryViewController is programmatic\")",
            library_ui,
        )
        self.assertNotIn(
            "fatalError(\"MobileScanSetupViewController is programmatic\")",
            setup_ui,
        )

        rollback_start = host.index(
            "private func rollbackMobileOnlyScanStart("
        )
        rollback_end = host.index(
            "private func persistScanConfiguration", rollback_start
        )
        rollback = host[rollback_start:rollback_end]
        self.assertNotIn("precondition(Thread.isMainThread)", rollback)
        self.assertIn("DispatchQueue.main.async", rollback)

        defaults_start = host.index("func updateDisplayFromDefaults()")
        defaults_end = host.index("func resumeScan()", defaults_start)
        defaults_flow = host[defaults_start:defaults_end]
        self.assertIn("guard let nativeHost = rtabmap", defaults_flow)
        self.assertIn("func stringSetting(", defaults_flow)
        self.assertNotIn("defaults.string(forKey:", defaults_flow.replace(
            "defaults.string(forKey: key)", ""
        ))
        self.assertNotIn("rtabmap!", defaults_flow)
        self.assertIn('fallback: "400"', defaults_flow)
        self.assertIn('fallback: "25"', defaults_flow)
        self.assertIn('fallback: "2"', defaults_flow)
        self.assertIn('fallback: "6"', defaults_flow)

        state_start = host.index("func updateState(state: State)")
        state_end = host.index("func exportMesh(isOBJ: Bool)", state_start)
        state_flow = host[state_start:state_end]
        self.assertNotIn(
            'string(forKey: "ExportPointCloudFormat")!', state_flow
        )
        self.assertIn('?? "ply"', state_flow)

        stats_start = host.index("func statsUpdated(")
        stats_end = host.index("func cameraInfoEventReceived", stats_start)
        stats_flow = host[stats_start:stats_end]
        self.assertNotIn("statusLabel.text!", stats_flow)
        self.assertNotIn("mLastKnownLocation!", stats_flow)
        self.assertNotIn("mLastLightEstimate!", stats_flow)

        scan_start = host.index("func newScan(")
        scan_start_end = host.index(
            "private func applyStreamingMappingSettings", scan_start
        )
        scan_start_flow = host[scan_start:scan_start_end]
        self.assertIn("guard let nativeHost = rtabmap", scan_start_flow)
        self.assertNotIn("self.rtabmap!", scan_start_flow)

        callbacks_start = native_bridge.index("func setupCallbacksWithCPP()")
        callbacks_end = native_bridge.index("deinit {", callbacks_start)
        callbacks = native_bridge[callbacks_start:callbacks_end]
        for forced_pointer in ("observer!", "msg!", "key!", "value!"):
            self.assertNotIn(forced_pointer, callbacks)
        self.assertIn("guard let observer, let msg else", callbacks)
        self.assertIn("guard let observer, let key, let value else", callbacks)
        odometry_start = native_bridge.index("func postOdometryEvent(")
        odometry_end = native_bridge.index(
            "// Parameters", odometry_start
        )
        odometry = native_bridge[odometry_start:odometry_end]
        self.assertIn(
            "CVPixelBufferGetPlaneCount(frame.capturedImage) >= 2",
            odometry,
        )
        self.assertIn("let capturedYPlane", odometry)
        self.assertIn("let capturedUVPlane", odometry)

        self.assertNotIn(
            "rawBuffer.bindMemory(to: UInt8.self).baseAddress!",
            import_coordinator,
        )

        finalization_start = host.index("private func finalizeStreamingScan(")
        finalization_end = host.index(
            "private func copyCaptureInBackground", finalization_start
        )
        finalization = host[finalization_start:finalization_end]
        self.assertNotIn("self.rtabmap!", finalization)
        self.assertIn("native_host_unavailable_after_finalization", finalization)
        self.assertLess(
            finalization.index("session.pause()"),
            finalization.index("let priorMapDrain"),
        )
        self.assertLess(
            finalization.index("rtabmap?.stopCamera()"),
            finalization.index("waitForFinalizationTransactionDrain"),
        )
        self.assertGreaterEqual(
            finalization.count(
                "setPausedMapping(\n                    paused: false,\n"
                "                    triggerNewMap: false)"
            ),
            1,
        )

        shipping_root = ROOT / "app/ios/RTABMapApp"
        forbidden_process_terminators = (
            "fatalError(",
            "preconditionFailure(",
            "precondition(",
            "as!",
        )
        for swift_file in shipping_root.rglob("*.swift"):
            if "Libraries" in swift_file.relative_to(shipping_root).parts:
                continue
            shipping_source = swift_file.read_text(encoding="utf-8")
            for forbidden in forbidden_process_terminators:
                self.assertNotIn(
                    forbidden,
                    shipping_source,
                    f"{swift_file.relative_to(ROOT)} contains {forbidden}",
                )


if __name__ == "__main__":
    unittest.main()
