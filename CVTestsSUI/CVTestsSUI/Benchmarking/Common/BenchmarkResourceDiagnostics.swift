//
//  BenchmarkResourceDiagnostics.swift
//  CVTestsSUI
//
//  Created by Codex on 19.05.2026.
//

import Foundation
import UIKit
import Darwin.Mach

struct BenchmarkResourceDiagnostics {
    let thermalStateBefore: String
    let thermalStateAfter: String
    let thermalStateDidChange: Bool
    let batteryLevelBefore: Float?
    let batteryLevelAfter: Float?
    let batteryLevelDelta: Float?
    let batteryStateBefore: String
    let batteryStateAfter: String
    let residentMemoryBeforeBytes: UInt64?
    let residentMemoryAfterBytes: UInt64?
    let residentMemoryDeltaBytes: Int64?
    let maxObservedResidentMemoryBytes: UInt64?
    let modelSizeBytes: UInt64?
}

private struct BenchmarkResourceSnapshot {
    let thermalState: String
    let batteryLevel: Float?
    let batteryState: String
    let residentMemoryBytes: UInt64?
}

final class BenchmarkResourceMonitor {
    private let modelDescriptor: BenchmarkModelDescriptor
    private let bundle: Bundle
    private let fileManager: FileManager

    private var beforeSnapshot: BenchmarkResourceSnapshot?
    private var previousBatteryMonitoringEnabled = false
    private var didEnableBatteryMonitoring = false
    private var maxObservedResidentMemoryBytes: UInt64?

    init(
        modelDescriptor: BenchmarkModelDescriptor,
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) {
        self.modelDescriptor = modelDescriptor
        self.bundle = bundle
        self.fileManager = fileManager
    }

    func begin() {
        previousBatteryMonitoringEnabled = UIDevice.current.isBatteryMonitoringEnabled
        UIDevice.current.isBatteryMonitoringEnabled = true
        didEnableBatteryMonitoring = true
        let snapshot = Self.makeSnapshot()
        beforeSnapshot = snapshot
        updateMaxResidentMemory(with: snapshot.residentMemoryBytes)
    }

    func recordCheckpoint() {
        updateMaxResidentMemory(with: Self.currentResidentMemoryBytes())
    }

    func finish() -> BenchmarkResourceDiagnostics {
        let afterSnapshot = Self.makeSnapshot()
        updateMaxResidentMemory(with: afterSnapshot.residentMemoryBytes)
        restoreBatteryMonitoringIfNeeded()

        let beforeSnapshot = beforeSnapshot ?? afterSnapshot
        let residentMemoryDeltaBytes = deltaBytes(
            before: beforeSnapshot.residentMemoryBytes,
            after: afterSnapshot.residentMemoryBytes
        )

        return BenchmarkResourceDiagnostics(
            thermalStateBefore: beforeSnapshot.thermalState,
            thermalStateAfter: afterSnapshot.thermalState,
            thermalStateDidChange: beforeSnapshot.thermalState != afterSnapshot.thermalState,
            batteryLevelBefore: beforeSnapshot.batteryLevel,
            batteryLevelAfter: afterSnapshot.batteryLevel,
            batteryLevelDelta: deltaLevel(
                before: beforeSnapshot.batteryLevel,
                after: afterSnapshot.batteryLevel
            ),
            batteryStateBefore: beforeSnapshot.batteryState,
            batteryStateAfter: afterSnapshot.batteryState,
            residentMemoryBeforeBytes: beforeSnapshot.residentMemoryBytes,
            residentMemoryAfterBytes: afterSnapshot.residentMemoryBytes,
            residentMemoryDeltaBytes: residentMemoryDeltaBytes,
            maxObservedResidentMemoryBytes: maxObservedResidentMemoryBytes,
            modelSizeBytes: modelSizeBytes()
        )
    }

    func restoreBatteryMonitoringIfNeeded() {
        guard didEnableBatteryMonitoring else {
            return
        }

        UIDevice.current.isBatteryMonitoringEnabled = previousBatteryMonitoringEnabled
        didEnableBatteryMonitoring = false
    }

    private func modelSizeBytes() -> UInt64? {
        guard let modelURL = BenchmarkModelResourceLocator.resourceURL(
            for: modelDescriptor,
            bundle: bundle
        ) else {
            return nil
        }

        return BenchmarkModelResourceLocator.sizeBytes(at: modelURL, fileManager: fileManager)
    }

    private func updateMaxResidentMemory(with bytes: UInt64?) {
        guard let bytes else {
            return
        }

        if let currentMax = maxObservedResidentMemoryBytes {
            maxObservedResidentMemoryBytes = max(currentMax, bytes)
        } else {
            maxObservedResidentMemoryBytes = bytes
        }
    }

    private func deltaLevel(before: Float?, after: Float?) -> Float? {
        guard let before, let after else {
            return nil
        }

        return after - before
    }

    private func deltaBytes(before: UInt64?, after: UInt64?) -> Int64? {
        guard let before, let after else {
            return nil
        }

        if after >= before {
            return Int64(after - before)
        }

        return -Int64(before - after)
    }

    private static func makeSnapshot() -> BenchmarkResourceSnapshot {
        BenchmarkResourceSnapshot(
            thermalState: ProcessInfo.processInfo.thermalState.reportValue,
            batteryLevel: batteryLevel(),
            batteryState: UIDevice.current.batteryState.reportValue,
            residentMemoryBytes: currentResidentMemoryBytes()
        )
    }

    private static func batteryLevel() -> Float? {
        let level = UIDevice.current.batteryLevel
        guard level >= 0 else {
            return nil
        }

        return level
    }

    private static func currentResidentMemoryBytes() -> UInt64? {
        var taskInfo = mach_task_basic_info()
        var taskInfoCount = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )

        let kernReturn: kern_return_t = withUnsafeMutablePointer(to: &taskInfo) { taskInfoPointer in
            taskInfoPointer.withMemoryRebound(to: integer_t.self, capacity: Int(taskInfoCount)) { reboundPointer in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    reboundPointer,
                    &taskInfoCount
                )
            }
        }

        guard kernReturn == KERN_SUCCESS else {
            return nil
        }

        return UInt64(taskInfo.resident_size)
    }
}

private enum BenchmarkModelResourceLocator {
    private static var cachedURLs: [String: URL] = [:]

    static func resourceURL(
        for descriptor: BenchmarkModelDescriptor,
        bundle: Bundle
    ) -> URL? {
        if let cachedURL = cachedURLs[descriptor.id] {
            return cachedURL
        }

        if let compiledURL = bundle.url(forResource: descriptor.id, withExtension: "mlmodelc") {
            cachedURLs[descriptor.id] = compiledURL
            return compiledURL
        }

        if let packageURL = bundle.url(forResource: descriptor.id, withExtension: "mlpackage") {
            cachedURLs[descriptor.id] = packageURL
            return packageURL
        }

        if let sourcePackageURL = bundle.resourceURL?.appending(path: "MLPackages/\(descriptor.id).mlpackage"),
           FileManager.default.fileExists(atPath: sourcePackageURL.path) {
            cachedURLs[descriptor.id] = sourcePackageURL
            return sourcePackageURL
        }

        guard let resourceRoot = bundle.resourceURL else {
            return nil
        }

        let expectedNames = Set([
            "\(descriptor.id).mlmodelc",
            "\(descriptor.id).mlpackage",
            "\(descriptor.id).mlmodel"
        ])
        let enumerator = FileManager.default.enumerator(
            at: resourceRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .totalFileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        )

        while let candidateURL = enumerator?.nextObject() as? URL {
            guard expectedNames.contains(candidateURL.lastPathComponent) else {
                continue
            }

            cachedURLs[descriptor.id] = candidateURL
            return candidateURL
        }

        return nil
    }

    static func sizeBytes(at url: URL, fileManager: FileManager) -> UInt64? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return nil
        }

        if !isDirectory.boolValue {
            return fileSize(at: url, fileManager: fileManager)
        }

        let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )

        var totalBytes: UInt64 = 0
        while let nestedURL = enumerator?.nextObject() as? URL {
            totalBytes += fileSize(at: nestedURL, fileManager: fileManager) ?? 0
        }

        return totalBytes
    }

    private static func fileSize(at url: URL, fileManager: FileManager) -> UInt64? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let fileSize = values.fileSize else {
            return nil
        }

        return UInt64(fileSize)
    }
}

private extension ProcessInfo.ThermalState {
    var reportValue: String {
        switch self {
        case .nominal:
            return "nominal"
        case .fair:
            return "fair"
        case .serious:
            return "serious"
        case .critical:
            return "critical"
        @unknown default:
            return "unknown"
        }
    }
}

private extension UIDevice.BatteryState {
    var reportValue: String {
        switch self {
        case .unknown:
            return "unknown"
        case .unplugged:
            return "unplugged"
        case .charging:
            return "charging"
        case .full:
            return "full"
        @unknown default:
            return "unknown"
        }
    }
}
