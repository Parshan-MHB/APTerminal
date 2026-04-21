import AppKit
import Foundation
import APTerminalProtocol

public enum ExternalTerminalSessionProviderError: Error, Equatable {
    case sessionNotFound(SessionID)
    case unsupportedOperation(SessionID)
    case previewAccessDenied(SessionID)
}

public protocol ExternalSessionProviding: AnyObject, Sendable {
    func handles(sessionID: SessionID) async -> Bool
    func sessionExists(_ sessionID: SessionID) async -> Bool
    func listSessions() async -> [SessionSummary]
    func attach(
        sessionID: SessionID,
        consumerID: UUID,
        onChunk: @escaping @Sendable (TerminalStreamChunk) -> Void
    ) async throws
    func detach(sessionID: SessionID, consumerID: UUID) async
    func lockSession(_ sessionID: SessionID) async
    func invalidate() async
}

public actor ExternalTerminalSessionProvider: ExternalSessionProviding {
    private static let emptySnapshotPlaceholderSuffix = " is available for preview, but no output was returned yet.]"
    private static let fullRedrawPrefix = Data("\u{1B}[2J\u{1B}[H".utf8)

    public struct Configuration: Sendable {
        public var maximumChunkBytes: Int
        public var maximumSnapshotBytes: Int
        public var maximumSnapshotLines: Int
        public var refreshIntervalMilliseconds: UInt64

        public init(
            maximumChunkBytes: Int = APTerminalConfiguration.defaultExternalPreviewChunkBytes,
            maximumSnapshotBytes: Int = APTerminalConfiguration.defaultExternalPreviewSnapshotBytes,
            maximumSnapshotLines: Int = APTerminalConfiguration.defaultExternalPreviewSnapshotLines,
            refreshIntervalMilliseconds: UInt64 = APTerminalConfiguration.defaultExternalPreviewRefreshIntervalMilliseconds
        ) {
            self.maximumChunkBytes = maximumChunkBytes
            self.maximumSnapshotBytes = maximumSnapshotBytes
            self.maximumSnapshotLines = maximumSnapshotLines
            self.refreshIntervalMilliseconds = refreshIntervalMilliseconds
        }
    }

    private enum ExternalAppKind: String, CaseIterable {
        case terminal
        case iTerm

        var sessionSource: SessionSource {
            switch self {
            case .terminal:
                return .terminalApp
            case .iTerm:
                return .iTermApp
            }
        }

        var sessionIDPrefix: String {
            switch self {
            case .terminal:
                return "external:terminal:"
            case .iTerm:
                return "external:iterm:"
            }
        }

        var applicationNames: [String] {
            switch self {
            case .terminal:
                return ["Terminal"]
            case .iTerm:
                return ["iTerm2", "iTerm"]
            }
        }

        var bundleIdentifiers: [String] {
            switch self {
            case .terminal:
                return ["com.apple.Terminal"]
            case .iTerm:
                return ["com.googlecode.iterm2"]
            }
        }

        var shellPathLabel: String {
            switch self {
            case .terminal:
                return "Terminal.app"
            case .iTerm:
                return "iTerm.app"
            }
        }

        var titleFallbackPrefix: String {
            switch self {
            case .terminal:
                return "Terminal"
            case .iTerm:
                return "iTerm"
            }
        }
    }

    private struct ExternalSessionKey {
        let app: ExternalAppKind
        let windowID: Int
    }

    private struct ScriptWindowRecord: Decodable {
        let windowID: Int
        let title: String
        let tty: String
        let contents: String
        let busy: Bool?
    }

    private struct ExternalSessionSnapshot {
        let summary: SessionSummary
        let outputData: Data
    }

    private struct AttachedConsumer {
        let onChunk: @Sendable (TerminalStreamChunk) -> Void
    }

    private var attachedConsumers: [SessionID: [UUID: AttachedConsumer]] = [:]
    private var lastDeliveredSnapshotData: [SessionID: Data] = [:]
    private var nextSequenceNumbers: [SessionID: UInt64] = [:]
    private var refreshTask: Task<Void, Never>?
    private let configuration: Configuration

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    public func handles(sessionID: SessionID) async -> Bool {
        parseSessionID(sessionID) != nil
    }

    public func sessionExists(_ sessionID: SessionID) async -> Bool {
        guard let key = parseSessionID(sessionID) else {
            return false
        }

        return (try? loadRecord(for: key)) != nil
    }

    public func listSessions() async -> [SessionSummary] {
        let scanTime = Date()
        let sessions = ExternalAppKind.allCases.flatMap { app in
            (try? loadRecords(for: app))?.map { makeSummary(from: $0, app: app, scanTime: scanTime) } ?? []
        }

        return sessions.sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    public func attach(
        sessionID: SessionID,
        consumerID: UUID,
        onChunk: @escaping @Sendable (TerminalStreamChunk) -> Void
    ) async throws {
        guard parseSessionID(sessionID) != nil else {
            throw ExternalTerminalSessionProviderError.sessionNotFound(sessionID)
        }

        var consumers = attachedConsumers[sessionID] ?? [:]
        consumers[consumerID] = AttachedConsumer(onChunk: onChunk)
        attachedConsumers[sessionID] = consumers
        lastDeliveredSnapshotData.removeValue(forKey: sessionID)
        nextSequenceNumbers[sessionID] = 1
        startRefreshLoopIfNeeded()

        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(
                for: .milliseconds(APTerminalConfiguration.defaultExternalPreviewInitialSnapshotDelayMilliseconds)
            )
            await self.loadAndDeliverInitialSnapshotIfStillAttached(sessionID: sessionID)
        }
    }

    public func detach(sessionID: SessionID, consumerID: UUID) {
        guard var consumers = attachedConsumers[sessionID] else {
            return
        }

        consumers.removeValue(forKey: consumerID)
        if consumers.isEmpty {
            attachedConsumers.removeValue(forKey: sessionID)
            lastDeliveredSnapshotData.removeValue(forKey: sessionID)
            nextSequenceNumbers.removeValue(forKey: sessionID)
        } else {
            attachedConsumers[sessionID] = consumers
        }

        stopRefreshLoopIfNeeded()
    }

    public func lockSession(_ sessionID: SessionID) {
        attachedConsumers.removeValue(forKey: sessionID)
        lastDeliveredSnapshotData.removeValue(forKey: sessionID)
        nextSequenceNumbers.removeValue(forKey: sessionID)
        stopRefreshLoopIfNeeded()
    }

    public func invalidate() {
        attachedConsumers.removeAll()
        lastDeliveredSnapshotData.removeAll()
        nextSequenceNumbers.removeAll()
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func loadSnapshot(for sessionID: SessionID) throws -> ExternalSessionSnapshot {
        guard let key = parseSessionID(sessionID) else {
            throw ExternalTerminalSessionProviderError.sessionNotFound(sessionID)
        }

        guard let record = try loadRecord(for: key) else {
            throw ExternalTerminalSessionProviderError.sessionNotFound(sessionID)
        }

        let now = Date()
        let summary = makeSummary(from: record, app: key.app, scanTime: now)
        let snapshotText: String
        if record.contents.isEmpty {
            snapshotText = "[\(summary.title)\(Self.emptySnapshotPlaceholderSuffix)\n"
        } else {
            snapshotText = trimmedSnapshotText(from: record.contents)
        }

        return ExternalSessionSnapshot(
            summary: summary,
            outputData: Data(snapshotText.utf8)
        )
    }

    private func makeSnapshotChunk(for sessionID: SessionID, sequenceNumber: UInt64, data: Data) -> TerminalStreamChunk {
        TerminalStreamChunk(
            sessionID: sessionID,
            direction: .output,
            sequenceNumber: sequenceNumber,
            data: data
        )
    }

    private func startRefreshLoopIfNeeded() {
        guard refreshTask == nil else {
            return
        }

        let refreshIntervalMilliseconds = configuration.refreshIntervalMilliseconds
        refreshTask = Task { [weak self] in
            while Task.isCancelled == false {
                try? await Task.sleep(for: .milliseconds(refreshIntervalMilliseconds))
                guard let self else { return }
                await self.refreshAttachedSnapshots()
            }
        }
    }

    private func stopRefreshLoopIfNeeded() {
        guard attachedConsumers.isEmpty else {
            return
        }

        refreshTask?.cancel()
        refreshTask = nil
    }

    private func refreshAttachedSnapshots() async {
        guard attachedConsumers.isEmpty == false else {
            stopRefreshLoopIfNeeded()
            return
        }

        let sessionIDs = Array(attachedConsumers.keys)
        for sessionID in sessionIDs {
            guard let consumers = attachedConsumers[sessionID], consumers.isEmpty == false else {
                continue
            }

            guard let snapshot = try? loadSnapshot(for: sessionID) else {
                continue
            }

            guard lastDeliveredSnapshotData[sessionID] != snapshot.outputData else {
                continue
            }

            let payload = makeRefreshPayload(
                previousData: lastDeliveredSnapshotData[sessionID],
                latestData: snapshot.outputData
            )
            lastDeliveredSnapshotData[sessionID] = snapshot.outputData
            streamPayload(payload, for: sessionID)
        }
    }

    private func loadAndDeliverInitialSnapshotIfStillAttached(sessionID: SessionID) async {
        guard (attachedConsumers[sessionID] ?? [:]).isEmpty == false else {
            return
        }

        guard let snapshot = try? loadSnapshot(for: sessionID) else {
            return
        }

        deliverInitialSnapshotIfStillAttached(sessionID: sessionID, data: snapshot.outputData)
    }

    private func deliverInitialSnapshotIfStillAttached(sessionID: SessionID, data: Data) {
        guard let consumers = attachedConsumers[sessionID], consumers.isEmpty == false else {
            return
        }

        guard lastDeliveredSnapshotData[sessionID] == nil else {
            return
        }

        lastDeliveredSnapshotData[sessionID] = data
        nextSequenceNumbers[sessionID] = 1
        streamPayload(data, for: sessionID)
    }

    private func makeRefreshPayload(previousData: Data?, latestData: Data) -> Data {
        guard let previousData, previousData.isEmpty == false else {
            return latestData
        }

        if latestData.starts(with: previousData) {
            return latestData.dropFirst(previousData.count)
        }

        var payload = Self.fullRedrawPrefix
        payload.append(latestData)
        return payload
    }

    private func streamPayload(_ payload: Data, for sessionID: SessionID) {
        guard payload.isEmpty == false else {
            return
        }

        var offset = 0
        while offset < payload.count {
            guard let consumers = attachedConsumers[sessionID], consumers.isEmpty == false else {
                return
            }

            let end = min(payload.count, offset + configuration.maximumChunkBytes)
            let chunkData = payload.subdata(in: offset..<end)
            let sequenceNumber = nextSequenceNumbers[sessionID] ?? 1
            nextSequenceNumbers[sessionID] = sequenceNumber + 1
            let chunk = makeSnapshotChunk(for: sessionID, sequenceNumber: sequenceNumber, data: chunkData)
            for consumer in consumers.values {
                consumer.onChunk(chunk)
            }
            offset = end
        }
    }

    private func makeSummary(from record: ScriptWindowRecord, app: ExternalAppKind, scanTime: Date) -> SessionSummary {
        let sessionID = SessionID(rawValue: "\(app.sessionIDPrefix)\(record.windowID)")
        let displayTitle = record.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "\(app.titleFallbackPrefix) \(record.windowID)"
            : record.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayLocation = record.tty.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? app.shellPathLabel
            : record.tty.trimmingCharacters(in: .whitespacesAndNewlines)
        let isAttached = (attachedConsumers[sessionID] ?? [:]).isEmpty == false
        let preview = sanitizedPreview(from: record.contents)

        return SessionSummary(
            id: sessionID,
            title: displayTitle,
            shellPath: app.shellPathLabel,
            workingDirectory: displayLocation,
            state: isAttached ? .attached : .running,
            source: app.sessionSource,
            capabilities: .readOnlyPreview,
            pid: nil,
            size: SessionWindowSize(rows: 40, columns: 120),
            createdAt: scanTime,
            lastActivityAt: scanTime,
            previewExcerpt: preview
        )
    }

    private func parseSessionID(_ sessionID: SessionID) -> ExternalSessionKey? {
        for app in ExternalAppKind.allCases where sessionID.rawValue.hasPrefix(app.sessionIDPrefix) {
            let suffix = sessionID.rawValue.dropFirst(app.sessionIDPrefix.count)
            guard let windowID = Int(suffix) else {
                return nil
            }
            return ExternalSessionKey(app: app, windowID: windowID)
        }

        return nil
    }

    private func loadRecord(for key: ExternalSessionKey) throws -> ScriptWindowRecord? {
        try loadRecords(for: key.app).first(where: { $0.windowID == key.windowID })
    }

    private func loadRecords(for app: ExternalAppKind) throws -> [ScriptWindowRecord] {
        for bundleIdentifier in app.bundleIdentifiers {
            if let records = try loadRecords(bundleIdentifier: bundleIdentifier, app: app) {
                return records
            }
        }

        for appName in app.applicationNames {
            if let records = try loadRecords(appName: appName, app: app) {
                return records
            }
        }

        return []
    }

    private func loadRecords(bundleIdentifier: String, app: ExternalAppKind) throws -> [ScriptWindowRecord]? {
        let output = try runAppleScript(
            lines: scriptLines(for: app, targetClause: "application id \"\(bundleIdentifier)\""),
            allowApplicationMissing: true
        )
        guard output.isEmpty == false else {
            return nil
        }

        let data = Data(output.utf8)
        return try JSONDecoder().decode([ScriptWindowRecord].self, from: data)
    }

    private func loadRecords(appName: String, app: ExternalAppKind) throws -> [ScriptWindowRecord]? {
        let output = try runAppleScript(
            lines: scriptLines(for: app, targetClause: "application \"\(appName)\""),
            allowApplicationMissing: true
        )
        guard output.isEmpty == false else {
            return nil
        }

        let data = Data(output.utf8)
        return try JSONDecoder().decode([ScriptWindowRecord].self, from: data)
    }

    private func scriptLines(for app: ExternalAppKind, targetClause: String) -> [String] {
        let commonPreamble = [
            "use framework \"Foundation\"",
            "use scripting additions",
            "on jsonStringFromObject_(value)",
            "set {jsonData, jsonError} to current application's NSJSONSerialization's dataWithJSONObject:value options:0 |error|:(reference)",
            "if jsonData = missing value then error (jsonError's localizedDescription() as text)",
            "return (current application's NSString's alloc()'s initWithData:jsonData encoding:(current application's NSUTF8StringEncoding)) as text",
            "end jsonStringFromObject_",
            "set rows to current application's NSMutableArray's array()",
        ]

        switch app {
        case .terminal:
            return commonPreamble + [
                "tell \(targetClause)",
                "repeat with appWindow in windows",
                "set tabRef to selected tab of appWindow",
                "set row to current application's NSMutableDictionary's dictionary()",
                "row's setObject:(id of appWindow) forKey:\"windowID\"",
                "set titleValue to \"\"",
                "try",
                "set titleValue to (custom title of tabRef as text)",
                "end try",
                "if titleValue is \"\" then",
                "try",
                "set titleValue to (name of appWindow as text)",
                "end try",
                "end if",
                "row's setObject:titleValue forKey:\"title\"",
                "set ttyValue to \"\"",
                "try",
                "set ttyValue to (tty of tabRef as text)",
                "end try",
                "row's setObject:ttyValue forKey:\"tty\"",
                "set contentsValue to \"\"",
                "try",
                "set contentsValue to (history of tabRef as text)",
                "end try",
                "row's setObject:contentsValue forKey:\"contents\"",
                "set busyValue to false",
                "try",
                "set busyValue to (busy of tabRef as boolean)",
                "end try",
                "row's setObject:busyValue forKey:\"busy\"",
                "rows's addObject:row",
                "end repeat",
                "end tell",
                "return my jsonStringFromObject_(rows)",
            ]
        case .iTerm:
            return commonPreamble + [
                "tell \(targetClause)",
                "repeat with appWindow in windows",
                "set sessionRef to current session of current tab of appWindow",
                "set row to current application's NSMutableDictionary's dictionary()",
                "row's setObject:(id of appWindow) forKey:\"windowID\"",
                "set titleValue to \"\"",
                "try",
                "set titleValue to (name of sessionRef as text)",
                "end try",
                "row's setObject:titleValue forKey:\"title\"",
                "set ttyValue to \"\"",
                "try",
                "set ttyValue to (tty of sessionRef as text)",
                "end try",
                "row's setObject:ttyValue forKey:\"tty\"",
                "set contentsValue to \"\"",
                "try",
                "set contentsValue to (contents of sessionRef as text)",
                "end try",
                "row's setObject:contentsValue forKey:\"contents\"",
                "row's setObject:false forKey:\"busy\"",
                "rows's addObject:row",
                "end repeat",
                "end tell",
                "return my jsonStringFromObject_(rows)",
            ]
        }
    }

    private func runAppleScript(lines: [String], allowApplicationMissing: Bool) throws -> String {
        let source = lines.joined(separator: "\n")
        guard let script = NSAppleScript(source: source) else {
            throw NSError(
                domain: "ExternalTerminalSessionProvider",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to compile AppleScript source."]
            )
        }

        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)

        if let errorInfo {
            let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "AppleScript execution failed."
            if allowApplicationMissing,
               message.localizedCaseInsensitiveContains("can’t get application") ||
               message.localizedCaseInsensitiveContains("can't get application") ||
               message.localizedCaseInsensitiveContains("application isn’t running") ||
               message.localizedCaseInsensitiveContains("application isn't running")
            {
                return ""
            }

            throw NSError(
                domain: "ExternalTerminalSessionProvider",
                code: (errorInfo[NSAppleScript.errorNumber] as? Int) ?? -1,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        return result.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func sanitizedPreview(from contents: String) -> String {
        let truncated = String(contents.suffix(256))
        let controlCharacters = CharacterSet.controlCharacters
        let filteredScalars = truncated.unicodeScalars.filter {
            !controlCharacters.contains($0) || $0 == "\n" || $0 == "\t"
        }
        let sanitized = String(String.UnicodeScalarView(filteredScalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return sanitized
    }

    private func trimmedSnapshotText(from contents: String) -> String {
        let limitedByLines: String
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > configuration.maximumSnapshotLines {
            limitedByLines = lines.suffix(configuration.maximumSnapshotLines).joined(separator: "\n")
        } else {
            limitedByLines = contents
        }

        if limitedByLines.utf8.count <= configuration.maximumSnapshotBytes {
            return limitedByLines
        }

        let suffixScalars = limitedByLines.unicodeScalars.suffix(configuration.maximumSnapshotBytes)
        return String(String.UnicodeScalarView(suffixScalars))
    }
}
