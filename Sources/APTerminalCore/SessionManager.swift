import Foundation
import APTerminalPTY
import APTerminalProtocol

public enum SessionManagerError: Error, Equatable {
    case sessionNotFound(SessionID)
    case invalidTitle
    case sessionExited
}

public actor SessionManager {
    private struct Subscriber {
        let id: UUID
        let onChunk: @Sendable (TerminalStreamChunk) -> Void
    }

    private struct ManagedSession {
        var id: SessionID
        var title: String
        var shellPath: String
        var workingDirectory: String
        var state: SessionState
        var pid: Int32?
        var size: SessionWindowSize
        var createdAt: Date
        var lastActivityAt: Date
        var previewExcerpt: String
        var outputSequence: UInt64
        var process: PTYProcess
        var subscribers: [UUID: Subscriber]
    }

    private var sessions: [SessionID: ManagedSession] = [:]

    public init() {}

    public func listSessions() -> [SessionSummary] {
        sessions.values
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
            .map(summary(from:))
    }

    @discardableResult
    public func createSession(
        shellPath: String?,
        workingDirectory: String?,
        initialSize: SessionWindowSize
    ) throws -> SessionSummary {
        let sessionID = SessionID.random()
        let resolvedShellPath = shellPath ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let resolvedWorkingDirectory = workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path
        let createdAt = Date()

        let process = PTYProcess(
            shellPath: resolvedShellPath,
            workingDirectory: resolvedWorkingDirectory,
            onOutput: { [sessionID] data in
                Task { [sessionID] in
                    await self.handleOutput(for: sessionID, data: data)
                }
            },
            onExit: { [sessionID] exitCode in
                Task { [sessionID] in
                    await self.handleExit(for: sessionID, exitCode: exitCode)
                }
            }
        )

        try process.start(rows: initialSize.rows, columns: initialSize.columns)

        let session = ManagedSession(
            id: sessionID,
            title: defaultTitle(for: resolvedWorkingDirectory),
            shellPath: resolvedShellPath,
            workingDirectory: resolvedWorkingDirectory,
            state: .running,
            pid: process.pid,
            size: initialSize,
            createdAt: createdAt,
            lastActivityAt: createdAt,
            previewExcerpt: "",
            outputSequence: 0,
            process: process,
            subscribers: [:]
        )

        sessions[sessionID] = session
        return summary(from: session)
    }

    public func renameSession(id: SessionID, title: String) throws -> SessionSummary {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmedTitle.isEmpty == false else {
            throw SessionManagerError.invalidTitle
        }

        guard var session = sessions[id] else {
            throw SessionManagerError.sessionNotFound(id)
        }

        session.title = trimmedTitle
        session.lastActivityAt = Date()
        sessions[id] = session
        return summary(from: session)
    }

    public func closeSession(id: SessionID) async throws {
        guard let session = sessions.removeValue(forKey: id) else {
            throw SessionManagerError.sessionNotFound(id)
        }

        let process = session.process
        _ = await Task.detached {
            process.terminate()
        }.value
    }

    public func closeAllSessions() async {
        let managedSessions = Array(sessions.values)
        sessions.removeAll()

        await withTaskGroup(of: Void.self) { group in
            for session in managedSessions {
                let process = session.process
                group.addTask {
                    _ = process.terminate()
                }
            }
        }
    }

    public func attach(
        sessionID: SessionID,
        consumerID: UUID,
        onChunk: @escaping @Sendable (TerminalStreamChunk) -> Void
    ) throws {
        guard var session = sessions[sessionID] else {
            throw SessionManagerError.sessionNotFound(sessionID)
        }

        session.subscribers[consumerID] = Subscriber(id: consumerID, onChunk: onChunk)
        session.state = .attached
        session.lastActivityAt = Date()
        sessions[sessionID] = session
    }

    public func detach(sessionID: SessionID, consumerID: UUID) {
        guard var session = sessions[sessionID] else {
            return
        }

        session.subscribers.removeValue(forKey: consumerID)
        session.state = session.subscribers.isEmpty ? .running : .attached
        session.lastActivityAt = Date()
        sessions[sessionID] = session
    }

    public func lockSession(sessionID: SessionID) {
        guard var session = sessions[sessionID] else {
            return
        }

        session.subscribers.removeAll()
        session.state = .running
        session.lastActivityAt = Date()
        sessions[sessionID] = session
    }

    public func resizeSession(id: SessionID, size: SessionWindowSize) throws {
        guard var session = sessions[id] else {
            throw SessionManagerError.sessionNotFound(id)
        }

        guard session.state != .exited else {
            throw SessionManagerError.sessionExited
        }

        try session.process.resize(rows: size.rows, columns: size.columns)
        session.size = size
        session.lastActivityAt = Date()
        sessions[id] = session
    }

    public func sendInput(sessionID: SessionID, data: Data) throws {
        guard var session = sessions[sessionID] else {
            throw SessionManagerError.sessionNotFound(sessionID)
        }

        guard session.state != .exited else {
            throw SessionManagerError.sessionExited
        }

        try session.process.write(data)
        session.lastActivityAt = Date()
        sessions[sessionID] = session
    }

    public func sessionSummary(id: SessionID) -> SessionSummary? {
        guard let session = sessions[id] else {
            return nil
        }

        return summary(from: session)
    }

    private func handleOutput(for sessionID: SessionID, data: Data) {
        guard var session = sessions[sessionID] else {
            return
        }

        session.outputSequence += 1
        session.lastActivityAt = Date()
        session.previewExcerpt = Self.updatedPreview(existing: session.previewExcerpt, newData: data)
        let chunk = TerminalStreamChunk(
            sessionID: sessionID,
            direction: .output,
            sequenceNumber: session.outputSequence,
            data: data
        )

        let subscribers = Array(session.subscribers.values)
        sessions[sessionID] = session

        for subscriber in subscribers {
            subscriber.onChunk(chunk)
        }
    }

    private func handleExit(for sessionID: SessionID, exitCode: Int32) {
        guard var session = sessions[sessionID] else {
            return
        }

        session.outputSequence += 1
        session.state = exitCode == 0 ? .exited : .failed
        session.pid = nil
        session.lastActivityAt = Date()
        let subscribers = Array(session.subscribers.values)
        let exitSummary = exitCode == 0 ? "Session exited." : "Session failed with code \(exitCode)."
        let chunk = TerminalStreamChunk(
            sessionID: sessionID,
            direction: .output,
            sequenceNumber: session.outputSequence,
            data: Data(("\r\n[\(exitSummary)]\r\n").utf8)
        )
        session.previewExcerpt = Self.updatedPreview(existing: session.previewExcerpt, newData: chunk.data)
        session.subscribers.removeAll()
        sessions[sessionID] = session

        for subscriber in subscribers {
            subscriber.onChunk(chunk)
        }
    }

    private func summary(from session: ManagedSession) -> SessionSummary {
        SessionSummary(
            id: session.id,
            title: session.title,
            shellPath: session.shellPath,
            workingDirectory: session.workingDirectory,
            state: session.state,
            pid: session.pid,
            size: session.size,
            createdAt: session.createdAt,
            lastActivityAt: session.lastActivityAt,
            previewExcerpt: session.previewExcerpt
        )
    }

    private func defaultTitle(for workingDirectory: String) -> String {
        URL(fileURLWithPath: workingDirectory).lastPathComponent
    }

    private static func updatedPreview(existing: String, newData: Data) -> String {
        guard let decoded = String(data: newData, encoding: .utf8) else {
            return existing
        }

        let controlCharacters = CharacterSet.controlCharacters
        let filteredScalars = decoded.unicodeScalars.filter {
            !controlCharacters.contains($0) || $0 == "\n" || $0 == "\t"
        }
        let sanitized = String(String.UnicodeScalarView(filteredScalars))

        let merged = (existing + sanitized).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(merged.suffix(256))
    }
}
