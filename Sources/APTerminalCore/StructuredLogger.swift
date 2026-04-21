import Foundation
import OSLog

public enum LogSeverity: String, Sendable {
    case debug
    case info
    case notice
    case error
    case fault
}

public protocol LogSink: Sendable {
    func write(
        severity: LogSeverity,
        subsystem: String,
        category: String,
        message: String,
        metadata: [String: String]
    )
}

public struct OSLogSink: LogSink {
    public init() {}

    public func write(
        severity: LogSeverity,
        subsystem: String,
        category: String,
        message: String,
        metadata: [String: String]
    ) {
        let logger = Logger(subsystem: subsystem, category: category)
        let formattedMetadata = metadata.isEmpty
            ? ""
            : metadata.keys.sorted().map { "\($0)=\(metadata[$0] ?? "")" }.joined(separator: " ")
        let payload = formattedMetadata.isEmpty ? message : "\(message) | \(formattedMetadata)"

        switch severity {
        case .debug:
            logger.debug("\(payload, privacy: .public)")
        case .info:
            logger.info("\(payload, privacy: .public)")
        case .notice:
            logger.notice("\(payload, privacy: .public)")
        case .error:
            logger.error("\(payload, privacy: .public)")
        case .fault:
            logger.fault("\(payload, privacy: .public)")
        }
    }
}

public final class InMemoryLogSink: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var records: [String] = []

    public init() {}

    public func write(
        severity: LogSeverity,
        subsystem: String,
        category: String,
        message: String,
        metadata: [String: String]
    ) {
        let metadataString = metadata.keys.sorted().map { "\($0)=\(metadata[$0] ?? "")" }.joined(separator: " ")
        let line = "[\(severity.rawValue)] \(subsystem).\(category): \(message)\(metadataString.isEmpty ? "" : " | \(metadataString)")"

        lock.lock()
        defer { lock.unlock() }
        records.append(line)
    }
}

public struct StructuredLogger: Sendable {
    public let subsystem: String
    public let category: String

    private let sink: LogSink

    public init(subsystem: String, category: String, sink: LogSink = OSLogSink()) {
        self.subsystem = subsystem
        self.category = category
        self.sink = sink
    }

    public func debug(_ message: String, metadata: [String: String] = [:]) {
        sink.write(severity: .debug, subsystem: subsystem, category: category, message: message, metadata: metadata)
    }

    public func info(_ message: String, metadata: [String: String] = [:]) {
        sink.write(severity: .info, subsystem: subsystem, category: category, message: message, metadata: metadata)
    }

    public func notice(_ message: String, metadata: [String: String] = [:]) {
        sink.write(severity: .notice, subsystem: subsystem, category: category, message: message, metadata: metadata)
    }

    public func error(_ message: String, metadata: [String: String] = [:]) {
        sink.write(severity: .error, subsystem: subsystem, category: category, message: message, metadata: metadata)
    }

    public func fault(_ message: String, metadata: [String: String] = [:]) {
        sink.write(severity: .fault, subsystem: subsystem, category: category, message: message, metadata: metadata)
    }
}
