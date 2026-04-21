import Foundation
import APTerminalProtocol

public protocol AuditEventStore: Sendable {
    func appendLine(_ line: Data) throws
    func readLines() throws -> [Data]
    func trimToLast(_ maxLineCount: Int) throws
}

public final class FileAuditEventStore: AuditEventStore, @unchecked Sendable {
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func defaultFileURL(appName: String = APTerminalConfiguration.appName) -> URL {
        APTerminalStoragePaths.auditLogFileURL(appName: appName)
    }

    public func appendLine(_ line: Data) throws {
        try ProtectedFileIO.append(line, to: fileURL)
    }

    public func readLines() throws -> [Data] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        let data = try Data(contentsOf: fileURL)
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { Data($0.utf8) }
    }

    public func trimToLast(_ maxLineCount: Int) throws {
        guard maxLineCount > 0, FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }

        let data = try Data(contentsOf: fileURL)
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(maxLineCount)
            .joined(separator: "\n")

        let rewritten = lines.isEmpty ? Data() : Data((lines + "\n").utf8)
        try ProtectedFileIO.write(rewritten, to: fileURL)
    }
}

public final class InMemoryAuditEventStore: AuditEventStore, @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [Data]

    public init(lines: [Data] = []) {
        self.lines = lines
    }

    public func appendLine(_ line: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        lines.append(line)
    }

    public func readLines() throws -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    public func trimToLast(_ maxLineCount: Int) throws {
        guard maxLineCount > 0 else {
            return
        }

        lock.lock()
        defer { lock.unlock() }
        lines = Array(lines.suffix(maxLineCount))
    }

    public func storedLines() -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}
