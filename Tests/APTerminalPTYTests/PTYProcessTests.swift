import Darwin
import Foundation
import XCTest
@testable import APTerminalPTY

final class PTYProcessTests: XCTestCase {
    func testProcessEmitsOutputAndInvokesExitOnce() async throws {
        let outputExpectation = expectation(description: "terminal output")
        outputExpectation.assertForOverFulfill = false
        let exitExpectation = expectation(description: "process exit")
        exitExpectation.assertForOverFulfill = true

        let state = PTYTestState()

        let process = PTYProcess(
            shellPath: "/bin/zsh",
            workingDirectory: NSTemporaryDirectory(),
            onOutput: { data in
                let rendered = state.appendOutput(data)

                if rendered.contains("apterminal-pty"), state.markOutputObserved() {
                    outputExpectation.fulfill()
                }
            },
            onExit: { status in
                state.recordExit(status)
                exitExpectation.fulfill()
            }
        )

        try process.start(rows: 24, columns: 80)
        defer { process.terminate(signal: SIGKILL) }

        try process.write(Data("print -r -- apterminal-pty\nexit\n".utf8))

        await fulfillment(of: [outputExpectation, exitExpectation], timeout: 10)

        let rendered = state.renderedOutput
        let statuses = state.exitStatuses
        XCTAssertTrue(rendered.contains("apterminal-pty"))
        XCTAssertEqual(statuses.count, 1)
        XCTAssertEqual(statuses.first, 0)
    }

    func testResizeUpdatesWindowSize() async throws {
        let exitExpectation = expectation(description: "process exit")
        exitExpectation.assertForOverFulfill = true

        let process = PTYProcess(
            shellPath: "/bin/zsh",
            workingDirectory: NSTemporaryDirectory(),
            onOutput: { _ in },
            onExit: { _ in
                exitExpectation.fulfill()
            }
        )

        try process.start(rows: 24, columns: 80)
        defer { process.terminate(signal: SIGKILL) }

        try process.resize(rows: 48, columns: 132)

        var windowSize = winsize()
        XCTAssertEqual(ioctl(process.masterFileDescriptor, TIOCGWINSZ, &windowSize), 0)
        XCTAssertEqual(windowSize.ws_row, 48)
        XCTAssertEqual(windowSize.ws_col, 132)

        process.terminate(signal: SIGTERM)
        await fulfillment(of: [exitExpectation], timeout: 10)
    }

    func testTerminateKillsChildProcess() async throws {
        let exitExpectation = expectation(description: "process exit")
        exitExpectation.assertForOverFulfill = true

        let process = PTYProcess(
            shellPath: "/bin/zsh",
            workingDirectory: NSTemporaryDirectory(),
            onOutput: { _ in },
            onExit: { _ in
                exitExpectation.fulfill()
            }
        )

        try process.start(rows: 24, columns: 80)
        guard let childPID = process.pid else {
            XCTFail("Expected child process identifier")
            return
        }

        let didExit = process.terminate(signal: SIGTERM, gracePeriod: 0.5, killTimeout: 1.5)

        XCTAssertTrue(didExit)
        XCTAssertFalse(Self.processExists(pid: childPID))
        await fulfillment(of: [exitExpectation], timeout: 10)
    }

    private static func processExists(pid: pid_t) -> Bool {
        Darwin.kill(pid, 0) == 0
    }
}

private final class PTYTestState: @unchecked Sendable {
    private let lock = NSLock()
    private var output = Data()
    private var statuses: [Int32] = []
    private var didObserveOutput = false

    func appendOutput(_ data: Data) -> String {
        lock.lock()
        defer { lock.unlock() }
        output.append(data)
        return String(decoding: output, as: UTF8.self)
    }

    func recordExit(_ status: Int32) {
        lock.lock()
        defer { lock.unlock() }
        statuses.append(status)
    }

    func markOutputObserved() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard didObserveOutput == false else {
            return false
        }
        didObserveOutput = true
        return true
    }

    var renderedOutput: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: output, as: UTF8.self)
    }

    var exitStatuses: [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return statuses
    }
}
