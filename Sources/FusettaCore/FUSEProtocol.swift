// Fusetta - an open source FUSE implementation for macOS on top of FSKit.
// Copyright (C) 2026 Håvard Sørbø <havard@hsorbo.no>
// SPDX-License-Identifier: GPL-2.0-only
//
// FUSE wire protocol definitions. Opcodes, flags and structure layouts follow
// <linux/fuse.h> (fuse_kernel.h) as spoken by upstream libfuse 3.

import Foundation

public enum FUSEOpcode: UInt32, Sendable {
    case lookup = 1
    case forget = 2
    case getattr = 3
    case setattr = 4
    case readlink = 5
    case symlink = 6
    case mknod = 8
    case mkdir = 9
    case unlink = 10
    case rmdir = 11
    case rename = 12
    case link = 13
    case open = 14
    case read = 15
    case write = 16
    case statfs = 17
    case release = 18
    case fsync = 20
    case setxattr = 21
    case getxattr = 22
    case listxattr = 23
    case removexattr = 24
    case flush = 25
    case initialize = 26
    case opendir = 27
    case readdir = 28
    case releasedir = 29
    case access = 34
    case create = 35
    case destroy = 38
    case batchForget = 42
    case fallocate = 43
    case readdirplus = 44
    case lseek = 46
}

/// Notification codes (fs -> kernel messages with unique == 0).
public enum FUSENotifyCode: Int32, Sendable {
    case poll = 1
    case invalInode = 2
    case invalEntry = 3
    case store = 4
    case retrieve = 5
    case delete = 6
}

public enum FUSEConstants {
    public static let kernelVersion: UInt32 = 7
    /// The minor version we announce. 7.31 keeps every structure at its
    /// "classic" size (no extended init or extension headers).
    public static let kernelMinorVersion: UInt32 = 31
    public static let rootID: UInt64 = 1

    public static let inHeaderSize = 40
    public static let outHeaderSize = 16
}

public struct FUSEInitFlags: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let asyncRead = FUSEInitFlags(rawValue: 1 << 0)
    public static let bigWrites = FUSEInitFlags(rawValue: 1 << 5)
    public static let dontMask = FUSEInitFlags(rawValue: 1 << 6)
    public static let autoInvalData = FUSEInitFlags(rawValue: 1 << 12)
    public static let doReaddirplus = FUSEInitFlags(rawValue: 1 << 13)
    public static let readdirplusAuto = FUSEInitFlags(rawValue: 1 << 14)
    public static let parallelDirops = FUSEInitFlags(rawValue: 1 << 18)
    public static let maxPages = FUSEInitFlags(rawValue: 1 << 22)
    /// fuse_setxattr_in carries setxattr_flags (16 bytes).
    public static let setxattrExt = FUSEInitFlags(rawValue: 1 << 29)
}

/// FATTR_* bits.
public struct FUSESetattrValid: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let mode = FUSESetattrValid(rawValue: 1 << 0)
    public static let uid = FUSESetattrValid(rawValue: 1 << 1)
    public static let gid = FUSESetattrValid(rawValue: 1 << 2)
    public static let size = FUSESetattrValid(rawValue: 1 << 3)
    public static let atime = FUSESetattrValid(rawValue: 1 << 4)
    public static let mtime = FUSESetattrValid(rawValue: 1 << 5)
    public static let fh = FUSESetattrValid(rawValue: 1 << 6)
    public static let ctime = FUSESetattrValid(rawValue: 1 << 10)
}

/// FOPEN_* flags returned by OPEN/CREATE/OPENDIR.
public struct FUSEOpenFlags: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let directIO = FUSEOpenFlags(rawValue: 1 << 0)
}

// MARK: - Errors

public struct FUSEError: Error, CustomStringConvertible, Sendable, Equatable {
    public let errno: Int32
    public init(_ errno: Int32) { self.errno = errno }
    public var description: String { "FUSE error \(errno) (\(String(cString: strerror(errno))))" }

    public static let noEntry = FUSEError(ENOENT)
    public static let io = FUSEError(EIO)
    public static let notConnected = FUSEError(ENOTCONN)
    public static let notSupported = FUSEError(ENOSYS)
    public static let protocolError = FUSEError(EPROTO)
}

// MARK: - Byte encoding

public struct ByteWriter: Sendable {
    public private(set) var bytes: [UInt8] = []

    public init(capacity: Int = 64) { bytes.reserveCapacity(capacity) }

    public mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { bytes.append(contentsOf: $0) } }
    public mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { bytes.append(contentsOf: $0) } }
    public mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { bytes.append(contentsOf: $0) } }
    public mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
    public mutating func i64(_ v: Int64) { u64(UInt64(bitPattern: v)) }
    public mutating func zeros(_ n: Int) { bytes.append(contentsOf: repeatElement(0, count: n)) }
    public mutating func raw<C: Collection>(_ c: C) where C.Element == UInt8 { bytes.append(contentsOf: c) }
    public mutating func cString<C: Collection>(_ c: C) where C.Element == UInt8 {
        bytes.append(contentsOf: c)
        bytes.append(0)
    }
    public mutating func pad(to alignment: Int) {
        let rem = bytes.count % alignment
        if rem != 0 { zeros(alignment - rem) }
    }
}

public struct ByteReader {
    public let bytes: [UInt8]
    public private(set) var offset: Int

    public init(_ bytes: [UInt8]) {
        self.bytes = bytes
        self.offset = 0
    }

    public var remaining: Int { bytes.count - offset }

    public mutating func need(_ n: Int) throws {
        if remaining < n { throw FUSEError.protocolError }
    }

    public mutating func u16() throws -> UInt16 {
        try need(2)
        defer { offset += 2 }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    public mutating func u32() throws -> UInt32 {
        try need(4)
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(bytes[offset + i]) << (8 * UInt32(i)) }
        offset += 4
        return v
    }

    public mutating func u64() throws -> UInt64 {
        try need(8)
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(bytes[offset + i]) << (8 * UInt64(i)) }
        offset += 8
        return v
    }

    public mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }
    public mutating func i64() throws -> Int64 { Int64(bitPattern: try u64()) }

    public mutating func skip(_ n: Int) throws {
        try need(n)
        offset += n
    }

    public mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
        try need(n)
        defer { offset += n }
        return bytes[offset..<(offset + n)]
    }
}

// MARK: - Decoded structures

public struct FUSETime: Sendable, Equatable {
    public var seconds: Int64
    public var nanoseconds: UInt32
    public init(seconds: Int64, nanoseconds: UInt32) {
        self.seconds = seconds
        self.nanoseconds = nanoseconds
    }
    public static let zero = FUSETime(seconds: 0, nanoseconds: 0)
    public static func now() -> FUSETime {
        var ts = Darwin.timespec()
        clock_gettime(CLOCK_REALTIME, &ts)
        return FUSETime(seconds: Int64(ts.tv_sec), nanoseconds: UInt32(ts.tv_nsec))
    }
    public var timespecValue: timespec { timespec(tv_sec: Int(seconds), tv_nsec: Int(nanoseconds)) }
}

/// struct fuse_attr.
public struct FUSEAttr: Sendable, Equatable {
    public var ino: UInt64 = 0
    public var size: UInt64 = 0
    public var blocks: UInt64 = 0
    public var atime: FUSETime = .zero
    public var mtime: FUSETime = .zero
    public var ctime: FUSETime = .zero
    public var mode: UInt32 = 0
    public var nlink: UInt32 = 0
    public var uid: UInt32 = 0
    public var gid: UInt32 = 0
    public var rdev: UInt32 = 0
    public var blksize: UInt32 = 0

    public init() {}

    public var fileType: UInt32 { mode & UInt32(S_IFMT) }
    public var isDirectory: Bool { fileType == UInt32(S_IFDIR) }

    static func decode(_ r: inout ByteReader) throws -> FUSEAttr {
        var a = FUSEAttr()
        a.ino = try r.u64()
        a.size = try r.u64()
        a.blocks = try r.u64()
        let atime = try r.i64(), mtime = try r.i64(), ctime = try r.i64()
        let atimensec = try r.u32(), mtimensec = try r.u32(), ctimensec = try r.u32()
        a.atime = FUSETime(seconds: atime, nanoseconds: atimensec)
        a.mtime = FUSETime(seconds: mtime, nanoseconds: mtimensec)
        a.ctime = FUSETime(seconds: ctime, nanoseconds: ctimensec)
        a.mode = try r.u32()
        a.nlink = try r.u32()
        a.uid = try r.u32()
        a.gid = try r.u32()
        a.rdev = try r.u32()
        a.blksize = try r.u32()
        try r.skip(4)  // fuse_attr.flags (FUSE_ATTR_*)
        return a
    }

    /// Only used by tests.
    public func encode(_ w: inout ByteWriter) {
        w.u64(ino); w.u64(size); w.u64(blocks)
        w.i64(atime.seconds); w.i64(mtime.seconds); w.i64(ctime.seconds)
        w.u32(atime.nanoseconds); w.u32(mtime.nanoseconds); w.u32(ctime.nanoseconds)
        w.u32(mode); w.u32(nlink); w.u32(uid); w.u32(gid); w.u32(rdev)
        w.u32(blksize); w.u32(0)
    }
}

/// struct fuse_entry_out.
public struct FUSEEntry: Sendable, Equatable {
    public var nodeID: UInt64
    public var generation: UInt64
    public var entryValid: Double
    public var attrValid: Double
    public var attr: FUSEAttr

    static func decode(_ r: inout ByteReader) throws -> FUSEEntry {
        let nodeID = try r.u64()
        let generation = try r.u64()
        let entryValid = try r.u64()
        let attrValid = try r.u64()
        let entryValidNsec = try r.u32()
        let attrValidNsec = try r.u32()
        let attr = try FUSEAttr.decode(&r)
        return FUSEEntry(
            nodeID: nodeID, generation: generation,
            entryValid: Double(entryValid) + Double(entryValidNsec) / 1e9,
            attrValid: Double(attrValid) + Double(attrValidNsec) / 1e9,
            attr: attr)
    }
}

/// struct fuse_attr_out.
public struct FUSEAttrOut: Sendable, Equatable {
    public var attrValid: Double
    public var attr: FUSEAttr

    static func decode(_ r: inout ByteReader) throws -> FUSEAttrOut {
        let valid = try r.u64()
        let nsec = try r.u32()
        try r.skip(4)
        let attr = try FUSEAttr.decode(&r)
        return FUSEAttrOut(attrValid: Double(valid) + Double(nsec) / 1e9, attr: attr)
    }
}

/// struct fuse_open_out.
public struct FUSEOpenOut: Sendable, Equatable {
    public var fh: UInt64
    public var flags: FUSEOpenFlags

    static func decode(_ r: inout ByteReader) throws -> FUSEOpenOut {
        let fh = try r.u64()
        let flags = try r.u32()
        return FUSEOpenOut(fh: fh, flags: FUSEOpenFlags(rawValue: flags))
    }
}

/// struct fuse_kstatfs.
public struct FUSEStatfs: Sendable, Equatable {
    public var blocks: UInt64 = 0
    public var bfree: UInt64 = 0
    public var bavail: UInt64 = 0
    public var files: UInt64 = 0
    public var ffree: UInt64 = 0
    public var bsize: UInt32 = 4096
    public var namelen: UInt32 = 255
    public var frsize: UInt32 = 4096

    public init() {}

    static func decode(_ r: inout ByteReader) throws -> FUSEStatfs {
        var s = FUSEStatfs()
        s.blocks = try r.u64()
        s.bfree = try r.u64()
        s.bavail = try r.u64()
        s.files = try r.u64()
        s.ffree = try r.u64()
        s.bsize = try r.u32()
        s.namelen = try r.u32()
        s.frsize = try r.u32()
        return s
    }

    /// The fragment size is the unit f_blocks is counted in; fall back to bsize.
    public var blockUnit: UInt64 { UInt64(frsize != 0 ? frsize : (bsize != 0 ? bsize : 512)) }
}

/// struct fuse_init_out (fields up to max_pages).
public struct FUSEInitOut: Sendable, Equatable {
    public var major: UInt32
    public var minor: UInt32
    public var maxReadahead: UInt32
    public var flags: FUSEInitFlags
    public var maxBackground: UInt16
    public var congestionThreshold: UInt16
    public var maxWrite: UInt32
    public var timeGran: UInt32
    public var maxPages: UInt16

    static func decode(_ r: inout ByteReader) throws -> FUSEInitOut {
        let major = try r.u32()
        let minor = try r.u32()
        let maxReadahead = r.remaining >= 4 ? try r.u32() : 0
        let flags = r.remaining >= 4 ? try r.u32() : 0
        let maxBackground = r.remaining >= 2 ? try r.u16() : 0
        let congestion = r.remaining >= 2 ? try r.u16() : 0
        let maxWrite = r.remaining >= 4 ? try r.u32() : 4096
        let timeGran = r.remaining >= 4 ? try r.u32() : 0
        let maxPages = r.remaining >= 2 ? try r.u16() : 0
        return FUSEInitOut(
            major: major, minor: minor, maxReadahead: maxReadahead,
            flags: FUSEInitFlags(rawValue: flags), maxBackground: maxBackground,
            congestionThreshold: congestion, maxWrite: maxWrite, timeGran: timeGran,
            maxPages: maxPages)
    }
}

/// One entry from READDIR / READDIRPLUS.
public struct FUSEDirEntry: Sendable, Equatable {
    public var ino: UInt64
    /// Offset of the *next* entry, to be used as the next READDIR offset.
    public var nextOffset: UInt64
    /// DT_* value.
    public var type: UInt32
    public var name: [UInt8]
    /// Only for READDIRPLUS. A nodeID of 0 means "no entry, no lookup count".
    public var entry: FUSEEntry?

    public var isDotOrDotDot: Bool { name == [0x2e] || name == [0x2e, 0x2e] }

    static func decodeList(_ bytes: [UInt8], plus: Bool) throws -> [FUSEDirEntry] {
        var r = ByteReader(bytes)
        var out: [FUSEDirEntry] = []
        while r.remaining > 0 {
            var entry: FUSEEntry?
            if plus { entry = try FUSEEntry.decode(&r) }
            let start = r.offset
            let ino = try r.u64()
            let off = try r.u64()
            let namelen = Int(try r.u32())
            let type = try r.u32()
            let name = Array(try r.take(namelen))
            let consumed = r.offset - start
            let padded = (consumed + 7) & ~7
            try r.skip(min(padded - consumed, r.remaining))
            out.append(FUSEDirEntry(ino: ino, nextOffset: off, type: type, name: name, entry: entry))
        }
        return out
    }

    /// Only used by tests.
    public func encode(_ w: inout ByteWriter) {
        if let entry {
            w.u64(entry.nodeID); w.u64(entry.generation)
            w.u64(0); w.u64(0); w.u32(0); w.u32(0)
            entry.attr.encode(&w)
        }
        w.u64(ino); w.u64(nextOffset); w.u32(UInt32(name.count)); w.u32(type)
        w.raw(name)
        w.pad(to: 8)
    }
}

/// struct fuse_setattr_in.
public struct FUSESetattr: Sendable, Equatable {
    public var valid: FUSESetattrValid = []
    public var fh: UInt64 = 0
    public var size: UInt64 = 0
    public var atime: FUSETime = .zero
    public var mtime: FUSETime = .zero
    public var ctime: FUSETime = .zero
    public var mode: UInt32 = 0
    public var uid: UInt32 = 0
    public var gid: UInt32 = 0

    public init() {}

    func encode() -> [UInt8] {
        var w = ByteWriter(capacity: 88)
        w.u32(valid.rawValue); w.u32(0)
        w.u64(fh); w.u64(size); w.u64(0)  // lock_owner
        w.i64(atime.seconds); w.i64(mtime.seconds); w.i64(ctime.seconds)
        w.u32(atime.nanoseconds); w.u32(mtime.nanoseconds); w.u32(ctime.nanoseconds)
        w.u32(mode); w.u32(0); w.u32(uid); w.u32(gid); w.u32(0)
        return w.bytes
    }
}

public struct FUSECaller: Sendable, Equatable {
    public var uid: UInt32
    public var gid: UInt32
    public init(uid: UInt32, gid: UInt32) {
        self.uid = uid
        self.gid = gid
    }
    public static let current = FUSECaller(uid: getuid(), gid: getgid())
}
