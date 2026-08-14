//
//  AppDelegate.swift
//  GLKittutorial
//
//  Created by Mathieu Labbe on 2020-12-28.
//

import UIKit
import ARKit
import MetricKit

/// Persists Apple's post-crash/hang diagnostics without making scan start or
/// finalization depend on MetricKit delivery. An active scan context remains
/// in UserDefaults across an abnormal process exit; when iOS later delivers a
/// diagnostic payload it is written both to the app-wide diagnostics folder
/// and, for a local session, into segment_0001 so ordinary raw-session export
/// carries the evidence to the PC.
final class MarketScannerCrashDiagnostics: NSObject, MXMetricManagerSubscriber {
    static let shared = MarketScannerCrashDiagnostics()

    static let diagnosticsFileName = "metrickit_diagnostics.jsonl"
    private let activeTrackingSessionKey =
        "MarketScannerDiagnosticsActiveTrackingSessionID"
    private let activeSessionRootKey =
        "MarketScannerDiagnosticsActiveSessionRoot"
    private let pendingTrackingSessionKey =
        "MarketScannerDiagnosticsPendingTrackingSessionID"
    private let pendingSessionRootKey =
        "MarketScannerDiagnosticsPendingSessionRoot"
    private let queue = DispatchQueue(
        label: "com.introlab.rtabmap.metrickit-diagnostics",
        qos: .utility)
    private let maximumFileBytes: UInt64 = 8 * 1024 * 1024
    private var subscribed = false

    private override init() {
        super.init()
    }

    func start() {
        guard !subscribed else { return }
        subscribed = true
        // An active context that survived into a new process launch belongs
        // to the prior abnormal run. Preserve it separately before a new scan
        // can overwrite the active slot; MetricKit delivery is commonly
        // delayed until this or a later launch.
        queue.sync {
            let defaults = UserDefaults.standard
            if let previousTrackingSessionID = defaults.string(
                    forKey: self.activeTrackingSessionKey) {
                defaults.set(
                    previousTrackingSessionID,
                    forKey: self.pendingTrackingSessionKey)
                defaults.set(
                    defaults.string(forKey: self.activeSessionRootKey),
                    forKey: self.pendingSessionRootKey)
                defaults.removeObject(forKey: self.activeTrackingSessionKey)
                defaults.removeObject(forKey: self.activeSessionRootKey)
                defaults.synchronize()
            }
        }
        MXMetricManager.shared.add(self)
    }

    func markScanActive(trackingSessionID: String, rootDirectory: URL?) {
        guard !trackingSessionID.isEmpty else { return }
        let rootPath = rootDirectory?.standardizedFileURL.path
        queue.sync {
            let defaults = UserDefaults.standard
            defaults.set(trackingSessionID, forKey: self.activeTrackingSessionKey)
            defaults.set(rootPath, forKey: self.activeSessionRootKey)
            defaults.synchronize()
        }
    }

    func markScanCompleted(trackingSessionID: String) {
        guard !trackingSessionID.isEmpty else { return }
        queue.sync {
            let defaults = UserDefaults.standard
            guard defaults.string(forKey: self.activeTrackingSessionKey)
                    == trackingSessionID else {
                return
            }
            defaults.removeObject(forKey: self.activeTrackingSessionKey)
            defaults.removeObject(forKey: self.activeSessionRootKey)
            defaults.synchronize()
        }
    }

    @available(iOS 14.0, *)
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        guard !payloads.isEmpty else { return }
        queue.async {
            let defaults = UserDefaults.standard
            let pendingTrackingSessionID = defaults.string(
                forKey: self.pendingTrackingSessionKey)
            // MetricKit payloads describe an earlier reporting period. Bind
            // them only to a context that demonstrably survived a process
            // restart; the current live scan is not evidence that an older
            // diagnostic belongs to it.
            let trackingSessionID = pendingTrackingSessionID
            let rootPath = pendingTrackingSessionID.flatMap { _ in
                defaults.string(forKey: self.pendingSessionRootKey)
            }
            var allPersisted = true
            for payload in payloads {
                allPersisted = self.persist(
                    payload,
                    trackingSessionID: trackingSessionID,
                    rootPath: rootPath) && allPersisted
            }
            if allPersisted,
               let pendingTrackingSessionID,
               defaults.string(forKey: self.pendingTrackingSessionKey)
                    == pendingTrackingSessionID {
                defaults.removeObject(forKey: self.pendingTrackingSessionKey)
                defaults.removeObject(forKey: self.pendingSessionRootKey)
                defaults.synchronize()
            }
        }
    }

    @available(iOS 14.0, *)
    private func persist(
        _ payload: MXDiagnosticPayload,
        trackingSessionID: String?,
        rootPath: String?
    ) -> Bool {
        var envelope: [String: Any] = [
            "format": "MarketScannerMetricKitDiagnostic",
            "version": 1,
            "delivery_id": UUID().uuidString.lowercased(),
            "received_at_unix": Date().timeIntervalSince1970,
            "payload_begin_unix": payload.timeStampBegin.timeIntervalSince1970,
            "payload_end_unix": payload.timeStampEnd.timeIntervalSince1970,
            "tracking_session_id": trackingSessionID ?? NSNull(),
            "app_version": Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ?? "unknown",
            "app_build": Bundle.main.object(
                forInfoDictionaryKey: "CFBundleVersion") as? String
                ?? "unknown",
            "crash_count": payload.crashDiagnostics?.count ?? 0,
            "hang_count": payload.hangDiagnostics?.count ?? 0,
            "cpu_exception_count": payload.cpuExceptionDiagnostics?.count ?? 0,
            "disk_write_exception_count":
                payload.diskWriteExceptionDiagnostics?.count ?? 0,
            "diagnostic_payload": payload.dictionaryRepresentation(),
        ]
        if trackingSessionID == nil {
            envelope["context_status"] = "no_active_scan_context"
        }
        guard JSONSerialization.isValidJSONObject(envelope),
              var data = try? JSONSerialization.data(
                withJSONObject: envelope,
                options: [.sortedKeys]) else {
            return false
        }
        if data.count + 1 > Int(maximumFileBytes) {
            let originalRecordBytes = data.count + 1
            envelope["diagnostic_payload"] = NSNull()
            envelope["raw_payload_preserved"] = false
            envelope["raw_payload_size_bytes"] = originalRecordBytes
            envelope["raw_payload_omitted_reason"] =
                "record_exceeded_file_limit"
            guard let bounded = try? JSONSerialization.data(
                    withJSONObject: envelope,
                    options: [.sortedKeys]),
                  bounded.count + 1 <= Int(maximumFileBytes) else {
                return false
            }
            data = bounded
        }
        data.append(0x0A)

        let fileManager = FileManager.default
        guard let documents = fileManager.urls(
                for: .documentDirectory,
                in: .userDomainMask).first else {
            return false
        }
        let globalDirectory = documents.appendingPathComponent(
            "MarketScannerDiagnostics",
            isDirectory: true)
        var globalPersisted = false
        if (try? fileManager.createDirectory(
                at: globalDirectory,
                withIntermediateDirectories: true)) != nil {
            globalPersisted = appendBounded(
                data,
                to: globalDirectory.appendingPathComponent(
                    Self.diagnosticsFileName))
        }

        guard let rootPath else { return globalPersisted }
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL
        let documentsPath = documents.standardizedFileURL.path + "/"
        guard root.path.hasPrefix(documentsPath),
              root.lastPathComponent.hasPrefix("SupermarketSession-") else {
            return globalPersisted
        }
        let segment = root.appendingPathComponent(
            "segment_0001",
            isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
                atPath: segment.path,
                isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return globalPersisted
        }
        _ = appendBounded(
            data,
            to: segment.appendingPathComponent(Self.diagnosticsFileName))
        return globalPersisted
    }

    @discardableResult
    private func appendBounded(_ data: Data, to url: URL) -> Bool {
        let fileManager = FileManager.default
        let existingSize = (try? url.resourceValues(
            forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0
        if existingSize + UInt64(data.count) > maximumFileBytes {
            let rollover = url.deletingLastPathComponent()
                .appendingPathComponent("metrickit_diagnostics.previous.jsonl")
            try? fileManager.removeItem(at: rollover)
            try? fileManager.moveItem(at: url, to: rollover)
        }
        if !fileManager.fileExists(atPath: url.path) {
            _ = fileManager.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            return false
        }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            handle.synchronizeFile()
            return true
        }
        catch {
            NSLog("MarketScanner MetricKit diagnostic write failed: %@",
                  error.localizedDescription)
            return false
        }
    }
}

func setDefaultsFromSettingsBundle() {
    
    let plistFiles = ["Root", "Mapping", "Assembling"]
    
    for plistName in plistFiles {
        //Read PreferenceSpecifiers from Root.plist in Settings.Bundle
        if let settingsURL = Bundle.main.url(forResource: plistName, withExtension: "plist", subdirectory: "Settings.bundle"),
            let settingsPlist = NSDictionary(contentsOf: settingsURL),
            let preferences = settingsPlist["PreferenceSpecifiers"] as? [NSDictionary] {

            for prefSpecification in preferences {

                if let key = prefSpecification["Key"] as? String, let value = prefSpecification["DefaultValue"] {

                    //If key doesn't exists in userDefaults then register it, else keep original value
                    if UserDefaults.standard.value(forKey: key) == nil {

                        UserDefaults.standard.set(value, forKey: key)
                        NSLog("registerDefaultsFromSettingsBundle: Set following to UserDefaults - (key: \(key), value: \(value), type: \(type(of: value)))")
                    }
                }
            }
        } else {
            NSLog("registerDefaultsFromSettingsBundle: Could not find Settings.bundle")
        }
    }
}

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        
        // Always set Version to default
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "Version")
        
        setDefaultsFromSettingsBundle()
        MarketScannerCrashDiagnostics.shared.start()
        
        // Override point for customization after application launch.
        if !ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            // Ensure that the device supports scene depth and present
            //  an error-message view controller, if not.
            let storyboard = UIStoryboard(name: "Main", bundle: nil)
            window?.rootViewController = storyboard.instantiateViewController(withIdentifier: "unsupportedDeviceMessage")
        }
        return true
    }

    // MARK: UISceneSession Lifecycle

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        // Called when a new scene session is being created.
        // Use this method to select a configuration to create the new scene with.
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
        // Called when the user discards a scene session.
        // If any sessions were discarded while the application was not running, this will be called shortly after application:didFinishLaunchingWithOptions.
        // Use this method to release any resources that were specific to the discarded scenes, as they will not return.
    }
}
