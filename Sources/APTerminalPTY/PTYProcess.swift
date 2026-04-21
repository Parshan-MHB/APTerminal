import Dispatch
import Foundation
import Darwin

public enum PTYProcessError: Error, Equatable {
    case masterOpenFailed(Int32)
    case grantFailed(Int32)
    case unlockFailed(Int32)
    case slaveNameUnavailable
    case forkFailed(Int32)
    case childSetupFailed(String)
    case processNotRunning
    case writeFailed(Int32)
    case resizeFailed(Int32)
}

public final class PTYProcess: @unchecked Sendable {
    public let shellPath: String
    public let workingDirectory: String

    public private(set) var pid: pid_t?
    public private(set) var processGroupID: pid_t?
    public private(set) var masterFileDescriptor: Int32 = -1

    private let ioQueue: DispatchQueue
    private let stateLock = NSLock()
    private var readSource: DispatchSourceRead?
    private var isStarted = false
    private var process: Process?
    private var didNotifyExit = false

    private let onOutput: @Sendable (Data) -> Void
    private let onExit: @Sendable (Int32) -> Void

    public init(
        shellPath: String,
        workingDirectory: String,
        onOutput: @escaping @Sendable (Data) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) {
        self.shellPath = shellPath
        self.workingDirectory = workingDirectory
        self.onOutput = onOutput
        self.onExit = onExit
        self.ioQueue = DispatchQueue(label: "com.apterminal.pty.\(UUID().uuidString)")
    }

    deinit {
        shutdown()
    }

    public func start(rows: UInt16, columns: UInt16) throws {
        guard isStarted == false else {
            return
        }

        stateLock.lock()
        didNotifyExit = false
        stateLock.unlock()

        let masterFD = posix_openpt(O_RDWR | O_NOCTTY)

        guard masterFD >= 0 else {
            throw PTYProcessError.masterOpenFailed(errno)
        }

        guard grantpt(masterFD) == 0 else {
            let errorCode = errno
            close(masterFD)
            throw PTYProcessError.grantFailed(errorCode)
        }

        guard unlockpt(masterFD) == 0 else {
            let errorCode = errno
            close(masterFD)
            throw PTYProcessError.unlockFailed(errorCode)
        }

        guard let slaveNamePointer = ptsname(masterFD) else {
            close(masterFD)
            throw PTYProcessError.slaveNameUnavailable
        }

        let slavePath = String(cString: slaveNamePointer)
        let slaveFD = open(slavePath, O_RDWR)
        guard slaveFD >= 0 else {
            let errorCode = errno
            close(masterFD)
            throw PTYProcessError.childSetupFailed("open slave failed: \(errorCode)")
        }

        masterFileDescriptor = masterFD
        try resize(rows: rows, columns: columns)

        let slaveHandle = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-l"]
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle
        process.environment = mergedEnvironment()
        process.terminationHandler = { [weak self] process in
            self?.notifyExitAndShutdown(status: process.terminationStatus)
        }

        do {
            try process.run()
            // The child inherited the slave side during spawn. Keeping the parent's
            // copy open prevents clean EOF on the master side and leaves stale
            // /dev/ttys* descriptors visible in the app process.
            slaveHandle.closeFile()
        } catch {
            slaveHandle.closeFile()
            close(masterFD)
            throw PTYProcessError.childSetupFailed(error.localizedDescription)
        }

        self.process = process
        pid = process.processIdentifier
        if setpgid(process.processIdentifier, process.processIdentifier) == 0 {
            processGroupID = process.processIdentifier
        } else {
            processGroupID = nil
        }
        isStarted = true
        startReadLoop()
    }

    public func write(_ data: Data) throws {
        guard masterFileDescriptor >= 0 else {
            throw PTYProcessError.processNotRunning
        }

        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }

            var bytesRemaining = rawBuffer.count
            var pointer = baseAddress.assumingMemoryBound(to: UInt8.self)

            while bytesRemaining > 0 {
                let written = Darwin.write(masterFileDescriptor, pointer, bytesRemaining)

                if written < 0 {
                    if errno == EINTR {
                        continue
                    }

                    throw PTYProcessError.writeFailed(errno)
                }

                bytesRemaining -= written
                pointer = pointer.advanced(by: written)
            }
        }
    }

    public func resize(rows: UInt16, columns: UInt16) throws {
        guard masterFileDescriptor >= 0 else {
            throw PTYProcessError.processNotRunning
        }

        var windowSize = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        guard ioctl(masterFileDescriptor, TIOCSWINSZ, &windowSize) == 0 else {
            throw PTYProcessError.resizeFailed(errno)
        }
    }

    @discardableResult
    public func terminate(
        signal: Int32 = SIGTERM,
        gracePeriod: TimeInterval = PTYConfiguration.defaultTerminationGracePeriodSeconds,
        killTimeout: TimeInterval = PTYConfiguration.defaultTerminationKillTimeoutSeconds
    ) -> Bool {
        guard let processID = pid else {
            shutdown()
            return true
        }

        let groupID = processGroupID
        Self.send(signal: signal, to: processID, processGroupID: groupID)

        if Self.waitUntilExited(pid: processID, processGroupID: groupID, timeout: gracePeriod) {
            shutdown()
            return true
        }

        if signal != SIGKILL {
            Self.send(signal: SIGKILL, to: processID, processGroupID: groupID)
        }

        let didExit = Self.waitUntilExited(pid: processID, processGroupID: groupID, timeout: killTimeout)
        shutdown()
        return didExit
    }

    private func startReadLoop() {
        let source = DispatchSource.makeReadSource(fileDescriptor: masterFileDescriptor, queue: ioQueue)

        source.setEventHandler { [weak self] in
            self?.handleReadable()
        }

        source.resume()
        readSource = source
    }

    private func handleReadable() {
        var buffer = [UInt8](repeating: 0, count: 4096)

        while true {
            let bytesRead = Darwin.read(masterFileDescriptor, &buffer, buffer.count)

            if bytesRead > 0 {
                onOutput(Data(buffer.prefix(bytesRead)))
                continue
            }

            if bytesRead == 0 {
                if let process, process.isRunning {
                    readSource?.cancel()
                    readSource = nil
                    return
                }

                notifyExitAndShutdown(status: process?.terminationStatus ?? 0)
                return
            }

            if errno == EINTR {
                continue
            }

            if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            }

            if let process, process.isRunning {
                readSource?.cancel()
                readSource = nil
                return
            }

            notifyExitAndShutdown(status: process?.terminationStatus ?? 0)
            return
        }
    }

    private func notifyExitAndShutdown(status: Int32) {
        stateLock.lock()
        let shouldNotify = didNotifyExit == false
        if shouldNotify {
            didNotifyExit = true
        }
        stateLock.unlock()

        if shouldNotify {
            onExit(status)
        }
        shutdown()
    }

    private func shutdown() {
        readSource?.cancel()
        readSource = nil

        if masterFileDescriptor >= 0 {
            close(masterFileDescriptor)
            masterFileDescriptor = -1
        }

        pid = nil
        processGroupID = nil
        process = nil
        isStarted = false
    }

    private func mergedEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        return environment
    }

    private static func send(signal: Int32, to pid: pid_t, processGroupID: pid_t?) {
        if let processGroupID {
            _ = Darwin.kill(-processGroupID, signal)
        }
        _ = Darwin.kill(pid, signal)
    }

    private static func isAlive(pid: pid_t, processGroupID: pid_t?) -> Bool {
        if Darwin.kill(pid, 0) == 0 {
            return true
        }

        if let processGroupID, Darwin.kill(-processGroupID, 0) == 0 {
            return true
        }

        return false
    }

    private static func waitUntilExited(pid: pid_t, processGroupID: pid_t?, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if isAlive(pid: pid, processGroupID: processGroupID) == false {
                return true
            }

            usleep(PTYConfiguration.defaultReadRetrySleepMicroseconds)
        }

        return isAlive(pid: pid, processGroupID: processGroupID) == false
    }
}
