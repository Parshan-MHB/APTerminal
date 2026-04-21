import Foundation
import APTerminalProtocol

public protocol HostSettingsStore: Sendable {
    func loadSettings() throws -> HostSettings
    func saveSettings(_ settings: HostSettings) throws
}

public final class FileHostSettingsStore: HostSettingsStore, @unchecked Sendable {
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(fileURL: URL) {
        self.fileURL = fileURL
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public static func defaultFileURL(appName: String = APTerminalConfiguration.appName) -> URL {
        APTerminalStoragePaths.hostSettingsFileURL(appName: appName)
    }

    public func loadSettings() throws -> HostSettings {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return HostSettings()
        }

        let data = try Data(contentsOf: fileURL)
        return try decoder.decode(HostSettings.self, from: data)
    }

    public func saveSettings(_ settings: HostSettings) throws {
        let data = try encoder.encode(settings)
        try ProtectedFileIO.write(data, to: fileURL)
    }
}
