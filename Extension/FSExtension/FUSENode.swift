// Fusetta - an open source FUSE implementation for macOS on top of FSKit.
// Copyright (C) 2026 Håvard Sørbø <havard@hsorbo.no>
// SPDX-License-Identifier: GPL-2.0-only

import FSKit
import FusettaCore

struct FUSEHandle {
    var fh: UInt64
    var modes: FSVolume.OpenModes
    var flags: Int32
}

final class FUSENode: FSItem, @unchecked Sendable {
    let nodeID: UInt64

    /// Guarded by FUSEVolume.tableLock: the number of FUSE lookups this node
    /// owes a FORGET for.
    var nlookup: UInt64 = 0

    /// Everything below is guarded by `lock`.
    let lock = NSLock()
    private(set) var attr: FUSEAttr
    private(set) var parentFileID: UInt64
    /// The handle used for I/O, and handles replaced by a wider one that are
    /// released on the final close (in-flight I/O may still use them).
    var handle: FUSEHandle?
    var retiredHandles: [FUSEHandle] = []
    /// Directory streams keyed by the verifier we handed to FSKit.
    var dirStreams: [(verifier: UInt64, fh: UInt64)] = []

    init(nodeID: UInt64, attr: FUSEAttr, parentFileID: UInt64) {
        self.nodeID = nodeID
        self.attr = attr
        self.parentFileID = parentFileID
        super.init()
    }

    var isRoot: Bool { nodeID == FUSEConstants.rootID }

    var snapshot: (attr: FUSEAttr, parentFileID: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        return (attr, parentFileID)
    }

    var cachedAttr: FUSEAttr { snapshot.attr }

    var isDirectory: Bool { cachedAttr.isDirectory }

    func update(attr: FUSEAttr, parentFileID: UInt64? = nil) {
        lock.lock()
        self.attr = attr
        if let parentFileID { self.parentFileID = parentFileID }
        lock.unlock()
    }

    func modifyAttr(_ body: (inout FUSEAttr) -> Void) {
        lock.lock()
        body(&attr)
        lock.unlock()
    }

    func takeAllHandles() -> [FUSEHandle] {
        lock.lock()
        defer { lock.unlock() }
        var all = retiredHandles
        if let handle { all.append(handle) }
        handle = nil
        retiredHandles = []
        return all
    }

    func takeAllDirStreams() -> [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        let all = dirStreams.map(\.fh)
        dirStreams = []
        return all
    }
}
