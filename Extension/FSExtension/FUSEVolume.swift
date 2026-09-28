// Fusetta - an open source FUSE implementation for macOS on top of FSKit.
// Copyright (C) 2026 Håvard Sørbø <havard@hsorbo.no>
// SPDX-License-Identifier: GPL-2.0-only

import FSKit
import FusettaCore
import os

let log = Logger(subsystem: "org.fusetta.fskit", category: "volume")

// Darwin values; the FUSE file system runs on Darwin and passes them to libc.
private let darwinXattrCreate: Int32 = 0x0002
private let darwinXattrReplace: Int32 = 0x0004
private let darwinSeekHole: Int32 = 3
private let darwinSeekData: Int32 = 4

final class FUSEVolume: FSVolume, @unchecked Sendable {
    let session: FUSESession
    let config: FusettaMountConfig

    /// Guards `nodes` and every node's `nlookup`. Lookups reply to FSKit while
    /// holding it so FSItem.tryReclaim sees a consistent count.
    private let tableLock = NSLock()
    private var nodes: [UInt64: FUSENode] = [:]
    private var root: FUSENode?
    private var rootIno: UInt64 = 1

    private let stateLock = NSLock()
    private var statfsCache = FUSEStatfs()
    private var statfsFetched = Date.distantPast
    private var statfsRefreshing = false
    private var nextVerifier: UInt64 = 1

    private var xattrUnsupported = false
    /// Hide and refuse AppleDouble ("._name") files. macOS stores extended
    /// attributes in them on file systems without xattr support, which
    /// litters the remote side (and breaks e.g. git repositories).
    private var denyAppleDouble = false
    /// FUSE_INIT, the root's attributes and feature probes. Like the Linux
    /// kernel we mount without waiting for the file system: libfuse only
    /// starts serving once fuse_session_mount() has returned, i.e. after
    /// mount(8) finished. Operations wait for this task instead.
    private var readiness: Task<Void, Never>?

    init(session: FUSESession, config: FusettaMountConfig, endpoint: FusettaEndpoint) {
        self.session = session
        self.config = config
        super.init(
            volumeID: FSVolume.Identifier(uuid: endpoint.volumeUUID),
            volumeName: FSFileName(string: config.effectiveVolumeName))
    }

    static func connect(endpoint: FusettaEndpoint) async throws -> FUSEVolume {
        let (fd, config) = try FusettaHandshake.connect(to: endpoint)
        let connection = FUSEConnection(fd: fd)
        let session = FUSESession(connection: connection)
        let volume = FUSEVolume(session: session, config: config, endpoint: endpoint)
        connection.setHandlers(
            notification: { [weak volume] code, body in volume?.handleNotification(code, body) },
            disconnect: { error in log.info("FUSE connection closed: \(String(describing: error), privacy: .public)") })
        if config.debug {
            connection.trace = { log.debug("\($0, privacy: .public)") }
        }
        connection.start()

        // Placeholder until the file system answers; FSKit needs a root item
        // to finish mounting.
        var rootAttr = FUSEAttr()
        rootAttr.ino = FUSEConstants.rootID
        rootAttr.mode = UInt32(S_IFDIR) | 0o755
        rootAttr.nlink = 2
        rootAttr.uid = getuid()
        rootAttr.gid = getgid()
        rootAttr.mtime = .now()
        rootAttr.ctime = rootAttr.mtime
        rootAttr.atime = rootAttr.mtime
        let root = FUSENode(nodeID: FUSEConstants.rootID, attr: rootAttr, parentFileID: FSItem.Identifier.parentOfRoot.rawValue)
        volume.root = root
        volume.nodes[FUSEConstants.rootID] = root
        volume.readiness = Task { await volume.prepare(root: root) }
        return volume
    }

    private func prepare(root: FUSENode) async {
        do {
            let initOut = try await session.initialize()
            log.info("FUSE_INIT: \(initOut.major).\(initOut.minor) max_write \(initOut.maxWrite)")
        } catch {
            log.error("FUSE_INIT failed: \(String(describing: error), privacy: .public)")
            return
        }
        if let attr = try? await session.getattr(nodeID: FUSEConstants.rootID).attr {
            stateLock.withLock { rootIno = attr.ino }
            root.update(attr: attr)
        }
        var noXattr = false
        do {
            _ = try await session.listxattr(nodeID: FUSEConstants.rootID)
        } catch let e as FUSEError where e.errno == ENOSYS {
            noXattr = true
        } catch {}
        let s = try? await session.statfs()
        stateLock.withLock {
            xattrUnsupported = noXattr
            denyAppleDouble = config.appleDouble.map { !$0 } ?? noXattr
            if let s {
                statfsCache = s
                statfsFetched = Date()
            }
        }
    }

    func ready(_ op: String = #function) async {
        if !session.isReady {
            log.notice("waiting for FUSE_INIT: \(op, privacy: .public)")
        }
        await readiness?.value
    }

    func shutdown() {
        session.connection.close()
    }

    // MARK: - Helpers

    func caller(_ context: FSContext?) -> FUSECaller {
        guard let context else { return .current }
        return FUSECaller(uid: UInt32(truncatingIfNeeded: context.effectiveUserID),
                          gid: UInt32(truncatingIfNeeded: context.effectiveGroupID))
    }

    /// FSKit reserves 0, 1 (parent of root) and 2 (root) as item identifiers.
    func fileID(ino: UInt64, isRoot: Bool = false) -> UInt64 {
        if isRoot || ino == stateLock.withLock({ rootIno }) { return FSItem.Identifier.rootDirectory.rawValue }
        if ino <= 2 { return ino | (1 << 63) }
        return ino
    }

    func fileID(of node: FUSENode) -> UInt64 {
        fileID(ino: node.cachedAttr.ino, isRoot: node.isRoot)
    }

    static func itemType(mode: UInt32) -> FSItem.ItemType {
        switch mode_t(truncatingIfNeeded: mode) & S_IFMT {
        case S_IFREG: return .file
        case S_IFDIR: return .directory
        case S_IFLNK: return .symlink
        case S_IFIFO: return .fifo
        case S_IFCHR: return .charDevice
        case S_IFBLK: return .blockDevice
        case S_IFSOCK: return .socket
        default: return .unknown
        }
    }

    static func itemType(direntType: UInt32) -> FSItem.ItemType {
        switch Int32(direntType) {
        case Int32(DT_REG): return .file
        case Int32(DT_DIR): return .directory
        case Int32(DT_LNK): return .symlink
        case Int32(DT_FIFO): return .fifo
        case Int32(DT_CHR): return .charDevice
        case Int32(DT_BLK): return .blockDevice
        case Int32(DT_SOCK): return .socket
        default: return .unknown
        }
    }

    func makeAttributes(_ a: FUSEAttr, fileID: UInt64, parentID: UInt64) -> FSItem.Attributes {
        let out = FSItem.Attributes()
        out.type = Self.itemType(mode: a.mode)
        out.mode = a.mode
        out.linkCount = a.nlink
        out.uid = a.uid
        out.gid = a.gid
        out.flags = 0
        out.size = a.size
        out.allocSize = a.blocks * 512
        out.fileID = FSItem.Identifier(fileID)
        out.parentID = FSItem.Identifier(parentID)
        out.accessTime = a.atime.timespecValue
        out.modifyTime = a.mtime.timespecValue
        out.changeTime = a.ctime.timespecValue
        out.birthTime = a.ctime.timespecValue  // FUSE_GETATTR has no birth time
        out.backupTime = timespec(tv_sec: 0, tv_nsec: 0)
        out.addedTime = a.ctime.timespecValue
        out.supportsLimitedXAttrs = false
        out.inhibitKernelOffloadedIO = true
        return out
    }

    func attributes(of node: FUSENode) -> FSItem.Attributes {
        let (attr, parent) = node.snapshot
        return makeAttributes(attr, fileID: fileID(ino: attr.ino, isRoot: node.isRoot), parentID: parent)
    }

    func refresh(_ node: FUSENode, caller: FUSECaller) async throws -> FSItem.Attributes {
        let fh = node.lock.withLock { node.handle?.fh }
        let out = try await session.getattr(nodeID: node.nodeID, fh: fh, caller: caller)
        node.update(attr: out.attr)
        return attributes(of: node)
    }

    static func nsError(_ error: Error) -> Error {
        if let e = error as? FUSEError { return fs_errorForPOSIXError(e.errno) }
        if let e = error as? HandshakeError { return fs_errorForPOSIXError(e.errno) }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain || ns.domain == FSKitErrorDomain { return error }
        return fs_errorForPOSIXError(EIO)
    }

    static func isAppleDouble(_ name: [UInt8]) -> Bool {
        name.count > 2 && name[0] == 0x2e && name[1] == 0x5f  // "._"
    }

    func hidden(_ name: [UInt8]) -> Bool {
        Self.isAppleDouble(name) && stateLock.withLock { denyAppleDouble }
    }

    /// Names we refuse to create. ENOTSUP (rather than EACCES) makes the
    /// kernel's AppleDouble fallback for setxattr fail with ENOTSUP, which
    /// copy tools treat as "this volume has no xattrs" and skip silently.
    func checkCreatable(_ name: FSFileName) throws {
        if hidden(Array(name.data)) {
            log.debug("refusing AppleDouble \(name.string ?? "?", privacy: .public)")
            throw FUSEError(ENOTSUP)
        }
    }

    static func node(_ item: FSItem) throws -> FUSENode {
        guard let node = item as? FUSENode else { throw FUSEError(EINVAL) }
        return node
    }

    func run<T>(_ reply: @escaping (T?, Error?) -> Void, op: String = #function, _ body: @escaping () async throws -> T) {
        Task {
            await ready(op)
            do {
                reply(try await body(), nil)
            } catch {
                reply(nil, Self.nsError(error))
            }
        }
    }

    func run(_ reply: @escaping (Error?) -> Void, op: String = #function, _ body: @escaping () async throws -> Void) {
        Task {
            await ready(op)
            do {
                try await body()
                reply(nil)
            } catch {
                reply(Self.nsError(error))
            }
        }
    }

    /// Registers a FUSE entry (one lookup reference) and replies while the
    /// table lock is held, so a concurrent reclaim cannot interleave.
    func register<R>(
        _ entry: FUSEEntry, parent: FUSENode,
        reply: (R?, Error?) -> Void,
        make: (FUSENode, FSItem.Attributes) -> R?
    ) {
        let parentID = fileID(of: parent)
        tableLock.lock()
        defer { tableLock.unlock() }
        let node: FUSENode
        if let existing = nodes[entry.nodeID] {
            node = existing
            node.update(attr: entry.attr, parentFileID: parentID)
        } else {
            node = FUSENode(nodeID: entry.nodeID, attr: entry.attr, parentFileID: parentID)
            nodes[entry.nodeID] = node
        }
        node.nlookup += 1
        if let result = make(node, attributes(of: node)) {
            reply(result, nil)
        } else {
            reply(nil, fs_errorForPOSIXError(EIO))
        }
    }

    /// Accounts for lookup references obtained outside a lookup (LINK,
    /// READDIRPLUS): keep them on a live node, otherwise give them back.
    func absorbLookups(_ entries: [FUSEEntry]) {
        var forgets: [(nodeID: UInt64, nlookup: UInt64)] = []
        tableLock.lock()
        for e in entries where e.nodeID != 0 {
            if let node = nodes[e.nodeID] {
                node.nlookup += 1
                node.update(attr: e.attr)
            } else {
                forgets.append((e.nodeID, 1))
            }
        }
        tableLock.unlock()
        session.batchForget(forgets)
    }

    private func updateStatfsIfStale() {
        stateLock.lock()
        let stale = Date().timeIntervalSince(statfsFetched) > 2 && !statfsRefreshing
        if stale { statfsRefreshing = true }
        stateLock.unlock()
        guard stale else { return }
        Task {
            let s = try? await session.statfs()
            stateLock.withLock {
                if let s { statfsCache = s }
                statfsFetched = Date()
                statfsRefreshing = false
            }
        }
    }

    private func handleNotification(_ code: FUSENotifyCode, _ body: [UInt8]) {
        // FSKit has no name-cache invalidation. Attribute changes surface on
        // the next getattr; data cache coherency is left to the kernel.
        log.debug("ignoring FUSE notification \(String(describing: code), privacy: .public)")
    }

    // MARK: - File handles

    /// Returns a handle usable for `modes`, opening (or widening) one if needed.
    func handle(for node: FUSENode, modes: FSVolume.OpenModes, caller: FUSECaller) async throws -> FUSEHandle {
        if let h = node.lock.withLock({ node.handle }), h.modes.isSuperset(of: modes) {
            return h
        }
        let current = node.lock.withLock { node.handle?.modes ?? [] }
        let wanted = current.union(modes)
        var attempts: [(Int32, FSVolume.OpenModes)] = []
        if wanted.contains(.write) {
            attempts.append((O_RDWR, [.read, .write]))
            if !wanted.contains(.read) { attempts.append((O_WRONLY, [.write])) }
        } else {
            attempts.append((O_RDONLY, [.read]))
        }
        var lastError: Error = FUSEError(EACCES)
        for (flags, granted) in attempts {
            do {
                let out = try await session.open(nodeID: node.nodeID, flags: flags, caller: caller)
                let h = FUSEHandle(fh: out.fh, modes: granted, flags: flags)
                node.lock.withLock {
                    if let old = node.handle { node.retiredHandles.append(old) }
                    node.handle = h
                }
                return h
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    func releaseHandles(_ handles: [FUSEHandle], of node: FUSENode, flush: Bool) async {
        for h in handles {
            if flush { try? await session.flush(nodeID: node.nodeID, fh: h.fh) }
            try? await session.release(nodeID: node.nodeID, fh: h.fh, flags: h.flags)
        }
    }
}

// MARK: - FSVolume.Handler

extension FUSEVolume: FSVolume.Handler {
    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let c = FSVolume.SupportedCapabilities()
        c.supportsSymbolicLinks = true
        c.supportsHardLinks = true
        c.supports64BitObjectIDs = true
        c.supportsHiddenFiles = false
        c.supports2TBFiles = true
        c.supportsFastStatFS = false
        c.doesNotSupportImmutableFiles = true
        c.caseFormat = .sensitive
        return c
    }

    var volumeStatistics: FSStatFSResult {
        updateStatfsIfStale()
        let s = stateLock.withLock { statfsCache }
        let r = FSStatFSResult(fileSystemTypeName: FusettaHandshake.fsShortName)
        let unit = s.blockUnit
        r.blockSize = Int(unit)
        r.ioSize = max(Int(unit), min(session.maxWrite, 1 << 20))
        r.totalBlocks = s.blocks
        r.freeBlocks = s.bfree
        r.availableBlocks = s.bavail
        r.usedBlocks = s.blocks >= s.bfree ? s.blocks - s.bfree : 0
        r.totalBytes = s.blocks * unit
        r.freeBytes = s.bfree * unit
        r.availableBytes = s.bavail * unit
        r.usedBytes = r.usedBlocks * unit
        r.totalFiles = s.files
        r.freeFiles = s.ffree
        return r
    }

    var maximumLinkCount: Int { Int(Int32.max) }
    var maximumNameLength: Int { Int(stateLock.withLock { statfsCache.namelen == 0 ? 255 : statfsCache.namelen }) }
    var restrictsOwnershipChanges: Bool { true }
    var truncatesLongNames: Bool { false }
    var maximumFileSize: UInt64 { UInt64(Int64.max) }
    /// _PC_XATTR_SIZE_BITS. 0 tells copy tools the volume keeps no extended
    /// attributes, so they skip them instead of failing or writing
    /// AppleDouble files; 64 means "no practical limit".
    var maximumXattrSizeInBits: Int { stateLock.withLock { xattrUnsupported } ? 0 : 64 }

    var requestedMountOptions: FSVolume.MountOptions { config.readOnly ? .readOnly : [] }

    func activateVolume(options: FSTaskOptions, replyHandler reply: @escaping @Sendable (FSActivateResult?, (any Error)?) -> Void) {
        guard let root, let result = FSActivateResult(rootItem: root) else {
            reply(nil, fs_errorForPOSIXError(EIO))
            return
        }
        reply(result, nil)
    }

    func deactivateVolume(options: FSDeactivateOptions, replyHandler reply: @escaping @Sendable ((any Error)?) -> Void) {
        Task {
            await session.destroy()
            session.connection.close()
            reply(nil)
        }
    }

    func mount(options: FSTaskOptions, replyHandler reply: @escaping @Sendable ((any Error)?) -> Void) {
        reply(nil)
    }

    func unmount(replyHandler reply: @escaping @Sendable () -> Void) {
        reply()
    }

    func synchronize(flags: FSSyncFlags, replyHandler reply: @escaping @Sendable ((any Error)?) -> Void) {
        let open = tableLock.withLock { Array(nodes.values) }
        run(reply) { [self] in
            for node in open {
                guard let h = node.lock.withLock({ node.handle }), h.modes.contains(.write) else { continue }
                try? await session.fsync(nodeID: node.nodeID, fh: h.fh)
            }
        }
    }

    func lookupItem(named name: FSFileName, in directory: FSItem, context: FSContext, replyHandler reply: @escaping @Sendable (FSLookupItemResult?, (any Error)?) -> Void) {
        Task {
            await ready()
            do {
                let dir = try Self.node(directory)
                if hidden(Array(name.data)) { throw FUSEError.noEntry }
                let entry = try await session.lookup(parent: dir.nodeID, name: Array(name.data), caller: caller(context))
                register(entry, parent: dir, reply: reply) { node, attrs in
                    FSLookupItemResult(foundItem: node, itemName: name, itemAttributes: attrs)
                }
            } catch {
                reply(nil, Self.nsError(error))
            }
        }
    }

    func reclaimItem(_ item: FSItem, replyHandler reply: @escaping @Sendable ((any Error)?) -> Void) {
        guard let node = item as? FUSENode, !node.isRoot else {
            reply(nil)
            return
        }
        var count: UInt64 = 0
        tableLock.lock()
        let reclaimed = item.tryReclaim { [self] in
            if nodes[node.nodeID] === node { nodes.removeValue(forKey: node.nodeID) }
            count = node.nlookup
            node.nlookup = 0
        }
        tableLock.unlock()
        guard reclaimed else {
            reply(nil)
            return
        }
        let handles = node.takeAllHandles()
        let streams = node.takeAllDirStreams()
        Task {
            await releaseHandles(handles, of: node, flush: false)
            for fh in streams {
                try? await session.release(nodeID: node.nodeID, fh: fh, flags: O_RDONLY, directory: true)
            }
            session.forget(nodeID: node.nodeID, nlookup: count)
        }
        reply(nil)
    }

    func createItem(named name: FSFileName, type: FSItem.ItemType, in directory: FSItem, attributes newAttributes: FSItem.SetAttributesRequest, context: FSContext, replyHandler reply: @escaping @Sendable (FSCreateItemResult?, (any Error)?) -> Void) {
        Task {
            await ready()
            do {
                let dir = try Self.node(directory)
                try checkCreatable(name)
                let c = caller(context)
                let bytes = Array(name.data)
                var perm = newAttributes.isValid(.mode) ? newAttributes.mode & 0o7777 : 0
                if perm == 0 && !newAttributes.isValid(.mode) { perm = type == .directory ? 0o755 : 0o644 }
                var entry: FUSEEntry
                var created: FUSEOpenOut?
                switch type {
                case .directory:
                    entry = try await session.mkdir(parent: dir.nodeID, name: bytes, mode: perm, caller: c)
                case .file:
                    if session.isUnsupported(.create) {
                        entry = try await session.mknod(parent: dir.nodeID, name: bytes, mode: UInt32(S_IFREG) | perm, caller: c)
                    } else {
                        do {
                            (entry, created) = try await session.create(
                                parent: dir.nodeID, name: bytes, mode: UInt32(S_IFREG) | perm,
                                flags: O_RDWR | O_CREAT | O_EXCL, caller: c)
                        } catch let e as FUSEError where e.errno == ENOSYS {
                            entry = try await session.mknod(parent: dir.nodeID, name: bytes, mode: UInt32(S_IFREG) | perm, caller: c)
                        }
                    }
                case .fifo, .socket, .charDevice, .blockDevice:
                    let kind: mode_t = [.fifo: S_IFIFO, .socket: S_IFSOCK, .charDevice: S_IFCHR, .blockDevice: S_IFBLK][type]!
                    entry = try await session.mknod(parent: dir.nodeID, name: bytes, mode: UInt32(kind) | perm, caller: c)
                default:
                    throw FUSEError(EINVAL)
                }
                let dirAttrs = try await refresh(dir, caller: c)
                register(entry, parent: dir, reply: reply) { node, attrs in
                    if let open = created {
                        node.lock.withLock {
                            if node.handle == nil {
                                node.handle = FUSEHandle(fh: open.fh, modes: [.read, .write], flags: O_RDWR)
                                created = nil
                            }
                        }
                    }
                    return FSCreateItemResult(newItem: node, newItemName: name, newItemAttributes: attrs, directoryAttributes: dirAttrs, freeSpace: nil)
                }
                if let created {
                    try? await session.release(nodeID: entry.nodeID, fh: created.fh, flags: O_RDWR, caller: c)
                }
            } catch {
                reply(nil, Self.nsError(error))
            }
        }
    }

    func createSymbolicLink(named name: FSFileName, in directory: FSItem, attributes newAttributes: FSItem.SetAttributesRequest, linkContents contents: FSFileName, context: FSContext, replyHandler reply: @escaping @Sendable (FSCreateSymlinkResult?, (any Error)?) -> Void) {
        Task {
            await ready()
            do {
                let dir = try Self.node(directory)
                try checkCreatable(name)
                let c = caller(context)
                let entry = try await session.symlink(parent: dir.nodeID, name: Array(name.data), target: Array(contents.data), caller: c)
                let dirAttrs = try await refresh(dir, caller: c)
                register(entry, parent: dir, reply: reply) { node, attrs in
                    FSCreateSymlinkResult(newItem: node, newItemName: name, newItemAttributes: attrs, directoryAttributes: dirAttrs, freeSpace: nil)
                }
            } catch {
                reply(nil, Self.nsError(error))
            }
        }
    }

    func createLink(to item: FSItem, named name: FSFileName, in directory: FSItem, context: FSContext, replyHandler reply: @escaping @Sendable (FSCreateLinkResult?, (any Error)?) -> Void) {
        run(reply) { [self] in
            let node = try Self.node(item)
            let dir = try Self.node(directory)
            try checkCreatable(name)
            let c = caller(context)
            let entry = try await session.link(nodeID: node.nodeID, newParent: dir.nodeID, newName: Array(name.data), caller: c)
            absorbLookups([entry])
            node.update(attr: entry.attr)
            let dirAttrs = try await refresh(dir, caller: c)
            guard let r = FSCreateLinkResult(linkName: name, linkAttributes: attributes(of: node), directoryAttributes: dirAttrs, freeSpace: nil) else {
                throw FUSEError.io
            }
            return r
        }
    }

    func renameItem(_ item: FSItem, inDirectory sourceDirectory: FSItem, named sourceName: FSFileName, to destinationName: FSFileName, inDirectory destinationDirectory: FSItem, overItem: FSItem?, context: FSContext, replyHandler reply: @escaping @Sendable (FSRenameItemResult?, (any Error)?) -> Void) {
        run(reply) { [self] in
            let node = try Self.node(item)
            let src = try Self.node(sourceDirectory)
            let dst = try Self.node(destinationDirectory)
            try checkCreatable(destinationName)
            let c = caller(context)
            try await session.rename(parent: src.nodeID, name: Array(sourceName.data), newParent: dst.nodeID, newName: Array(destinationName.data), caller: c)
            let srcAttrs = try await refresh(src, caller: c)
            let dstAttrs = src === dst ? srcAttrs : try await refresh(dst, caller: c)
            node.update(attr: node.cachedAttr, parentFileID: fileID(of: dst))
            let itemAttrs = (try? await refresh(node, caller: c)) ?? attributes(of: node)
            var overAttrs: FSItem.Attributes?
            if let over = overItem as? FUSENode {
                overAttrs = try? await refresh(over, caller: c)
                if overAttrs == nil {
                    over.modifyAttr { $0.nlink = $0.nlink > 0 ? $0.nlink - 1 : 0 }
                    overAttrs = attributes(of: over)
                }
            }
            guard let r = FSRenameItemResult(newName: destinationName, renamedItemAttributes: itemAttrs, sourceDirectoryAttributes: srcAttrs, destinationDirectoryAttributes: dstAttrs, overItemAttributes: overAttrs, freeSpace: nil) else {
                throw FUSEError.io
            }
            return r
        }
    }

    func removeItem(_ item: FSItem, named name: FSFileName, from directory: FSItem, context: FSContext, replyHandler reply: @escaping @Sendable (FSRemoveItemResult?, (any Error)?) -> Void) {
        run(reply) { [self] in
            let node = try Self.node(item)
            let dir = try Self.node(directory)
            let c = caller(context)
            if node.isDirectory {
                try await session.rmdir(parent: dir.nodeID, name: Array(name.data), caller: c)
                node.modifyAttr { $0.nlink = 0 }
            } else {
                try await session.unlink(parent: dir.nodeID, name: Array(name.data), caller: c)
                if (try? await refresh(node, caller: c)) == nil {
                    node.modifyAttr { $0.nlink = $0.nlink > 0 ? $0.nlink - 1 : 0 }
                }
            }
            let dirAttrs = try await refresh(dir, caller: c)
            guard let r = FSRemoveItemResult(itemAttributes: attributes(of: node), directoryAttributes: dirAttrs, freeSpace: nil) else {
                throw FUSEError.io
            }
            return r
        }
    }

    func getAttributes(_ desiredAttributes: FSItem.GetAttributesRequest, of item: FSItem, context: FSContext, replyHandler reply: @escaping @Sendable (FSGetAttributesResult?, (any Error)?) -> Void) {
        if let node = item as? FUSENode, node.isRoot, !session.isReady {
            // Asked while mounting, before libfuse serves requests.
            reply(FSGetAttributesResult(attributes: attributes(of: node)), nil)
            return
        }
        run(reply) { [self] in
            let node = try Self.node(item)
            let attrs = try await refresh(node, caller: caller(context))
            guard let r = FSGetAttributesResult(attributes: attrs) else { throw FUSEError.io }
            return r
        }
    }

    func setAttributes(_ newAttributes: FSItem.SetAttributesRequest, on item: FSItem, context: FSContext, replyHandler reply: @escaping @Sendable (FSSetAttributesResult?, (any Error)?) -> Void) {
        run(reply) { [self] in
            let node = try Self.node(item)
            let c = caller(context)
            let current = node.cachedAttr
            var s = FUSESetattr()
            var consumed: FSItem.Attribute = []
            func time(_ t: timespec) -> FUSETime { FUSETime(seconds: Int64(t.tv_sec), nanoseconds: UInt32(t.tv_nsec)) }

            if newAttributes.isValid(.mode) {
                s.valid.insert(.mode)
                s.mode = (current.mode & UInt32(S_IFMT)) | (newAttributes.mode & 0o7777)
                consumed.insert(.mode)
            }
            if newAttributes.isValid(.uid) {
                s.valid.insert(.uid); s.uid = newAttributes.uid; consumed.insert(.uid)
            }
            if newAttributes.isValid(.gid) {
                s.valid.insert(.gid); s.gid = newAttributes.gid; consumed.insert(.gid)
            }
            if newAttributes.isValid(.size) {
                s.valid.insert(.size); s.size = newAttributes.size; consumed.insert(.size)
                if let h = node.lock.withLock({ node.handle }), h.modes.contains(.write) {
                    s.valid.insert(.fh); s.fh = h.fh
                }
            }
            if newAttributes.isValid(.accessTime) {
                s.valid.insert(.atime); s.atime = time(newAttributes.accessTime); consumed.insert(.accessTime)
            }
            if newAttributes.isValid(.modifyTime) {
                s.valid.insert(.mtime); s.mtime = time(newAttributes.modifyTime); consumed.insert(.modifyTime)
            }
            if newAttributes.isValid(.changeTime) {
                s.valid.insert(.ctime); s.ctime = time(newAttributes.changeTime); consumed.insert(.changeTime)
            }
            // Birth time, backup time and BSD flags have no FUSE equivalent.

            let attrs: FSItem.Attributes
            if s.valid.isEmpty {
                attrs = try await refresh(node, caller: c)
            } else {
                let out = try await session.setattr(nodeID: node.nodeID, s, caller: c)
                node.update(attr: out.attr)
                attrs = attributes(of: node)
            }
            newAttributes.consumedAttributes = consumed
            guard let r = FSSetAttributesResult(attributes: attrs, freeSpace: nil) else { throw FUSEError.io }
            return r
        }
    }

    func enumerateDirectory(_ directory: FSItem, startingAt cookie: FSDirectoryCookie, verifier: FSDirectoryVerifier, attributes: FSItem.GetAttributesRequest?, packer: FSDirectoryEntryPacker, context: FSContext, replyHandler reply: @escaping @Sendable (FSEnumerateDirectoryResult?, (any Error)?) -> Void) {
        run(reply) { [self] in
            let dir = try Self.node(directory)
            let c = caller(context)
            let (stream, verifierValue) = try await dirStream(for: dir, cookie: cookie.rawValue, verifier: verifier.rawValue, caller: c)
            let wantAttrs = attributes != nil
            var plus = wantAttrs && session.supportsReaddirplus && !session.isUnsupported(.readdirplus)
            let dirFileID = fileID(of: dir)
            let parentFileID = dir.snapshot.parentFileID
            var offset = cookie.rawValue
            var keep: [FUSEEntry] = []
            var giveBack: [(nodeID: UInt64, nlookup: UInt64)] = []
            defer {
                if !keep.isEmpty { absorbLookups(keep) }
                session.batchForget(giveBack)
            }

            enumeration: while true {
                let entries: [FUSEDirEntry]
                do {
                    entries = try await session.readdir(nodeID: dir.nodeID, fh: stream, offset: offset, plus: plus, caller: c)
                } catch let e as FUSEError where e.errno == ENOSYS && plus {
                    plus = false  // fall back to READDIR + LOOKUP
                    continue enumeration
                }
                if entries.isEmpty {
                    closeDirStream(dir, verifier: verifierValue)
                    break
                }
                for var e in entries {
                    if hidden(e.name) {
                        if let entry = e.entry, entry.nodeID != 0 { giveBack.append((entry.nodeID, 1)) }
                        offset = e.nextOffset
                        continue
                    }
                    if e.isDotOrDotDot {
                        if wantAttrs {
                            offset = e.nextOffset
                            continue
                        }
                        let isDot = e.name.count == 1
                        let packed = packer.packEntry(
                            name: FSFileName(data: Data(e.name)), itemType: .directory,
                            itemID: FSItem.Identifier(isDot ? dirFileID : parentFileID),
                            nextCookie: FSDirectoryCookie(e.nextOffset), attributes: nil)
                        if !packed { break enumeration }
                        offset = e.nextOffset
                        continue
                    }
                    var type = Self.itemType(direntType: e.type)
                    // READDIRPLUS entries with nodeid 0 carry no attributes.
                    if (wantAttrs || type == .unknown) && (e.entry?.nodeID ?? 0) == 0 {
                        e.entry = try? await session.lookup(parent: dir.nodeID, name: e.name, caller: c)
                        if e.entry == nil {
                            // Vanished since READDIR.
                            offset = e.nextOffset
                            continue
                        }
                    }
                    var attrs: FSItem.Attributes?
                    var id = fileID(ino: e.ino)
                    if let entry = e.entry, entry.nodeID != 0 {
                        type = Self.itemType(mode: entry.attr.mode)
                        id = fileID(ino: entry.attr.ino)
                        if wantAttrs {
                            attrs = makeAttributes(entry.attr, fileID: id, parentID: dirFileID)
                        }
                    }
                    let packed = packer.packEntry(
                        name: FSFileName(data: Data(e.name)), itemType: type, itemID: FSItem.Identifier(id),
                        nextCookie: FSDirectoryCookie(e.nextOffset), attributes: attrs)
                    if let entry = e.entry, entry.nodeID != 0 {
                        if packed {
                            keep.append(entry)
                        } else {
                            giveBack.append((entry.nodeID, 1))
                        }
                    }
                    if !packed { break enumeration }
                    offset = e.nextOffset
                }
            }
            guard let r = FSEnumerateDirectoryResult(verifier: verifierValue) else { throw FUSEError.io }
            return r
        }
    }

    /// Finds or opens the FUSE directory handle backing an enumeration. A new
    /// enumeration (cookie 0) always gets a fresh OPENDIR, so file systems that
    /// snapshot the directory in opendir behave like on Linux.
    private func dirStream(for dir: FUSENode, cookie: UInt64, verifier: UInt64, caller: FUSECaller) async throws -> (fh: UInt64, verifier: UInt64) {
        if cookie != 0, let s = dir.lock.withLock({ dir.dirStreams.first { $0.verifier == verifier } }) {
            return (s.fh, s.verifier)
        }
        let out = try await session.opendir(nodeID: dir.nodeID, caller: caller)
        let v = stateLock.withLock { () -> UInt64 in
            defer { nextVerifier += 1 }
            return nextVerifier
        }
        let evicted: [UInt64] = dir.lock.withLock {
            dir.dirStreams.append((v, out.fh))
            // Bound the number of abandoned enumerations we keep open.
            guard dir.dirStreams.count > 8 else { return [] }
            let old = dir.dirStreams.prefix(dir.dirStreams.count - 8).map(\.fh)
            dir.dirStreams.removeFirst(dir.dirStreams.count - 8)
            return old
        }
        for fh in evicted {
            try? await session.release(nodeID: dir.nodeID, fh: fh, flags: O_RDONLY, directory: true, caller: caller)
        }
        return (out.fh, v)
    }

    private func closeDirStream(_ dir: FUSENode, verifier: UInt64) {
        let fh: UInt64? = dir.lock.withLock {
            guard let i = dir.dirStreams.firstIndex(where: { $0.verifier == verifier }) else { return nil }
            return dir.dirStreams.remove(at: i).fh
        }
        guard let fh else { return }
        Task { try? await session.release(nodeID: dir.nodeID, fh: fh, flags: O_RDONLY, directory: true) }
    }

    func readSymbolicLink(_ item: FSItem, context: FSContext, replyHandler reply: @escaping @Sendable (FSReadSymlinkResult?, (any Error)?) -> Void) {
        run(reply) { [self] in
            let node = try Self.node(item)
            let target = try await session.readlink(nodeID: node.nodeID, caller: caller(context))
            guard let r = FSReadSymlinkResult(contents: FSFileName(data: Data(target)), symlinkAttributes: attributes(of: node)) else {
                throw FUSEError.io
            }
            return r
        }
    }
}

// MARK: - Open / close

extension FUSEVolume: FSVolume.OpenCloseHandler {
    func openItem(_ item: FSItem, modes: FSVolume.OpenModes, context: FSContext, replyHandler reply: @escaping @Sendable ((any Error)?) -> Void) {
        run(reply) { [self] in
            let node = try Self.node(item)
            if node.isDirectory { return }
            _ = try await handle(for: node, modes: modes, caller: caller(context))
        }
    }

    func closeItem(_ item: FSItem, modes: FSVolume.OpenModes, context: FSContext, replyHandler reply: @escaping @Sendable ((any Error)?) -> Void) {
        run(reply) { [self] in
            let node = try Self.node(item)
            if node.isDirectory { return }
            if modes.isEmpty {
                await releaseHandles(node.takeAllHandles(), of: node, flush: true)
            } else if let h = node.lock.withLock({ node.handle }) {
                // A close(2) that is not the last: FUSE expects a FLUSH.
                try? await session.flush(nodeID: node.nodeID, fh: h.fh, caller: caller(context))
            }
        }
    }
}

// MARK: - Read / write

extension FUSEVolume: FSVolume.ReadWriteHandler {
    func read(from item: FSItem, at offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer, replyHandler reply: @escaping @Sendable (FSReadFileResult?, (any Error)?) -> Void) {
        run(reply) { [self] in
            let node = try Self.node(item)
            let h = try await handle(for: node, modes: .read, caller: .current)
            let want = min(length, buffer.length)
            var total = 0
            while total < want {
                let chunk = min(want - total, session.maxRead)
                let data = try await session.read(nodeID: node.nodeID, fh: h.fh, offset: UInt64(offset) + UInt64(total), size: chunk)
                let n = min(data.count, want - total)
                if n > 0 {
                    buffer.withUnsafeMutableBytes { dst in
                        data.withUnsafeBytes { src in
                            dst.baseAddress!.advanced(by: total).copyMemory(from: src.baseAddress!, byteCount: n)
                        }
                    }
                }
                total += n
                if data.count < chunk { break }  // EOF
            }
            guard let r = FSReadFileResult(bytesRead: total, itemAttributes: attributes(of: node)) else { throw FUSEError.io }
            return r
        }
    }

    func write(contents: Data, to item: FSItem, at offset: off_t, replyHandler reply: @escaping @Sendable (FSWriteFileResult?, (any Error)?) -> Void) {
        run(reply) { [self] in
            let node = try Self.node(item)
            let h = try await handle(for: node, modes: .write, caller: .current)
            let limit = session.maxWrite
            var total = 0
            while total < contents.count {
                let end = min(contents.count, total + limit)
                let slice = contents.subdata(in: (contents.startIndex + total)..<(contents.startIndex + end))
                let n = try await session.write(nodeID: node.nodeID, fh: h.fh, offset: UInt64(offset) + UInt64(total), data: slice)
                total += n
                if n < slice.count { break }
            }
            let written = total
            node.modifyAttr { a in
                a.size = max(a.size, UInt64(offset) + UInt64(written))
                a.mtime = .now()
                a.ctime = a.mtime
            }
            guard let r = FSWriteFileResult(bytesWritten: written, itemAttributes: attributes(of: node), freeSpace: nil) else {
                throw FUSEError.io
            }
            return r
        }
    }
}

// MARK: - Extended attributes

extension FUSEVolume: FSVolume.XattrHandler {
    private static func xattrError(_ error: Error, _ op: String = #function) -> Error {
        log.debug("xattr \(op, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        if let e = error as? FUSEError, e.errno == ENOSYS { return FUSEError(ENOTSUP) }
        return error
    }

    func getXattr(named name: FSFileName, of item: FSItem, context: FSContext, replyHandler reply: @escaping @Sendable (FSGetXattrResult?, (any Error)?) -> Void) {
        run(reply) { [self] in
            let node = try Self.node(item)
            do {
                let value = try await session.getxattr(nodeID: node.nodeID, name: Array(name.data), caller: caller(context))
                guard let r = FSGetXattrResult(xattrValue: Data(value)) else { throw FUSEError.io }
                return r
            } catch {
                throw Self.xattrError(error)
            }
        }
    }

    func setXattr(named name: FSFileName, to value: Data?, on item: FSItem, policy: FSVolume.SetXattrPolicy, context: FSContext, replyHandler reply: @escaping @Sendable (FSSetXattrResult?, (any Error)?) -> Void) {
        run(reply) { [self] in
            let node = try Self.node(item)
            let c = caller(context)
            // macOS tags nearly every file a process writes with
            // com.apple.provenance. Without xattr support in the file system
            // every copy would fail over it (the kernel's AppleDouble fallback
            // is refused), so drop that one system attribute silently.
            if stateLock.withLock({ xattrUnsupported }), name.string == "com.apple.provenance" {
                guard let r = FSSetXattrResult(freeSpace: nil) else { throw FUSEError.io }
                return r
            }
            do {
                switch policy {
                case .delete:
                    try await session.removexattr(nodeID: node.nodeID, name: Array(name.data), caller: c)
                default:
                    let flags: Int32 = policy == .mustCreate ? darwinXattrCreate : policy == .mustReplace ? darwinXattrReplace : 0
                    try await session.setxattr(nodeID: node.nodeID, name: Array(name.data), value: value.map(Array.init) ?? [], flags: flags, caller: c)
                }
            } catch {
                throw Self.xattrError(error)
            }
            guard let r = FSSetXattrResult(freeSpace: nil) else { throw FUSEError.io }
            return r
        }
    }

    func listXattrs(of item: FSItem, context: FSContext, replyHandler reply: @escaping @Sendable (FSListXattrsResult?, (any Error)?) -> Void) {
        run(reply) { [self] in
            let node = try Self.node(item)
            do {
                let names = try await session.listxattr(nodeID: node.nodeID, caller: caller(context))
                guard let r = FSListXattrsResult(xattrNames: names.map { FSFileName(data: Data($0)) }) else { throw FUSEError.io }
                return r
            } catch {
                throw Self.xattrError(error)
            }
        }
    }
}

// MARK: - Access checks

extension FUSEVolume: FSVolume.AccessCheckHandler {
    func checkAccess(to theItem: FSItem, requestedAccess access: FSVolume.AccessMask, context: FSContext, replyHandler reply: @escaping @Sendable (FSCheckAccessResult?, (any Error)?) -> Void) {
        if let node = theItem as? FUSENode, node.isRoot, !session.isReady {
            // mount(8) checks the root while mounting, before libfuse serves
            // requests; the file system's own checks apply once it does.
            reply(FSCheckAccessResult(accessAllowed: true), nil)
            return
        }
        run(reply) { [self] in
            let node = try Self.node(theItem)
            var mask: Int32 = 0
            let readBits: FSVolume.AccessMask = [.readData, .listDirectory, .readAttributes, .readXattr, .readSecurity]
            let writeBits: FSVolume.AccessMask = [.writeData, .addFile, .addSubdirectory, .appendData, .delete, .deleteChild, .writeAttributes, .writeXattr, .writeSecurity, .takeOwnership]
            let execBits: FSVolume.AccessMask = [.execute, .search]
            if !access.isDisjoint(with: readBits) { mask |= R_OK }
            if !access.isDisjoint(with: writeBits) { mask |= W_OK }
            if !access.isDisjoint(with: execBits) { mask |= X_OK }
            var allowed = true
            do {
                try await session.access(nodeID: node.nodeID, mask: mask, caller: caller(context))
            } catch let e as FUSEError where e.errno == EACCES || e.errno == EPERM || e.errno == EROFS {
                allowed = false
            } catch let e as FUSEError where e.errno == ENOSYS {
                allowed = true
            }
            guard let r = FSCheckAccessResult(accessAllowed: allowed) else { throw FUSEError.io }
            return r
        }
    }
}

// MARK: - Preallocation and holes

extension FUSEVolume: FSVolume.PreallocateHandler {
    func preallocateSpace(for item: FSItem, at offset: off_t, length: Int, flags: FSVolume.PreallocateFlags, context: FSContext, replyHandler reply: @escaping @Sendable (FSPreallocateResult?, (any Error)?) -> Void) {
        run(reply) { [self] in
            let node = try Self.node(item)
            let c = caller(context)
            let h = try await handle(for: node, modes: .write, caller: c)
            let start = flags.contains(.fromEOF) ? node.cachedAttr.size : UInt64(max(offset, 0))
            do {
                try await session.fallocate(nodeID: node.nodeID, fh: h.fh, offset: start, length: UInt64(length), caller: c)
            } catch let e as FUSEError where e.errno == ENOSYS {
                throw FUSEError(ENOTSUP)
            }
            let attrs = (try? await refresh(node, caller: c)) ?? attributes(of: node)
            guard let r = FSPreallocateResult(bytesAllocated: length, itemAttributes: attrs, freeSpace: nil) else { throw FUSEError.io }
            return r
        }
    }
}

extension FUSEVolume: FSVolume.SeekRegionHandler {
    func seek(within item: FSItem, from offset: off_t, region: FSVolume.SeekRegion, context: FSContext, replyHandler reply: @escaping @Sendable (FSSeekRegionResult?, (any Error)?) -> Void) {
        run(reply) { [self] in
            let node = try Self.node(item)
            let c = caller(context)
            let size = node.cachedAttr.size
            if !session.isUnsupported(.lseek) {
                do {
                    let h = try await handle(for: node, modes: .read, caller: c)
                    let whence = region == .hole ? darwinSeekHole : darwinSeekData
                    let result = try await session.lseek(nodeID: node.nodeID, fh: h.fh, offset: UInt64(max(offset, 0)), whence: whence, caller: c)
                    return FSSeekRegionResult(returnedOffset: off_t(result))
                } catch let e as FUSEError where e.errno == ENOSYS {}
            }
            // No lseek support: the file is one data region followed by EOF.
            if UInt64(max(offset, 0)) >= size { throw FUSEError(ENXIO) }
            return FSSeekRegionResult(returnedOffset: region == .hole ? off_t(size) : offset)
        }
    }
}
