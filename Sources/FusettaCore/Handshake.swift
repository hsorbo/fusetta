// Fusetta - an open source FUSE implementation for macOS on top of FSKit.
// Copyright (C) 2026 Håvard Sørbø <havard@hsorbo.no>
// SPDX-License-Identifier: GPL-2.0-only
//
// Rendezvous between the mount helper (fusermount3, run by libfuse's Darwin
// mount backend) and the sandboxed FSKit extension.
//
// fusermount3 registers a Mach service "<prefix>.<32 hex digits>" with
// launchd (HandshakeServer) and mounts "fusetta://mach/<service>". <prefix>
// is the extension's app group: the sandbox only lets the extension look up
// names under it. FSKit hands the URL to the extension as an
// FSGenericURLResource; the extension looks the service up and sends a hello
// with a reply port (FusettaHandshake.connect). fusermount3 checks the
// sender's code signature (audit token) and replies with the mount
// configuration (JSON) and one end of a socketpair as a fileport; libfuse
// gets the other end. From then on the socket carries raw FUSE messages in
// both directions:
//
//   extension -> libfuse : fuse_in_header-framed requests
//   libfuse -> extension : fuse_out_header-framed replies and notifications
//
// The service is dropped after the first successful handshake.

import Foundation
import Security

public enum FusettaHandshake {
    public static let scheme = "fusetta"
    public static let fsShortName = "fusetta"

    static let helloID: mach_msg_id_t = 0x4655_5354  // "FUST"
    static let replyID: mach_msg_id_t = helloID + 100
    static let version: UInt32 = 2
}

/// Message layout. hello: header, UInt32 version. reply (complex): header,
/// descriptor count, port descriptor (the fileport, or null), Int32 status
/// (0 or an errno), UInt32 length, then the config JSON or the reason.
private enum Wire {
    static let headerSize = MemoryLayout<mach_msg_header_t>.size  // 24
    static let helloSize = headerSize + 4
    static let descriptorCount = 24
    static let portName = 28
    static let portDisposition = 38
    static let portType = 39
    static let status = 40
    static let length = 44
    static let data = 48
    static let maxData = 4096
    static let bufferSize = data + maxData + MemoryLayout<mach_msg_max_trailer_t>.size
}

/// Where the extension finds the file system for one mount.
public struct FusettaEndpoint: Sendable, Equatable {
    public var serviceName: String

    public init?(serviceName: String) {
        guard serviceName.utf8.count < 128, let dot = serviceName.lastIndex(of: "."),
            dot != serviceName.startIndex
        else { return nil }
        let id = serviceName[serviceName.index(after: dot)...]
        guard id.count == 32, id.allSatisfy({ $0.isHexDigit }) else { return nil }
        self.serviceName = serviceName
    }

    public init?(url: URL) {
        guard url.scheme == FusettaHandshake.scheme, url.host == "mach" else { return nil }
        self.init(serviceName: String(url.path.dropFirst()))
    }

    public var url: URL {
        URL(string: "\(FusettaHandshake.scheme)://mach/\(serviceName)")!
    }

    /// The random per-mount part of the service name.
    public var id: String {
        String(serviceName[serviceName.index(after: serviceName.lastIndex(of: ".")!)...])
    }

    /// A stable UUID for the FSKit container/volume identifiers of this mount.
    public var volumeUUID: UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        let hex = Array(id.utf8)
        for i in 0..<16 {
            bytes[i] = UInt8(String(decoding: hex[(2 * i)..<(2 * i + 2)], as: UTF8.self), radix: 16) ?? 0
        }
        bytes[6] = (bytes[6] & 0x0f) | 0x40  // version 4
        bytes[8] = (bytes[8] & 0x3f) | 0x80  // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    public static func randomID() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        arc4random_buf(&bytes, bytes.count)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// From the mount options. Every key is optional on the wire.
public struct FusettaMountConfig: Codable, Sendable, Equatable {
    public var volumeName: String?
    public var readOnly = false
    /// The FUSE file system program, the fallback volume name.
    public var daemonPath: String?
    public var debug = false
    /// Allow AppleDouble ("._name") files. nil: only when the file system
    /// has no xattr support is the answer "no".
    public var appleDouble: Bool?

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        volumeName = try c.decodeIfPresent(String.self, forKey: .volumeName)
        readOnly = try c.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
        daemonPath = try c.decodeIfPresent(String.self, forKey: .daemonPath)
        debug = try c.decodeIfPresent(Bool.self, forKey: .debug) ?? false
        appleDouble = try c.decodeIfPresent(Bool.self, forKey: .appleDouble)
    }

    public var effectiveVolumeName: String {
        if let volumeName, !volumeName.isEmpty { return volumeName }
        if let daemonPath, !daemonPath.isEmpty {
            return (daemonPath as NSString).lastPathComponent
        }
        return "fusetta"
    }
}

public enum HandshakeError: Error, CustomStringConvertible {
    /// No such service (never registered, or already connected).
    case unavailable(kern_return_t)
    case rejected(String)
    case malformed

    public var description: String {
        switch self {
        case .unavailable(let kr): return "file system not reachable: \(String(cString: mach_error_string(kr)))"
        case .rejected(let why): return "handshake rejected: \(why)"
        case .malformed: return "malformed handshake"
        }
    }

    /// The closest errno, for FSKit (fusermount3 turns EPERM into a hint).
    public var errno: Int32 {
        switch self {
        case .unavailable(let kr): return kr == 1100 /* BOOTSTRAP_NOT_PRIVILEGED */ ? EPERM : ENOENT
        case .rejected: return EACCES
        case .malformed: return EPROTO
        }
    }
}

@_silgen_name("bootstrap_look_up")
private func bootstrapLookUp(_ bp: mach_port_t, _ name: UnsafePointer<CChar>, _ sp: UnsafeMutablePointer<mach_port_t>) -> kern_return_t

@_silgen_name("bootstrap_check_in")
private func bootstrapCheckIn(_ bp: mach_port_t, _ name: UnsafePointer<CChar>, _ sp: UnsafeMutablePointer<mach_port_t>) -> kern_return_t

@_silgen_name("fileport_makefd")
private func fileportMakeFD(_ port: mach_port_t) -> Int32

@_silgen_name("fileport_makeport")
private func fileportMakePort(_ fd: Int32, _ port: UnsafeMutablePointer<mach_port_t>) -> Int32

// audit_token_to_euid()/_pid() take the token by value, which a Swift
// @_silgen_name declaration cannot pass the C way; read the fields libbsm
// documents instead (val[1]: euid, val[5]: pid).
private func auditTokenToEUID(_ token: audit_token_t) -> uid_t { token.val.1 }
private func auditTokenToPID(_ token: audit_token_t) -> pid_t { pid_t(bitPattern: token.val.5) }

private func bootstrapPort() -> mach_port_t {
    var bootstrap: mach_port_t = 0
    task_get_special_port(mach_task_self_, TASK_BOOTSTRAP_PORT, &bootstrap)
    return bootstrap
}

extension FusettaHandshake {
    /// Returns our end of the FUSE socket and the mount configuration.
    public static func connect(to endpoint: FusettaEndpoint) throws -> (fd: Int32, config: FusettaMountConfig) {
        let task = mach_task_self_
        let bootstrap = bootstrapPort()
        defer { mach_port_deallocate(task, bootstrap) }
        var server: mach_port_t = 0
        let kr = endpoint.serviceName.withCString { bootstrapLookUp(bootstrap, $0, &server) }
        guard kr == KERN_SUCCESS else { throw HandshakeError.unavailable(kr) }
        defer { mach_port_deallocate(task, server) }

        var reply: mach_port_t = 0
        guard mach_port_allocate(task, MACH_PORT_RIGHT_RECEIVE, &reply) == KERN_SUCCESS else { throw FUSEError(ENOMEM) }
        defer { mach_port_mod_refs(task, reply, MACH_PORT_RIGHT_RECEIVE, -1) }

        let size = Wire.bufferSize
        let buf = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { buf.deallocate() }
        buf.initializeMemory(as: UInt8.self, repeating: 0, count: size)
        let header = buf.bindMemory(to: mach_msg_header_t.self, capacity: 1)
        header.pointee.msgh_bits = UInt32(MACH_MSG_TYPE_COPY_SEND) | (UInt32(MACH_MSG_TYPE_MAKE_SEND_ONCE) << 8)
        header.pointee.msgh_size = mach_msg_size_t(Wire.helloSize)
        header.pointee.msgh_remote_port = server
        header.pointee.msgh_local_port = reply
        header.pointee.msgh_id = helloID
        buf.storeBytes(of: version, toByteOffset: Wire.headerSize, as: UInt32.self)

        let mr = mach_msg(header, MACH_SEND_MSG | MACH_SEND_TIMEOUT | MACH_RCV_MSG | MACH_RCV_TIMEOUT,
                          header.pointee.msgh_size, mach_msg_size_t(size), reply, 30_000, mach_port_t(MACH_PORT_NULL))
        switch mr {
        case MACH_MSG_SUCCESS: break
        case MACH_SEND_INVALID_DEST: throw HandshakeError.unavailable(mr)
        case MACH_SEND_TIMED_OUT, MACH_RCV_TIMED_OUT: throw FUSEError(ETIMEDOUT)
        default: throw HandshakeError.malformed
        }

        let got = header.pointee
        guard got.msgh_id == replyID, got.msgh_bits & MACH_MSGH_BITS_COMPLEX != 0, Int(got.msgh_size) >= Wire.data,
            buf.load(fromByteOffset: Wire.descriptorCount, as: UInt32.self) == 1,
            buf.load(fromByteOffset: Wire.portType, as: UInt8.self) == UInt8(MACH_MSG_PORT_DESCRIPTOR)
        else {
            mach_msg_destroy(header)
            throw HandshakeError.malformed
        }
        let fileport = buf.load(fromByteOffset: Wire.portName, as: mach_port_t.self)
        defer { if fileport != 0 { mach_port_deallocate(task, fileport) } }
        let status = buf.load(fromByteOffset: Wire.status, as: Int32.self)
        let length = Int(buf.load(fromByteOffset: Wire.length, as: UInt32.self))
        guard Wire.data + length <= Int(got.msgh_size) else { throw HandshakeError.malformed }
        let data = Data(bytes: buf + Wire.data, count: length)
        guard status == 0 else { throw HandshakeError.rejected(String(decoding: data, as: UTF8.self)) }

        let fd = fileportMakeFD(fileport)
        guard fd >= 0 else { throw FUSEError(errno) }
        do {
            let config = try JSONDecoder().decode(FusettaMountConfig.self, from: data)
            SocketIO.setNoSigPipe(fd)
            SocketIO.setBufferSizes(fd, 4 * 1024 * 1024)
            return (fd, config)
        } catch {
            Darwin.close(fd)
            throw error
        }
    }
}

/// The mount helper's side: a Mach service the extension looks up.
public final class HandshakeServer {
    public enum Outcome {
        /// A peer took the other end; this is ours.
        case connected(fd: Int32)
        /// A peer failed `authorize` or spoke another protocol version.
        case refused(pid: pid_t, reason: String)
        /// Nothing (usable) arrived in time.
        case timedOut
    }

    public let endpoint: FusettaEndpoint
    private var port: mach_port_t = 0

    public init(prefix: String) throws {
        guard let endpoint = FusettaEndpoint(serviceName: "\(prefix).\(FusettaEndpoint.randomID())") else {
            throw FUSEError(ENAMETOOLONG)
        }
        self.endpoint = endpoint
        let bootstrap = bootstrapPort()
        defer { mach_port_deallocate(mach_task_self_, bootstrap) }
        let kr = endpoint.serviceName.withCString { bootstrapCheckIn(bootstrap, $0, &port) }
        guard kr == KERN_SUCCESS else { throw HandshakeError.unavailable(kr) }
    }

    deinit { invalidate() }

    /// Drops the receive right, and with it the service name.
    public func invalidate() {
        if port != 0 {
            mach_port_mod_refs(mach_task_self_, port, MACH_PORT_RIGHT_RECEIVE, -1)
            port = 0
        }
    }

    /// Waits up to `timeoutMS` for a hello. A sender that passes `authorize`
    /// gets the configuration and one end of a new socketpair.
    public func accept(config: Data, timeoutMS: mach_msg_timeout_t, authorize: (audit_token_t) -> Bool) -> Outcome {
        let buf = UnsafeMutableRawPointer.allocate(byteCount: Wire.bufferSize, alignment: 8)
        defer { buf.deallocate() }
        let header = buf.bindMemory(to: mach_msg_header_t.self, capacity: 1)
        let trailerAudit: Int32 = 3 << 24  // MACH_RCV_TRAILER_ELEMENTS(MACH_RCV_TRAILER_AUDIT)
        let kr = mach_msg(header, MACH_RCV_MSG | MACH_RCV_TIMEOUT | trailerAudit, 0, mach_msg_size_t(Wire.bufferSize),
                          port, timeoutMS, mach_port_t(MACH_PORT_NULL))
        guard kr == MACH_MSG_SUCCESS else { return .timedOut }

        let h = header.pointee
        let reply = h.msgh_remote_port
        guard h.msgh_id == FusettaHandshake.helloID, Int(h.msgh_size) == Wire.helloSize,
            h.msgh_bits & MACH_MSGH_BITS_COMPLEX == 0,
            h.msgh_bits & 0x1f == MACH_MSG_TYPE_MOVE_SEND_ONCE,  // MACH_MSGH_BITS_REMOTE
            reply != 0
        else {
            mach_msg_destroy(header)
            return .timedOut
        }
        let version = buf.load(fromByteOffset: Wire.headerSize, as: UInt32.self)
        let tokenOffset = Wire.helloSize + MemoryLayout<mach_msg_audit_trailer_t>.offset(of: \.msgh_audit)!
        let token = buf.load(fromByteOffset: tokenOffset, as: audit_token_t.self)
        let pid = auditTokenToPID(token)

        guard version == FusettaHandshake.version else {
            let why = "protocol version \(version), expected \(FusettaHandshake.version)"
            send(to: reply, status: EPROTONOSUPPORT, fileport: 0, data: Data(why.utf8))
            return .refused(pid: pid, reason: why)
        }
        guard authorize(token) else {
            send(to: reply, status: EPERM, fileport: 0, data: Data("not the Fusetta extension".utf8))
            return .refused(pid: pid, reason: "not the Fusetta extension")
        }

        var sv: [Int32] = [-1, -1]
        var fileport: mach_port_t = 0
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sv) == 0 else {
            send(to: reply, status: errno, fileport: 0, data: Data(String(cString: strerror(errno)).utf8))
            return .timedOut
        }
        let made = fileportMakePort(sv[1], &fileport)
        Darwin.close(sv[1])  // the fileport keeps the peer's end open
        guard made == 0, send(to: reply, status: 0, fileport: fileport, data: config) else {
            Darwin.close(sv[0])
            return .timedOut
        }
        return .connected(fd: sv[0])
    }

    /// The sender is our user's process satisfying `requirement` (if any).
    public static func peer(_ token: audit_token_t, satisfies requirement: SecRequirement?) -> Bool {
        guard auditTokenToEUID(token) == geteuid() else { return false }
        guard let requirement else { return true }
        var token = token
        let attrs = [kSecGuestAttributeAudit: Data(bytes: &token, count: MemoryLayout<audit_token_t>.size)] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess, let code else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    @discardableResult
    private func send(to reply: mach_port_t, status: Int32, fileport: mach_port_t, data: Data) -> Bool {
        let length = min(data.count, Wire.maxData)
        let size = Wire.data + ((length + 3) & ~3)
        let buf = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { buf.deallocate() }
        buf.initializeMemory(as: UInt8.self, repeating: 0, count: size)
        let header = buf.bindMemory(to: mach_msg_header_t.self, capacity: 1)
        header.pointee.msgh_bits = UInt32(MACH_MSG_TYPE_MOVE_SEND_ONCE) | MACH_MSGH_BITS_COMPLEX
        header.pointee.msgh_size = mach_msg_size_t(size)
        header.pointee.msgh_remote_port = reply
        header.pointee.msgh_id = FusettaHandshake.replyID
        buf.storeBytes(of: UInt32(1), toByteOffset: Wire.descriptorCount, as: UInt32.self)
        buf.storeBytes(of: fileport, toByteOffset: Wire.portName, as: mach_port_t.self)
        buf.storeBytes(of: UInt8(MACH_MSG_TYPE_MOVE_SEND), toByteOffset: Wire.portDisposition, as: UInt8.self)
        buf.storeBytes(of: UInt8(MACH_MSG_PORT_DESCRIPTOR), toByteOffset: Wire.portType, as: UInt8.self)
        buf.storeBytes(of: status, toByteOffset: Wire.status, as: Int32.self)
        buf.storeBytes(of: UInt32(length), toByteOffset: Wire.length, as: UInt32.self)
        data.prefix(length).withUnsafeBytes { (buf + Wire.data).copyMemory(from: $0.baseAddress!, byteCount: length) }
        let kr = mach_msg(header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, mach_msg_size_t(size), 0,
                          mach_port_t(MACH_PORT_NULL), 5000, mach_port_t(MACH_PORT_NULL))
        if kr != MACH_MSG_SUCCESS { mach_msg_destroy(header) }
        return kr == MACH_MSG_SUCCESS
    }
}
