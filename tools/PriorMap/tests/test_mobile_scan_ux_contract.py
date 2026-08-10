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


if __name__ == "__main__":
    unittest.main()
