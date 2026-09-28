// Fusetta - an open source FUSE implementation for macOS on top of FSKit.
// Copyright (C) 2026 Håvard Sørbø <havard@hsorbo.no>
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

public final class FUSESession: @unchecked Sendable {
    public let connection: FUSEConnection
    private var _initOut: FUSEInitOut?
    public var initOut: FUSEInitOut? { stateLock.withLock { _initOut } }

    private let stateLock = NSLock()
    private var unsupported: Set<UInt32> = []
    private var initTask: Task<FUSEInitOut, Error>?

    public init(connection: FUSEConnection) {
        self.connection = connection
    }

    public var maxWrite: Int {
        guard let o = initOut else { return 4096 }
        return max(4096, Int(o.maxWrite))
    }

    public var maxRead: Int { max(maxWrite, 128 * 1024) }

    public var setxattrExt: Bool {
        initOut?.flags.contains(.setxattrExt) ?? false
    }

    public var supportsReaddirplus: Bool {
        initOut?.flags.contains(.doReaddirplus) ?? false
    }

    /// FUSE semantics: an opcode that answered ENOSYS is never sent again.
    public func isUnsupported(_ op: FUSEOpcode) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return unsupported.contains(op.rawValue)
    }

    private func markUnsupported(_ op: FUSEOpcode) {
        stateLock.lock()
        unsupported.insert(op.rawValue)
        stateLock.unlock()
    }

    public var isReady: Bool { initOut != nil }

    private func call(
        _ op: FUSEOpcode, _ nodeID: UInt64, _ caller: FUSECaller, _ body: [UInt8] = [],
        payload: Data? = nil
    ) async throws -> [UInt8] {
        if isUnsupported(op) { throw FUSEError.notSupported }
        try await initialize()
        do {
            return try await connection.request(op, nodeID: nodeID, caller: caller, body: body, payload: payload)
        } catch let e as FUSEError where e.errno == ENOSYS {
            markUnsupported(op)
            throw e
        }
    }

    // MARK: Lifecycle

    /// Sends FUSE_INIT once. Like the Linux kernel, the volume can be mounted
    /// before the file system answers: requests wait here until it does.
    @discardableResult
    public func initialize() async throws -> FUSEInitOut {
        let task = stateLock.withLock {
            if initTask == nil { initTask = Task { try await self.sendInit() } }
            return initTask!
        }
        return try await task.value
    }

    private func sendInit() async throws -> FUSEInitOut {
        var w = ByteWriter()
        w.u32(FUSEConstants.kernelVersion)
        w.u32(FUSEConstants.kernelMinorVersion)
        w.u32(1 << 20)  // max_readahead
        let want: FUSEInitFlags = [
            .asyncRead, .bigWrites, .dontMask, .doReaddirplus, .readdirplusAuto,
            .parallelDirops, .maxPages, .autoInvalData, .setxattrExt,
        ]
        w.u32(want.rawValue)
        let reply = try await connection.request(.initialize, nodeID: 0, body: w.bytes)
        var r = ByteReader(reply)
        let out = try FUSEInitOut.decode(&r)
        guard out.major == FUSEConstants.kernelVersion else { throw FUSEError.protocolError }
        stateLock.withLock { _initOut = out }
        return out
    }

    public func destroy() async {
        _ = try? await connection.request(.destroy, nodeID: 0)
    }

    // MARK: Namespace

    public func lookup(parent: UInt64, name: [UInt8], caller: FUSECaller = .current) async throws -> FUSEEntry {
        var w = ByteWriter()
        w.cString(name)
        let reply = try await call(.lookup, parent, caller, w.bytes)
        var r = ByteReader(reply)
        let entry = try FUSEEntry.decode(&r)
        // A zero nodeid is a negative entry.
        if entry.nodeID == 0 { throw FUSEError.noEntry }
        return entry
    }

    public func forget(nodeID: UInt64, nlookup: UInt64) {
        guard nlookup > 0, nodeID != FUSEConstants.rootID else { return }
        var w = ByteWriter()
        w.u64(nlookup)
        try? connection.post(.forget, nodeID: nodeID, body: w.bytes)
    }

    public func batchForget(_ items: [(nodeID: UInt64, nlookup: UInt64)]) {
        let items = items.filter { $0.nlookup > 0 && $0.nodeID != FUSEConstants.rootID }
        if items.isEmpty { return }
        if items.count == 1 || isUnsupported(.batchForget) {
            for i in items { forget(nodeID: i.nodeID, nlookup: i.nlookup) }
            return
        }
        for chunk in stride(from: 0, to: items.count, by: 512) {
            let slice = items[chunk..<min(chunk + 512, items.count)]
            var w = ByteWriter(capacity: 8 + slice.count * 16)
            w.u32(UInt32(slice.count))
            w.u32(0)
            for i in slice {
                w.u64(i.nodeID)
                w.u64(i.nlookup)
            }
            try? connection.post(.batchForget, nodeID: 0, body: w.bytes)
        }
    }

    public func getattr(nodeID: UInt64, fh: UInt64? = nil, caller: FUSECaller = .current) async throws -> FUSEAttrOut {
        var w = ByteWriter()
        w.u32(fh != nil ? 1 : 0)  // FUSE_GETATTR_FH
        w.u32(0)
        w.u64(fh ?? 0)
        let reply = try await call(.getattr, nodeID, caller, w.bytes)
        var r = ByteReader(reply)
        return try FUSEAttrOut.decode(&r)
    }

    public func setattr(nodeID: UInt64, _ s: FUSESetattr, caller: FUSECaller = .current) async throws -> FUSEAttrOut {
        let reply = try await call(.setattr, nodeID, caller, s.encode())
        var r = ByteReader(reply)
        return try FUSEAttrOut.decode(&r)
    }

    public func readlink(nodeID: UInt64, caller: FUSECaller = .current) async throws -> [UInt8] {
        var target = try await call(.readlink, nodeID, caller)
        // Some file systems include the terminating NUL.
        if let nul = target.firstIndex(of: 0) { target.removeSubrange(nul...) }
        return target
    }

    public func symlink(parent: UInt64, name: [UInt8], target: [UInt8], caller: FUSECaller = .current) async throws -> FUSEEntry {
        var w = ByteWriter()
        w.cString(name)
        w.cString(target)
        let reply = try await call(.symlink, parent, caller, w.bytes)
        var r = ByteReader(reply)
        return try FUSEEntry.decode(&r)
    }

    public func mknod(parent: UInt64, name: [UInt8], mode: UInt32, caller: FUSECaller = .current) async throws -> FUSEEntry {
        var w = ByteWriter()
        w.u32(mode)
        w.u32(0)  // rdev
        w.u32(0)  // umask
        w.u32(0)
        w.cString(name)
        let reply = try await call(.mknod, parent, caller, w.bytes)
        var r = ByteReader(reply)
        return try FUSEEntry.decode(&r)
    }

    public func mkdir(parent: UInt64, name: [UInt8], mode: UInt32, caller: FUSECaller = .current) async throws -> FUSEEntry {
        var w = ByteWriter()
        w.u32(mode)
        w.u32(0)  // umask
        w.cString(name)
        let reply = try await call(.mkdir, parent, caller, w.bytes)
        var r = ByteReader(reply)
        return try FUSEEntry.decode(&r)
    }

    public func unlink(parent: UInt64, name: [UInt8], caller: FUSECaller = .current) async throws {
        var w = ByteWriter()
        w.cString(name)
        _ = try await call(.unlink, parent, caller, w.bytes)
    }

    public func rmdir(parent: UInt64, name: [UInt8], caller: FUSECaller = .current) async throws {
        var w = ByteWriter()
        w.cString(name)
        _ = try await call(.rmdir, parent, caller, w.bytes)
    }

    public func rename(parent: UInt64, name: [UInt8], newParent: UInt64, newName: [UInt8], caller: FUSECaller = .current) async throws {
        var w = ByteWriter()
        w.u64(newParent)
        w.cString(name)
        w.cString(newName)
        _ = try await call(.rename, parent, caller, w.bytes)
    }

    public func link(nodeID: UInt64, newParent: UInt64, newName: [UInt8], caller: FUSECaller = .current) async throws -> FUSEEntry {
        var w = ByteWriter()
        w.u64(nodeID)
        w.cString(newName)
        let reply = try await call(.link, newParent, caller, w.bytes)
        var r = ByteReader(reply)
        return try FUSEEntry.decode(&r)
    }

    // MARK: Files

    public func open(nodeID: UInt64, flags: Int32, caller: FUSECaller = .current) async throws -> FUSEOpenOut {
        var w = ByteWriter()
        w.i32(flags)
        w.u32(0)
        let reply = try await call(.open, nodeID, caller, w.bytes)
        var r = ByteReader(reply)
        return try FUSEOpenOut.decode(&r)
    }

    public func create(parent: UInt64, name: [UInt8], mode: UInt32, flags: Int32, caller: FUSECaller = .current) async throws -> (FUSEEntry, FUSEOpenOut) {
        var w = ByteWriter()
        w.i32(flags)
        w.u32(mode)
        w.u32(0)  // umask
        w.u32(0)
        w.cString(name)
        let reply = try await call(.create, parent, caller, w.bytes)
        var r = ByteReader(reply)
        let entry = try FUSEEntry.decode(&r)
        let open = try FUSEOpenOut.decode(&r)
        return (entry, open)
    }

    public func read(nodeID: UInt64, fh: UInt64, offset: UInt64, size: Int, caller: FUSECaller = .current) async throws -> [UInt8] {
        var w = ByteWriter()
        w.u64(fh)
        w.u64(offset)
        w.u32(UInt32(size))
        w.u32(0)  // read_flags
        w.u64(0)  // lock_owner
        w.u32(0)  // flags
        w.u32(0)
        return try await call(.read, nodeID, caller, w.bytes)
    }

    public func write(nodeID: UInt64, fh: UInt64, offset: UInt64, data: Data, caller: FUSECaller = .current) async throws -> Int {
        var w = ByteWriter()
        w.u64(fh)
        w.u64(offset)
        w.u32(UInt32(data.count))
        w.u32(0)  // write_flags
        w.u64(0)  // lock_owner
        w.u32(0)  // flags
        w.u32(0)
        let reply = try await call(.write, nodeID, caller, w.bytes, payload: data)
        var r = ByteReader(reply)
        return Int(try r.u32())
    }

    public func flush(nodeID: UInt64, fh: UInt64, caller: FUSECaller = .current) async throws {
        var w = ByteWriter()
        w.u64(fh)
        w.u32(0)
        w.u32(0)
        w.u64(0)
        // Like the Linux kernel: a file system without flush has nothing to flush.
        do { _ = try await call(.flush, nodeID, caller, w.bytes) } catch let e as FUSEError where e.errno == ENOSYS {}
    }

    public func release(nodeID: UInt64, fh: UInt64, flags: Int32, directory: Bool = false, caller: FUSECaller = .current) async throws {
        var w = ByteWriter()
        w.u64(fh)
        w.i32(flags)
        w.u32(0)  // release_flags
        w.u64(0)  // lock_owner
        do {
            _ = try await call(directory ? .releasedir : .release, nodeID, caller, w.bytes)
        } catch let e as FUSEError where e.errno == ENOSYS {}
    }

    public func fsync(nodeID: UInt64, fh: UInt64, caller: FUSECaller = .current) async throws {
        var w = ByteWriter()
        w.u64(fh)
        w.u32(0)  // fsync_flags
        w.u32(0)
        do {
            _ = try await call(.fsync, nodeID, caller, w.bytes)
        } catch let e as FUSEError where e.errno == ENOSYS {}
    }

    public func fallocate(nodeID: UInt64, fh: UInt64, offset: UInt64, length: UInt64, caller: FUSECaller = .current) async throws {
        var w = ByteWriter()
        w.u64(fh)
        w.u64(offset)
        w.u64(length)
        w.u32(0)  // mode
        w.u32(0)
        _ = try await call(.fallocate, nodeID, caller, w.bytes)
    }

    public func lseek(nodeID: UInt64, fh: UInt64, offset: UInt64, whence: Int32, caller: FUSECaller = .current) async throws -> UInt64 {
        var w = ByteWriter()
        w.u64(fh)
        w.u64(offset)
        w.i32(whence)
        w.u32(0)
        let reply = try await call(.lseek, nodeID, caller, w.bytes)
        var r = ByteReader(reply)
        return try r.u64()
    }

    // MARK: Directories

    public func opendir(nodeID: UInt64, caller: FUSECaller = .current) async throws -> FUSEOpenOut {
        var w = ByteWriter()
        w.i32(O_RDONLY)
        w.u32(0)
        let reply = try await call(.opendir, nodeID, caller, w.bytes)
        var r = ByteReader(reply)
        return try FUSEOpenOut.decode(&r)
    }

    public func readdir(nodeID: UInt64, fh: UInt64, offset: UInt64, size: Int = 64 * 1024, plus: Bool, caller: FUSECaller = .current) async throws -> [FUSEDirEntry] {
        var w = ByteWriter()
        w.u64(fh)
        w.u64(offset)
        w.u32(UInt32(size))
        w.u32(0)
        w.u64(0)
        w.u32(0)
        w.u32(0)
        let reply = try await call(plus ? .readdirplus : .readdir, nodeID, caller, w.bytes)
        return try FUSEDirEntry.decodeList(reply, plus: plus)
    }

    // MARK: Volume

    public func statfs(caller: FUSECaller = .current) async throws -> FUSEStatfs {
        let reply = try await call(.statfs, FUSEConstants.rootID, caller)
        var r = ByteReader(reply)
        return try FUSEStatfs.decode(&r)
    }

    public func access(nodeID: UInt64, mask: Int32, caller: FUSECaller = .current) async throws {
        var w = ByteWriter()
        w.i32(mask)
        w.u32(0)
        _ = try await call(.access, nodeID, caller, w.bytes)
    }

    // MARK: Extended attributes

    private func xattrHeader(size: UInt32, flags: UInt32?) -> ByteWriter {
        var w = ByteWriter()
        w.u32(size)
        w.u32(flags ?? 0)
        if flags != nil && setxattrExt {
            w.u32(0)  // setxattr_flags
            w.u32(0)
        }
        return w
    }

    public func getxattr(nodeID: UInt64, name: [UInt8], caller: FUSECaller = .current) async throws -> [UInt8] {
        var size: UInt32 = 64 * 1024
        for _ in 0..<3 {
            var w = xattrHeader(size: size, flags: nil)
            w.cString(name)
            do {
                return try await call(.getxattr, nodeID, caller, w.bytes)
            } catch let e as FUSEError where e.errno == ERANGE {
                var probe = xattrHeader(size: 0, flags: nil)
                probe.cString(name)
                let reply = try await call(.getxattr, nodeID, caller, probe.bytes)
                var r = ByteReader(reply)
                size = try r.u32()
            }
        }
        throw FUSEError(ERANGE)
    }

    public func listxattr(nodeID: UInt64, caller: FUSECaller = .current) async throws -> [[UInt8]] {
        var size: UInt32 = 64 * 1024
        var data: [UInt8] = []
        var done = false
        for _ in 0..<3 where !done {
            let w = xattrHeader(size: size, flags: nil)
            do {
                data = try await call(.listxattr, nodeID, caller, w.bytes)
                done = true
            } catch let e as FUSEError where e.errno == ERANGE {
                let reply = try await call(.listxattr, nodeID, caller, xattrHeader(size: 0, flags: nil).bytes)
                var r = ByteReader(reply)
                size = try r.u32()
            }
        }
        if !done { throw FUSEError(ERANGE) }
        return data.split(separator: 0, omittingEmptySubsequences: true).map(Array.init)
    }

    /// `flags` uses the Darwin XATTR_CREATE/XATTR_REPLACE values; they are
    /// passed straight to the file system's setxattr handler.
    public func setxattr(nodeID: UInt64, name: [UInt8], value: [UInt8], flags: Int32, caller: FUSECaller = .current) async throws {
        var w = xattrHeader(size: UInt32(value.count), flags: UInt32(bitPattern: flags))
        w.cString(name)
        w.raw(value)
        _ = try await call(.setxattr, nodeID, caller, w.bytes)
    }

    public func removexattr(nodeID: UInt64, name: [UInt8], caller: FUSECaller = .current) async throws {
        var w = ByteWriter()
        w.cString(name)
        _ = try await call(.removexattr, nodeID, caller, w.bytes)
    }
}
