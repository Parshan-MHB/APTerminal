import Foundation

public enum SessionState: String, Codable, Sendable {
    case starting
    case running
    case attached
    case closing
    case exited
    case failed
}

public struct SessionWindowSize: Codable, Equatable, Sendable {
    public var rows: UInt16
    public var columns: UInt16

    public init(rows: UInt16, columns: UInt16) {
        self.rows = rows
        self.columns = columns
    }
}

public enum SessionSource: String, Codable, Sendable {
    case managed
    case terminalApp
    case iTermApp
}

public struct SessionCapabilities: Codable, Equatable, Sendable {
    public var supportsInput: Bool
    public var supportsResize: Bool
    public var supportsRename: Bool
    public var supportsClose: Bool

    public init(
        supportsInput: Bool,
        supportsResize: Bool,
        supportsRename: Bool,
        supportsClose: Bool
    ) {
        self.supportsInput = supportsInput
        self.supportsResize = supportsResize
        self.supportsRename = supportsRename
        self.supportsClose = supportsClose
    }

    public static let managed = SessionCapabilities(
        supportsInput: true,
        supportsResize: true,
        supportsRename: true,
        supportsClose: true
    )

    public static let readOnlyPreview = SessionCapabilities(
        supportsInput: false,
        supportsResize: false,
        supportsRename: false,
        supportsClose: false
    )
}

public struct SessionSummary: Codable, Equatable, Sendable {
    public var id: SessionID
    public var title: String
    public var shellPath: String
    public var workingDirectory: String
    public var state: SessionState
    public var source: SessionSource
    public var capabilities: SessionCapabilities
    public var pid: Int32?
    public var size: SessionWindowSize
    public var createdAt: Date
    public var lastActivityAt: Date
    public var previewExcerpt: String

    public init(
        id: SessionID,
        title: String,
        shellPath: String,
        workingDirectory: String,
        state: SessionState,
        source: SessionSource = .managed,
        capabilities: SessionCapabilities = .managed,
        pid: Int32?,
        size: SessionWindowSize,
        createdAt: Date,
        lastActivityAt: Date,
        previewExcerpt: String
    ) {
        self.id = id
        self.title = title
        self.shellPath = shellPath
        self.workingDirectory = workingDirectory
        self.state = state
        self.source = source
        self.capabilities = capabilities
        self.pid = pid
        self.size = size
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
        self.previewExcerpt = previewExcerpt
    }

    public var isManaged: Bool {
        source == .managed
    }

    public var isReadOnlyPreview: Bool {
        capabilities.supportsInput == false &&
            capabilities.supportsResize == false &&
            capabilities.supportsRename == false &&
            capabilities.supportsClose == false
    }
}
