// Fusetta - an open source FUSE implementation for macOS on top of FSKit.
// Copyright (C) 2026 Håvard Sørbø <havard@hsorbo.no>
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

public final class FUSEConnection: @unchecked Sendable {
    public typealias NotificationHandler = @Sendable (FUSENotifyCode, [UInt8]) -> Void
    public typealias DisconnectHandler = @Sendable (Error?) -> Void

    private let fd: Int32
    private let lock = NSLock()
    private let writeLock = NSLock()
    private var pending: [UInt64: CheckedContinuation<[UInt8], Error>] = [:]
    private var nextUnique: UInt64 = 2
    private var closedError: Error?
    private var readerStarted = false

    private var notificationHandler: NotificationHandler?
    private var disconnectHandler: DisconnectHandler?

    public var trace: (@Sendable (String) -> Void)?

    public init(fd: Int32) {
        self.fd = fd
        SocketIO.setNoSigPipe(fd)
    }

    deinit {
        Darwin.close(fd)
    }

    public func setHandlers(notification: NotificationHandler?, disconnect: DisconnectHandler?) {
        lock.lock()
        notificationHandler = notification
        disconnectHandler = disconnect
        lock.unlock()
    }

    public func start() {
        lock.lock()
        if readerStarted {
            lock.unlock()
            return
        }
        readerStarted = true
        lock.unlock()
        let thread = Thread { [self] in readLoop() }
        thread.name = "fusetta.fuse-reader"
        thread.qualityOfService = .userInitiated
        thread.stackSize = 1 << 20
        thread.start()
    }

    public func close() {
        Darwin.shutdown(fd, SHUT_RDWR)
        fail(with: FUSEError.notConnected)
    }

    // MARK: Requests

    public func request(
        _ opcode: FUSEOpcode, nodeID: UInt64, caller: FUSECaller = .current,
        body: [UInt8] = [], payload: Data? = nil
    ) async throws -> [UInt8] {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[UInt8], Error>) in
            lock.lock()
            if let err = closedError {
                lock.unlock()
                cont.resume(throwing: err)
                return
            }
            let unique = nextUnique
            nextUnique += 2
            pending[unique] = cont
            lock.unlock()

            do {
                try send(opcode, unique: unique, nodeID: nodeID, caller: caller, body: body, payload: payload)
            } catch {
                lock.lock()
                let c = pending.removeValue(forKey: unique)
                lock.unlock()
                c?.resume(throwing: error)
            }
        }
    }

    /// For requests without a reply (FORGET, BATCH_FORGET).
    public func post(_ opcode: FUSEOpcode, nodeID: UInt64, body: [UInt8]) throws {
        lock.lock()
        if let err = closedError {
            lock.unlock()
            throw err
        }
        let unique = nextUnique
        nextUnique += 2
        lock.unlock()
        try send(opcode, unique: unique, nodeID: nodeID, caller: .current, body: body, payload: nil)
    }

    private func send(
        _ opcode: FUSEOpcode, unique: UInt64, nodeID: UInt64, caller: FUSECaller,
        body: [UInt8], payload: Data?
    ) throws {
        let total = FUSEConstants.inHeaderSize + body.count + (payload?.count ?? 0)
        guard total <= UInt32.max else { throw FUSEError(EFBIG) }
        var h = ByteWriter(capacity: FUSEConstants.inHeaderSize)
        h.u32(UInt32(total))
        h.u32(opcode.rawValue)
        h.u64(unique)
        h.u64(nodeID)
        h.u32(caller.uid)
        h.u32(caller.gid)
        h.u32(0)  // pid
        h.u32(0)  // total_extlen + padding
        trace?("-> \(opcode) unique=\(unique) node=\(nodeID) len=\(total)")

        writeLock.lock()
        defer { writeLock.unlock() }
        try h.bytes.withUnsafeBytes { hp in
            try body.withUnsafeBytes { bp in
                if let payload {
                    try payload.withUnsafeBytes { try SocketIO.writeAllv(fd, [hp, bp, $0]) }
                } else {
                    try SocketIO.writeAllv(fd, [hp, bp])
                }
            }
        }
    }

    // MARK: Reader

    private func readLoop() {
        var header = [UInt8](repeating: 0, count: FUSEConstants.outHeaderSize)
        var failure: Error?
        while true {
            do {
                let ok = try header.withUnsafeMutableBytes {
                    try SocketIO.readExact(fd, $0.baseAddress!, FUSEConstants.outHeaderSize)
                }
                if !ok { break }
                var r = ByteReader(header)
                let len = Int(try r.u32())
                let error = try r.i32()
                let unique = try r.u64()
                guard len >= FUSEConstants.outHeaderSize, len <= 64 * 1024 * 1024 else {
                    throw FUSEError.protocolError
                }
                var body = [UInt8](repeating: 0, count: len - FUSEConstants.outHeaderSize)
                if !body.isEmpty {
                    let ok = try body.withUnsafeMutableBytes {
                        try SocketIO.readExact(fd, $0.baseAddress!, $0.count)
                    }
                    if !ok { throw FUSEError(ECONNRESET) }
                }
                dispatch(unique: unique, error: error, body: body)
            } catch {
                failure = error
                break
            }
        }
        fail(with: failure ?? FUSEError.notConnected)
    }

    private func dispatch(unique: UInt64, error: Int32, body: [UInt8]) {
        if unique == 0 {
            lock.lock()
            let handler = notificationHandler
            lock.unlock()
            if let code = FUSENotifyCode(rawValue: error) {
                trace?("<- notify \(code) len=\(body.count)")
                handler?(code, body)
            }
            return
        }
        lock.lock()
        let cont = pending.removeValue(forKey: unique)
        lock.unlock()
        trace?("<- unique=\(unique) error=\(error) len=\(body.count)")
        guard let cont else { return }
        if error < 0 {
            cont.resume(throwing: FUSEError(-error))
        } else if error > 0 {
            cont.resume(throwing: FUSEError.protocolError)
        } else {
            cont.resume(returning: body)
        }
    }

    private func fail(with error: Error) {
        lock.lock()
        let first = closedError == nil
        if first { closedError = error }
        let waiting = pending
        pending.removeAll()
        let handler = first ? disconnectHandler : nil
        lock.unlock()
        for (_, c) in waiting { c.resume(throwing: FUSEError.notConnected) }
        handler?(error)
    }
}
