//
//  BenchmarkLogStore.swift
//  CVTestsSUI
//
//  Created by Codex on 13.05.2026.
//

import Foundation

enum BenchmarkLogStoreError: LocalizedError {
    case documentsDirectoryUnavailable
    case noLogsAvailable
    case invalidShareCount

    var errorDescription: String? {
        switch self {
        case .documentsDirectoryUnavailable:
            return "Documents directory is unavailable"
        case .noLogsAvailable:
            return "No log files available"
        case .invalidShareCount:
            return "Log count must be greater than zero"
        }
    }
}

struct BenchmarkLogStore {
    private static let legacyLogDirectoryName = "BenchmarkLogs"
    private static let exportDirectoryName = "BenchmarkLogExports"

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    var logsDirectory: URL {
        get throws {
            let directory = try documentsDirectory()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }
    }

    func writeLog(text: String, experimentKind: BenchmarkExperimentKind, date: Date = Date()) throws -> URL {
        let directory = try logsDirectory
        let fileURL = directory.appendingPathComponent(fileName(kind: experimentKind, date: date))
        try text.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    func writeRunArchive(
        files: [URL],
        experimentKind: BenchmarkExperimentKind,
        date: Date = Date()
    ) throws -> URL {
        let directory = try logsDirectory
        let archiveURL = directory.appendingPathComponent(archiveFileName(kind: experimentKind, date: date))
        try ZipArchiveWriter.write(files: files, to: archiveURL)
        return archiveURL
    }

    func latestLogFiles(limit: Int) throws -> [URL] {
        guard limit > 0 else {
            throw BenchmarkLogStoreError.invalidShareCount
        }

        return Array(try allLogFiles().prefix(limit))
    }

    func logFileCount() throws -> Int {
        try allLogFiles().count
    }

    func removeDocumentExportDirectory() throws {
        let exportDirectory = try documentsDirectory()
            .appendingPathComponent(Self.exportDirectoryName, isDirectory: true)
        if fileManager.fileExists(atPath: exportDirectory.path) {
            try fileManager.removeItem(at: exportDirectory)
        }
    }

    func makeArchiveOfLatestLogs(limit: Int, date: Date = Date()) throws -> URL {
        try removeDocumentExportDirectory()

        let files = try latestLogFiles(limit: limit)
        guard !files.isEmpty else {
            throw BenchmarkLogStoreError.noLogsAvailable
        }

        let exportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent(Self.exportDirectoryName, isDirectory: true)
        if fileManager.fileExists(atPath: exportDirectory.path) {
            try fileManager.removeItem(at: exportDirectory)
        }
        try fileManager.createDirectory(at: exportDirectory, withIntermediateDirectories: true)

        let archiveURL = exportDirectory.appendingPathComponent("benchmark-logs-\(Self.fileTimestampFormatter.string(from: date)).zip")
        try ZipArchiveWriter.write(files: files, to: archiveURL)
        return archiveURL
    }

    private func allLogFiles() throws -> [URL] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        let urls = try visibleLogDirectories().flatMap { directory in
            try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )
        }

        return try urls
            .filter { url in
                let values = try url.resourceValues(forKeys: keys)
                return values.isRegularFile == true && url.pathExtension.lowercased() == "txt"
            }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhsDate > rhsDate
            }
    }

    private func documentsDirectory() throws -> URL {
        guard let directory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw BenchmarkLogStoreError.documentsDirectoryUnavailable
        }

        return directory
    }

    private func visibleLogDirectories() throws -> [URL] {
        let documents = try documentsDirectory()
        let legacyLogs = documents.appendingPathComponent(Self.legacyLogDirectoryName, isDirectory: true)

        if fileManager.fileExists(atPath: legacyLogs.path) {
            return [documents, legacyLogs]
        }

        return [documents]
    }

    private func fileName(kind: BenchmarkExperimentKind, date: Date) -> String {
        "benchmark-\(kind.rawValue)-\(Self.fileTimestampFormatter.string(from: date)).txt"
    }

    private func archiveFileName(kind: BenchmarkExperimentKind, date: Date) -> String {
        "benchmark-\(kind.rawValue)-\(Self.fileTimestampFormatter.string(from: date)).zip"
    }

    private static let fileTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

private enum ZipArchiveWriter {
    private struct Entry {
        let name: String
        let crc32: UInt32
        let size: UInt32
        let offset: UInt32
        let modifiedAt: Date
    }

    static func write(files: [URL], to archiveURL: URL) throws {
        var data = Data()
        var entries: [Entry] = []

        for fileURL in files {
            let fileData = try Data(contentsOf: fileURL)
            let entryName = safeEntryName(from: fileURL)
            let offset = UInt32(data.count)
            let crc = CRC32.checksum(fileData)
            let size = UInt32(fileData.count)
            let modifiedAt = modificationDate(for: fileURL)

            appendLocalFileHeader(
                name: entryName,
                crc32: crc,
                size: size,
                modifiedAt: modifiedAt,
                to: &data
            )
            data.append(fileData)

            entries.append(Entry(name: entryName, crc32: crc, size: size, offset: offset, modifiedAt: modifiedAt))
        }

        let centralDirectoryOffset = UInt32(data.count)
        for entry in entries {
            appendCentralDirectoryHeader(entry: entry, to: &data)
        }

        let centralDirectorySize = UInt32(data.count) - centralDirectoryOffset
        appendEndOfCentralDirectory(
            entryCount: UInt16(entries.count),
            centralDirectorySize: centralDirectorySize,
            centralDirectoryOffset: centralDirectoryOffset,
            to: &data
        )

        try data.write(to: archiveURL, options: .atomic)
    }

    private static func appendLocalFileHeader(
        name: String,
        crc32: UInt32,
        size: UInt32,
        modifiedAt: Date,
        to data: inout Data
    ) {
        let nameData = Data(name.utf8)
        let dosTime = DOSDateTime(date: modifiedAt)

        data.appendLittleEndian(UInt32(0x04034b50))
        data.appendLittleEndian(UInt16(20))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(dosTime.time)
        data.appendLittleEndian(dosTime.date)
        data.appendLittleEndian(crc32)
        data.appendLittleEndian(size)
        data.appendLittleEndian(size)
        data.appendLittleEndian(UInt16(nameData.count))
        data.appendLittleEndian(UInt16(0))
        data.append(nameData)
    }

    private static func appendCentralDirectoryHeader(entry: Entry, to data: inout Data) {
        let nameData = Data(entry.name.utf8)
        let dosTime = DOSDateTime(date: entry.modifiedAt)

        data.appendLittleEndian(UInt32(0x02014b50))
        data.appendLittleEndian(UInt16(20))
        data.appendLittleEndian(UInt16(20))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(dosTime.time)
        data.appendLittleEndian(dosTime.date)
        data.appendLittleEndian(entry.crc32)
        data.appendLittleEndian(entry.size)
        data.appendLittleEndian(entry.size)
        data.appendLittleEndian(UInt16(nameData.count))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(UInt32(0))
        data.appendLittleEndian(entry.offset)
        data.append(nameData)
    }

    private static func appendEndOfCentralDirectory(
        entryCount: UInt16,
        centralDirectorySize: UInt32,
        centralDirectoryOffset: UInt32,
        to data: inout Data
    ) {
        data.appendLittleEndian(UInt32(0x06054b50))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(entryCount)
        data.appendLittleEndian(entryCount)
        data.appendLittleEndian(centralDirectorySize)
        data.appendLittleEndian(centralDirectoryOffset)
        data.appendLittleEndian(UInt16(0))
    }

    private static func safeEntryName(from url: URL) -> String {
        url.lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
    }

    private static func modificationDate(for url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
    }
}

private struct DOSDateTime {
    let date: UInt16
    let time: UInt16

    init(date sourceDate: Date) {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: sourceDate)
        let year = max((components.year ?? 1980), 1980)
        let month = components.month ?? 1
        let day = components.day ?? 1
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        let second = (components.second ?? 0) / 2

        self.date = UInt16(((year - 1980) << 9) | (month << 5) | day)
        self.time = UInt16((hour << 11) | (minute << 5) | second)
    }
}

private enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            if value & 1 == 1 {
                value = (value >> 1) ^ 0xedb88320
            } else {
                value >>= 1
            }
        }
        return value
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xff)
            crc = (crc >> 8) ^ table[index]
        }
        return crc ^ UInt32.max
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }
}
