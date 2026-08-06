import Foundation
#if canImport(UIKit)
import UIKit
#endif
import Darwin

/// Processing resource governor (V1R2 Gate L §16 / Gate H §12).
///
/// Every heavy stage asks the governor for a budget BEFORE it starts.
/// The governor measures memory footprint, free disk, thermal state and
/// battery, and fails closed with `.resourceRequired` when a hard budget
/// is exceeded. A run is never silently degraded and published.
enum ProcessingResourceGovernor {

    /// Hard budgets (fail closed).
    static let minimumFreeDiskBytes: Int64 = 512 * 1024 * 1024
    static let minimumAvailableMemoryBytes: Int64 = 256 * 1024 * 1024
    /// Deep path additionally requires a healthy battery (§12).
    static let deepMinimumBatteryPercent: Float = 15

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
    static func checkBudget(stage: String) throws {
        // Thermal: serious/critical never starts heavy work (§12/§16).
        let thermal = ProcessInfo.processInfo.thermalState
        if thermal == .serious || thermal == .critical {
            throw MobileOnlyWorkflowError.resourceRequired(
                "\(stage): thermal state \(thermalStateName())")
        }
        let freeDisk = currentFreeDiskBytes()
        if freeDisk >= 0 && freeDisk < minimumFreeDiskBytes {
            throw MobileOnlyWorkflowError.resourceRequired(
                "\(stage): free disk \(freeDisk) bytes below budget")
        }
        let availableMemory = availableMemoryBytes()
        if availableMemory > 0 && availableMemory < minimumAvailableMemoryBytes {
            throw MobileOnlyWorkflowError.resourceRequired(
                "\(stage): available memory below budget")
        }
        if stage == "deep" {
            let percent = batteryPercent()
            if percent >= 0, percent < deepMinimumBatteryPercent, !isBatteryCharging() {
                throw MobileOnlyWorkflowError.resourceRequired(
                    "deep: battery \(Int(percent))% below \(Int(deepMinimumBatteryPercent))% and not charging")
            }
        }
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
        switch ProcessInfo.processInfo.thermalState {
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
