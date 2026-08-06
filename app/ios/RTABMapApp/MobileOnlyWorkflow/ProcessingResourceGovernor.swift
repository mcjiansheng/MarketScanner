import Foundation
#if canImport(UIKit)
import UIKit
#endif
import Darwin

/// Processing resource governor (V1R2 Gate L §16 / Gate H §12 /
/// V1R4 Gate O §18).
///
/// Every heavy stage asks the governor for a budget BEFORE it starts.
/// The governor builds a byte-level task estimate (§18), measures memory
/// footprint, free disk, thermal state and battery, and fails closed
/// with `.resourceRequired` when a hard budget is exceeded. A run is
/// never silently degraded and published.
enum ProcessingResourceGovernor {

    /// Hard budgets (fail closed).
    static let minimumFreeDiskBytes: Int64 = 512 * 1024 * 1024
    static let minimumAvailableMemoryBytes: Int64 = 256 * 1024 * 1024
    /// Deep path additionally requires a healthy battery (§12).
    static let deepMinimumBatteryPercent: Float = 15

    // MARK: - Task estimate (V1R4 §18 Gate O)

    /// Byte-level estimate of the full task peak footprint. Each stage
    /// refines the components it now knows; the check runs against the
    /// CURRENT total, so the budget is dynamic instead of static.
    struct TaskEstimate {
        /// Input snapshot artifact bytes (DB + sidecars + manifest).
        var snapshotBytes: Int64 = 0
        /// Raw snapshot-DB graph inventory (nodes/links).
        var rawGraphBytes: Int64 = 0
        /// Optimized skeleton + factor graph held by the native core.
        var skeletonFactorBytes: Int64 = 0
        /// Native outcome trajectory + its Swift copy.
        var nativeOutcomeBytes: Int64 = 0
        /// Tag observations + burst sidecar evidence.
        var tagEvidenceBytes: Int64 = 0
        /// Final 1 Hz trajectory rows.
        var trajectoryBytes: Int64 = 0
        /// XLSX streaming temp footprint.
        var xlsxTempBytes: Int64 = 0
        /// Result staging package bytes.
        var resultStagingBytes: Int64 = 0
        /// Unallocated safety reserve (§18), never zeroed.
        var safetyReserveBytes: Int64 = 64 * 1024 * 1024

        var totalBytes: Int64 {
            return snapshotBytes + rawGraphBytes + skeletonFactorBytes
                + nativeOutcomeBytes + tagEvidenceBytes + trajectoryBytes
                + xlsxTempBytes + resultStagingBytes + safetyReserveBytes
        }
    }

    /// Device class derived from physical memory (§18 device class).
    /// Low/mid devices get a tighter RSS headroom ceiling.
    enum DeviceClass: String {
        case low
        case mid
        case high
    }

    /// Physical-memory based device class: <4 GB low, <6 GB mid, else
    /// high (macOS hosts are always high).
    static func deviceClass() -> DeviceClass {
        let physical = physicalMemoryBytes()
        if physical > 0 && physical < 4 * 1024 * 1024 * 1024 { return .low }
        if physical > 0 && physical < 6 * 1024 * 1024 * 1024 { return .mid }
        return .high
    }

    /// RSS headroom ceiling as a ratio of physical memory per class.
    static func headroomRatio(for deviceClass: DeviceClass) -> Double {
        switch deviceClass {
        case .low: return 0.55
        case .mid: return 0.65
        case .high: return 0.75
        }
    }

    // MARK: - Test overrides (host suite only, off in production)

    /// Host-test injection points; all stay nil/-1/0 in the app so the
    /// real measurements are always used.
    static var thermalStateOverride: ProcessInfo.ThermalState?
    static var freeDiskOverrideBytes: Int64 = -1
    static var availableMemoryOverrideBytes: Int64 = -1
    static var physicalMemoryOverrideBytes: Int64 = 0

    static func resetOverrides() {
        thermalStateOverride = nil
        freeDiskOverrideBytes = -1
        availableMemoryOverrideBytes = -1
        physicalMemoryOverrideBytes = 0
    }

    private static func physicalMemoryBytes() -> Int64 {
        if physicalMemoryOverrideBytes > 0 { return physicalMemoryOverrideBytes }
        return Int64(ProcessInfo.processInfo.physicalMemory)
    }

    private static func currentThermalState() -> ProcessInfo.ThermalState {
        if let override = thermalStateOverride { return override }
        return ProcessInfo.processInfo.thermalState
    }

    private static func currentFreeDiskBytesForBudget() -> Int64 {
        if freeDiskOverrideBytes >= 0 { return freeDiskOverrideBytes }
        return currentFreeDiskBytes()
    }

    private static func availableMemoryBytesForBudget() -> Int64 {
        if availableMemoryOverrideBytes >= 0 { return availableMemoryOverrideBytes }
        return availableMemoryBytes()
    }

    /// Soft-budget diagnostics recorded per run (wall/CPU/memory/disk).
    struct Snapshot {
        var memoryFootprintMB: Int64
        var freeDiskBytes: Int64
        var thermalState: String
        var batteryPercent: Float
        var batteryCharging: Bool
        var takenAtUTC: Double
    }

    static func currentSnapshot() -> Snapshot {
        return Snapshot(
            memoryFootprintMB: currentMemoryFootprintMB(),
            freeDiskBytes: currentFreeDiskBytes(),
            thermalState: thermalStateName(),
            batteryPercent: batteryPercent(),
            batteryCharging: isBatteryCharging(),
            takenAtUTC: Date().timeIntervalSince1970)
    }

    /// Fails closed when the stage cannot run within the hard budgets.
    /// The task estimate (§18) is required: every stage checks its
    /// current total against physical-memory headroom, available memory
    /// and free disk, plus thermal/battery/device-class gates.
    static func checkBudget(
        stage: String,
        estimate: TaskEstimate = TaskEstimate()
    ) throws {
        // §12.4: every budget check also samples the run-scoped real
        // diagnostics (peak RSS / thermal interruptions) before any
        // hard-budget outcome.
        sampleRunDiagnostics()
        // Thermal: serious/critical never starts heavy work (§12/§16).
        let thermal = currentThermalState()
        if thermal == .serious || thermal == .critical {
            throw MobileOnlyWorkflowError.resourceRequired(
                "\(stage): thermal state \(thermalStateName())")
        }
        // §18 RSS headroom: current footprint + full-task estimate must
        // fit under the device-class ceiling of physical memory.
        let physical = physicalMemoryBytes()
        if physical > 0 {
            let ceiling = Int64(
                Double(physical) * headroomRatio(for: deviceClass()))
            let footprint = currentMemoryFootprintMB() * 1024 * 1024
            if footprint + estimate.totalBytes > ceiling {
                throw MobileOnlyWorkflowError.resourceRequired(
                    "\(stage): task estimate \(estimate.totalBytes) B + RSS "
                    + "\(footprint) B exceed \(deviceClass().rawValue)-class "
                    + "headroom \(ceiling) B (physical \(physical) B)")
            }
        }
        // Available memory must cover the estimate plus the baseline.
        let availableMemory = availableMemoryBytesForBudget()
        if availableMemory >= 0
            && availableMemory < estimate.totalBytes + minimumAvailableMemoryBytes {
            throw MobileOnlyWorkflowError.resourceRequired(
                "\(stage): available memory \(availableMemory) B below "
                + "estimate \(estimate.totalBytes) B + baseline")
        }
        // Free disk must cover the estimate plus the baseline.
        let freeDisk = currentFreeDiskBytesForBudget()
        if freeDisk >= 0
            && freeDisk < estimate.totalBytes + minimumFreeDiskBytes {
            throw MobileOnlyWorkflowError.resourceRequired(
                "\(stage): free disk \(freeDisk) B below estimate "
                + "\(estimate.totalBytes) B + baseline")
        }
        if stage == "deep" {
            let percent = batteryPercent()
            if percent >= 0, percent < deepMinimumBatteryPercent, !isBatteryCharging() {
                throw MobileOnlyWorkflowError.resourceRequired(
                    "deep: battery \(Int(percent))% below \(Int(deepMinimumBatteryPercent))% and not charging")
            }
        }
    }

    // MARK: - Run-scoped real diagnostics (V1R4 §12.4)

    /// Run-scoped counters, reset per processing run and sampled at every
    /// budget checkpoint so the RunSummary reports REAL peak RSS and REAL
    /// thermal interruptions instead of placeholders.
    private static let diagnosticsLock = NSLock()
    private static var runPeakMemoryMB: Int64 = 0
    private static var runSeriousOrCriticalThermalSamples = 0

    /// Resets the run-scoped diagnostics; call once at run start.
    static func beginRun() {
        diagnosticsLock.lock()
        defer { diagnosticsLock.unlock() }
        runPeakMemoryMB = 0
        runSeriousOrCriticalThermalSamples = 0
    }

    /// Samples the current footprint/thermal state into the run counters.
    static func sampleRunDiagnostics() {
        let footprint = currentMemoryFootprintMB()
        let thermal = currentThermalState()
        diagnosticsLock.lock()
        if footprint > runPeakMemoryMB { runPeakMemoryMB = footprint }
        if thermal == .serious || thermal == .critical {
            runSeriousOrCriticalThermalSamples += 1
        }
        diagnosticsLock.unlock()
    }

    /// Highest sampled physical footprint in MB (0 when nothing sampled).
    static func runPeakMemoryFootprintMB() -> Int64 {
        diagnosticsLock.lock()
        defer { diagnosticsLock.unlock() }
        return runPeakMemoryMB
    }

    /// Number of samples where the thermal state was serious/critical.
    static func runSeriousOrCriticalThermalSampleCount() -> Int {
        diagnosticsLock.lock()
        defer { diagnosticsLock.unlock() }
        return runSeriousOrCriticalThermalSamples
    }

    // MARK: - Measurements

    /// Current process physical footprint in MB (0 when unavailable).
    static func currentMemoryFootprintMB() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int64(info.phys_footprint) / (1024 * 1024)
    }

    /// Memory the OS says is still available to this process (iOS 13+).
    static func availableMemoryBytes() -> Int64 {
        #if canImport(UIKit) && !targetEnvironment(macCatalyst)
        if #available(iOS 13.0, *) {
            return Int64(os_proc_available_memory())
        }
        #endif
        return -1
    }

    static func currentFreeDiskBytes() -> Int64 {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        if let values = try? documents.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let capacity = values.volumeAvailableCapacityForImportantUsage {
            return capacity
        }
        let attributes = try? FileManager.default.attributesOfFileSystem(
            forPath: documents.path)
        if let free = (attributes?[.systemFreeSize] as? NSNumber)?.int64Value {
            return free
        }
        return -1
    }

    static func thermalStateName() -> String {
        switch currentThermalState() {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    static func batteryPercent() -> Float {
        #if canImport(UIKit) && !os(watchOS)
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let level = device.batteryLevel
        return level < 0 ? -1 : level * 100
        #else
        return -1
        #endif
    }

    static func isBatteryCharging() -> Bool {
        #if canImport(UIKit) && !os(watchOS)
        let state = UIDevice.current.batteryState
        return state == .charging || state == .full
        #else
        return true
        #endif
    }
}
