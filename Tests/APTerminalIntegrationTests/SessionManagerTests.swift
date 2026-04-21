import Foundation
import XCTest
@testable import APTerminalCore
@testable import APTerminalProtocol

final class SessionManagerTests: XCTestCase {
    func testMultipleSessionsMaintainIndependentState() async throws {
        let manager = SessionManager()
        let first = try await manager.createSession(
            shellPath: nil,
            workingDirectory: nil,
            initialSize: .init(rows: 30, columns: 100)
        )
        let second = try await manager.createSession(
            shellPath: nil,
            workingDirectory: nil,
            initialSize: .init(rows: 40, columns: 132)
        )

        _ = try await manager.renameSession(id: second.id, title: "Second Session")
        try await manager.resizeSession(id: first.id, size: .init(rows: 50, columns: 140))

        let sessions = await manager.listSessions()
        let firstSummary = await manager.sessionSummary(id: first.id)
        let secondSummary = await manager.sessionSummary(id: second.id)

        XCTAssertEqual(sessions.count, 2)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(firstSummary?.size, .init(rows: 50, columns: 140))
        XCTAssertEqual(secondSummary?.size, .init(rows: 40, columns: 132))
        XCTAssertEqual(sessions.first(where: { $0.id == second.id })?.title, "Second Session")

        try await manager.closeSession(id: first.id)
        try await manager.closeSession(id: second.id)
    }

    func testResizeUpdatesSessionSummary() async throws {
        let manager = SessionManager()
        let session = try await manager.createSession(
            shellPath: nil,
            workingDirectory: nil,
            initialSize: .init(rows: 24, columns: 80)
        )

        try await manager.resizeSession(id: session.id, size: .init(rows: 40, columns: 132))
        let summary = await manager.sessionSummary(id: session.id)

        XCTAssertEqual(summary?.size, .init(rows: 40, columns: 132))

        try await manager.closeSession(id: session.id)
    }
}
