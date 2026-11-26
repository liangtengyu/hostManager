import Foundation
import HostManagerCore
import Security

/// The app's way of changing the hosts file.
///
/// One password prompt per launch: once the user approves, the shell helper described in
/// `HelperScript` is started as root and stays connected over an inherited pipe until the app
/// exits. Nothing is installed and no process outlives the app.
///
/// If such a session cannot be opened, writes fall back to `osascript`, at the cost of one
/// prompt per write. With `requiresAuthorization` off (development against a scratch file)
/// the same helper runs as the current user.
final class PrivilegedSession: @unchecked Sendable {
    typealias Handler = (Result<Void, PrivilegeError>) -> Void

    private struct Connection {
        /// The helper's stdout and stdin, as seen from this process.
        let readFD: Int32
        let writeFD: Int32
    }

    private enum Mode {
        case privileged(AuthorizationHandle)
        case unprivileged
    }

    private let mode: Mode
    private let hostsPath: String
    /// Receives a line for each step, so a failed elevation can be understood afterwards.
    private let log: (String) -> Void
    /// Everything below runs on this one queue, so requests are serialized and a write issued
    /// while the password prompt is still up simply waits its turn.
    private let queue = DispatchQueue(label: "dev.hostmanager.privileged", qos: .userInitiated)

    private var connection: Connection?
    private var process: Process?
    private var isStarted = false
    private var usesOneShotWrites = false

    init(hostsPath: String, requiresAuthorization: Bool, log: @escaping (String) -> Void = { _ in }) {
        self.hostsPath = hostsPath
        self.log = log
        self.mode = requiresAuthorization ? .privileged(AuthorizationHandle()) : .unprivileged
    }

    // MARK: Lifecycle

    /// Asks for the admin password and opens the session. Calling it again is a no-op.
    func start(_ handler: @escaping Handler) {
        queue.async { [self] in
            if isStarted { return handler(.success(())) }
            log("start: opening the session")
            switch mode {
            case .unprivileged:
                do {
                    try spawnUnprivileged()
                    log("start: helper running without elevation")
                    isStarted = true
                    handler(.success(()))
                } catch let error as PrivilegeError {
                    handler(.failure(error))
                } catch {
                    handler(.failure(.helperUnavailable))
                }
            case .privileged(let authorization):
                if authorization.isExecuteAvailable {
                    switch authorization.obtainRight() {
                    case errAuthorizationSuccess:
                        break
                    case errAuthorizationCanceled:
                        log("start: password prompt cancelled")
                        return handler(.failure(.canceled))
                    case let status:
                        log("start: AuthorizationCopyRights failed with \(status)")
                        return handler(.failure(.authorizationFailed(status)))
                    }
                    log("start: password accepted")
                    do {
                        try spawnPrivileged(authorization)
                        isStarted = true
                        return handler(.success(()))
                    } catch PrivilegeError.canceled {
                        log("start: launch cancelled")
                        return handler(.failure(.canceled))
                    } catch PrivilegeError.authorizationFailed(let status) {
                        log("start: authorization failed with \(status)")
                        return handler(.failure(.authorizationFailed(status)))
                    } catch {
                        log("start: AuthorizationExecuteWithPrivileges session failed (\(error)); trying osascript session")
                    }
                } else {
                    log("start: AuthorizationExecuteWithPrivileges unavailable; using osascript session")
                }

                do {
                    try spawnViaAppleScriptSession()
                    isStarted = true
                    handler(.success(()))
                } catch PrivilegeError.canceled {
                    log("start: osascript session prompt cancelled")
                    handler(.failure(.canceled))
                } catch {
                    // Neither persistent channel could be opened on this system.
                    // One prompt per write beats refusing to work at all.
                    log("start: no persistent session could be opened (\(error)); falling back to one prompt per write")
                    usesOneShotWrites = true
                    isStarted = true
                    handler(.success(()))
                }
            }
        }
    }

    /// Closes whatever is open and asks for the password again.
    func restart(_ handler: @escaping Handler) {
        queue.async { [self] in
            closeConnection()
            isStarted = false
            usesOneShotWrites = false
            start(handler)
        }
    }

    func shutdown() {
        queue.sync {
            if let connection {
                try? writeAll(Data((HelperProtocol.quitCommand + "\n").utf8), to: connection.writeFD)
            }
            closeConnection()
            isStarted = false
            if case .privileged(let authorization) = mode {
                authorization.release()
            }
        }
    }

    // MARK: Requests

    func writeHosts(_ data: Data, handler: @escaping Handler) {
        queue.async { [self] in
            guard isStarted else { return handler(.failure(.notRunning)) }
            guard data.count <= HelperScript.maximumBytes else { return handler(.failure(.payloadTooLarge)) }
            if usesOneShotWrites { return oneShotWrite(data, handler: handler) }

            let result = send(HelperProtocol.writeCommand(byteCount: data.count), payload: data)
            switch result {
            case .success(.wrote(let count)) where count == data.count:
                handler(.success(()))
            case .success(.error(let reason)):
                handler(.failure(.rejected(reason)))
            case .success:
                handler(.failure(.helperUnavailable))
            case .failure(let error):
                handler(.failure(error))
            }
        }
    }

    func flushDNS(handler: @escaping Handler) {
        queue.async { [self] in
            guard isStarted else { return handler(.success(())) }
            guard !usesOneShotWrites else {
                // The full flush needs root and would cost a second prompt; clear what can be
                // cleared as the user.
                _ = run("/usr/bin/dscacheutil", ["-flushcache"])
                return handler(.success(()))
            }
            switch send(HelperProtocol.flushCommand) {
            case .success(.flushed): handler(.success(()))
            case .success: handler(.failure(.helperUnavailable))
            case .failure(let error): handler(.failure(error))
            }
        }
    }

    // MARK: Opening a session

    private func spawnPrivileged(_ authorization: AuthorizationHandle) throws {
        let descriptor = try authorization.launch("/bin/sh", arguments: HelperScript.arguments(hostsPath: hostsPath))
        do {
            try greet(read: descriptor, write: descriptor)
            log("start: helper running as root and answering")
        } catch {
            log("start: helper did not answer (\(error))")
            throw error
        }
    }

    /// Fallback persistent root session over a pair of private FIFOs launched once through
    /// `osascript`. The FIFOs and their `0o700` directory are unlinked as soon as the helper
    /// connects, so nothing stays on disk and closing the write descriptor still ends the helper.
    private func spawnViaAppleScriptSession() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("hostmanager-session-\(UUID().uuidString)")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: directory) }

        let inputFIFO = directory.appendingPathComponent("in.fifo").path
        let outputFIFO = directory.appendingPathComponent("out.fifo").path
        guard mkfifo(inputFIFO, 0o600) == 0, mkfifo(outputFIFO, 0o600) == 0 else {
            throw PrivilegeError.helperUnavailable
        }

        // Open the read side first (non-blocking) so the helper's `> out.fifo` never blocks once
        // the write side of `in.fifo` is opened.
        let readFD = open(outputFIFO, O_RDONLY | O_NONBLOCK)
        guard readFD >= 0 else { throw PrivilegeError.helperUnavailable }

        let command = HelperScript.detachedSessionCommand(
            hostsPath: hostsPath, inputFIFO: inputFIFO, outputFIFO: outputFIFO
        )
        guard let (status, output) = run("/usr/bin/osascript", ["-e", HelperScript.appleScript(forShellCommand: command, privileged: true)]) else {
            close(readFD)
            throw PrivilegeError.helperUnavailable
        }
        guard status == 0 else {
            close(readFD)
            if output.contains("-128") || output.localizedCaseInsensitiveContains("cancel") {
                throw PrivilegeError.canceled
            }
            throw PrivilegeError.helperUnavailable
        }

        // Wait briefly for the background root helper to open `in.fifo` for reading.
        var writeFD: Int32 = -1
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            writeFD = open(inputFIFO, O_WRONLY | O_NONBLOCK)
            if writeFD >= 0 { break }
            if errno != ENXIO && errno != EINTR { break }
            usleep(20_000)
        }
        guard writeFD >= 0 else {
            close(readFD)
            throw PrivilegeError.helperUnavailable
        }

        for fd in [readFD, writeFD] {
            let flags = fcntl(fd, F_GETFL)
            if flags >= 0 {
                _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
            }
        }

        do {
            try greet(read: readFD, write: writeFD)
            log("start: osascript helper running as root and answering")
        } catch {
            log("start: osascript helper did not answer (\(error))")
            throw error
        }
    }

    private func spawnUnprivileged() throws {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = HelperScript.arguments(hostsPath: hostsPath)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process

        let readFD = dup(output.fileHandleForReading.fileDescriptor)
        let writeFD = dup(input.fileHandleForWriting.fileDescriptor)
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
        guard readFD >= 0, writeFD >= 0 else {
            if readFD >= 0 { close(readFD) }
            if writeFD >= 0 { close(writeFD) }
            throw PrivilegeError.helperUnavailable
        }
        try greet(read: readFD, write: writeFD)
    }

    /// Waits for the helper's `READY` and checks that it answers, so a session is only
    /// reported open once it is known to work.
    private func greet(read: Int32, write: Int32) throws {
        guard (try? readLine(from: read, timeout: 5)) == "READY", send("PING", on: read, to: write) == .success(.pong) else {
            Self.closeDescriptors(read: read, write: write)
            throw PrivilegeError.helperUnavailable
        }
        connection = Connection(readFD: read, writeFD: write)
    }

    private func closeConnection() {
        if let connection {
            Self.closeDescriptors(read: connection.readFD, write: connection.writeFD)
            self.connection = nil
        }
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
    }

    private static func closeDescriptors(read: Int32, write: Int32) {
        close(read)
        if write != read {
            close(write)
        }
    }

    // MARK: Talking to the helper

    private func send(_ command: String, payload: Data? = nil) -> Result<HelperProtocol.Reply, PrivilegeError> {
        guard let connection else { return .failure(.notRunning) }
        return send(command, payload: payload, on: connection.readFD, to: connection.writeFD)
    }

    private func send(_ command: String, payload: Data? = nil, on read: Int32, to write: Int32) -> Result<HelperProtocol.Reply, PrivilegeError> {
        do {
            try writeAll(Data((command + "\n").utf8), to: write)
            if let payload {
                try writeAll(payload, to: write)
            }
            let line = try readLine(from: read, timeout: payload == nil ? 15 : 120)
            return .success(HelperProtocol.parseReply(line))
        } catch let error as PrivilegeError {
            // A broken pipe means the helper is gone; nothing can be sent until it is restarted.
            log("send(\(command)) failed with \(error); closing session")
            closeConnection()
            isStarted = false
            return .failure(error)
        } catch {
            log("send(\(command)) failed with \(error); closing session")
            closeConnection()
            isStarted = false
            return .failure(.helperStopped)
        }
    }

    // MARK: Without a session

    private func oneShotWrite(_ data: Data, handler: Handler) {
        let payloadURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostmanager-\(UUID().uuidString).hosts")
        // Root reads the payload from this file, so keep it to its owner.
        guard FileManager.default.createFile(atPath: payloadURL.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            return handler(.failure(.rejected("PAYLOAD")))
        }
        defer { try? FileManager.default.removeItem(at: payloadURL) }

        let command = HelperScript.oneShotCommand(
            byteCount: data.count, payloadPath: payloadURL.path, hostsPath: hostsPath
        )
        guard let (status, output) = run("/usr/bin/osascript", ["-e", HelperScript.appleScript(forShellCommand: command, privileged: true)]) else {
            return handler(.failure(.helperUnavailable))
        }
        if output.contains("WROTE \(data.count)") {
            return handler(.success(()))
        }
        if status != 0, output.contains("-128") || output.localizedCaseInsensitiveContains("cancel") {
            return handler(.failure(.canceled))
        }
        handler(.failure(.rejected(output.trimmingCharacters(in: .whitespacesAndNewlines))))
    }

    private func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String)? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

// MARK: - Pipe I/O with deadlines

// Every read polls first. A blocking `read` would wait forever on a helper that has (quite
// correctly) nothing to say, and would take the app with it.

private func waitFor(_ fd: Int32, event: Int16, timeout: TimeInterval) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw PrivilegeError.timedOut }
        var descriptor = pollfd(fd: fd, events: event, revents: 0)
        let ready = poll(&descriptor, 1, Int32((remaining * 1000).rounded(.up)))
        if ready > 0 { return }
        if ready == 0 { throw PrivilegeError.timedOut }
        if errno != EINTR {
            throw PrivilegeError.helperStopped
        }
    }
}

private func writeAll(_ data: Data, to fd: Int32) throws {
    try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
        var offset = 0
        while offset < buffer.count {
            try waitFor(fd, event: Int16(POLLOUT), timeout: 30)
            let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
            if written > 0 {
                offset += written
            } else if written < 0 && errno != EINTR {
                throw PrivilegeError.helperStopped
            }
        }
    }
}

private func readLine(from fd: Int32, timeout: TimeInterval) throws -> String {
    var bytes: [UInt8] = []
    let deadline = Date().addingTimeInterval(timeout)
    while true {
        try waitFor(fd, event: Int16(POLLIN), timeout: deadline.timeIntervalSinceNow)
        var byte: UInt8 = 0
        let count = read(fd, &byte, 1)
        if count == 0 { throw PrivilegeError.helperStopped }
        if count < 0 {
            if errno == EINTR { continue }
            throw PrivilegeError.helperStopped
        }
        if byte == 0x0A { return String(decoding: bytes, as: UTF8.self) }
        guard bytes.count < 4096 else { throw PrivilegeError.helperUnavailable }
        bytes.append(byte)
    }
}
