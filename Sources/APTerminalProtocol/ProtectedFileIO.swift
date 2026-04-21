import Foundation

public enum ProtectedFileIO {
    private static let directoryPermissions = 0o700
    private static let filePermissions = 0o600

    public static func write(_ data: Data, to fileURL: URL) throws {
        try ensureParentDirectory(for: fileURL)
        try data.write(to: fileURL, options: .atomic)
        try applyPermissions(filePermissions, to: fileURL)
    }

    public static func append(_ data: Data, to fileURL: URL) throws {
        try ensureParentDirectory(for: fileURL)

        if FileManager.default.fileExists(atPath: fileURL.path) == false {
            let created = FileManager.default.createFile(atPath: fileURL.path, contents: data)
            guard created else {
                throw CocoaError(.fileWriteUnknown)
            }
            try applyPermissions(filePermissions, to: fileURL)
            return
        }

        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try applyPermissions(filePermissions, to: fileURL)
    }

    public static func ensureParentDirectory(for fileURL: URL) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try applyPermissions(directoryPermissions, to: directoryURL)
    }

    private static func applyPermissions(_ permissions: Int, to url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }
}
