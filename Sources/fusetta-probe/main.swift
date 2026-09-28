// Fusetta - an open source FUSE implementation for macOS on top of FSKit.
// Copyright (C) 2026 Håvard Sørbø <havard@hsorbo.no>
// SPDX-License-Identifier: GPL-2.0-only
//
// fusetta-probe: plays the kernel against a FUSE file system without FSKit.
//
//   FUSETTA_ENDPOINT_FILE=/tmp/ep ./hello_ll -f /tmp/mnt &
//   fusetta-probe "$(cat /tmp/ep)" ls /
//   fusetta-probe "$(cat /tmp/ep)" cat /hello

import Foundation
import FusettaCore

func usage() -> Never {
    print("""
        usage: fusetta-probe <fusetta://endpoint> <command> [path]
          commands: info, ls <dir>, lsr <dir>, stat <path>, cat <path>, xattr <path>,
                    setxattr <path> <name> <value>, write <path> <text>, mkdir <path>,
                    rm <path>, rmdir <path>, mv <from> <to>
        """)
    exit(2)
}

let args = CommandLine.arguments
guard args.count >= 3, let url = URL(string: args[1]), let endpoint = FusettaEndpoint(url: url) else { usage() }

func components(_ path: String) -> [[UInt8]] {
    path.split(separator: "/").map { Array($0.utf8) }
}

func resolve(_ s: FUSESession, _ path: String) async throws -> (UInt64, FUSEAttr) {
    var node = FUSEConstants.rootID
    var attr = try await s.getattr(nodeID: node).attr
    for c in components(path) {
        let e = try await s.lookup(parent: node, name: c)
        node = e.nodeID
        attr = e.attr
    }
    return (node, attr)
}

func parentAndName(_ s: FUSESession, _ path: String) async throws -> (UInt64, [UInt8]) {
    var comps = components(path)
    guard let name = comps.popLast() else { throw FUSEError(EINVAL) }
    let (parent, _) = try await resolve(s, "/" + comps.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "/"))
    return (parent, name)
}

func describe(_ a: FUSEAttr) -> String {
    String(format: "%06o nlink=%u uid=%u gid=%u size=%llu ino=%llu mtime=%lld", a.mode, a.nlink, a.uid, a.gid, a.size, a.ino, a.mtime.seconds)
}

func list(_ s: FUSESession, _ node: UInt64, prefix: String, recursive: Bool) async throws {
    let dh = try await s.opendir(nodeID: node)
    var offset: UInt64 = 0
    while true {
        let entries = try await s.readdir(nodeID: node, fh: dh.fh, offset: offset, plus: false)
        if entries.isEmpty { break }
        for e in entries {
            let name = String(decoding: e.name, as: UTF8.self)
            print("\(prefix)\(name)\t(ino \(e.ino), type \(e.type))")
            if recursive && !e.isDotOrDotDot && e.type == UInt32(DT_DIR) {
                let child = try await s.lookup(parent: node, name: e.name)
                try await list(s, child.nodeID, prefix: prefix + name + "/", recursive: true)
                s.forget(nodeID: child.nodeID, nlookup: 1)
            }
            offset = e.nextOffset
        }
    }
    try await s.release(nodeID: node, fh: dh.fh, flags: O_RDONLY, directory: true)
}

let (fd, config) = try FusettaHandshake.connect(to: endpoint)
let connection = FUSEConnection(fd: fd)
if ProcessInfo.processInfo.environment["FUSETTA_TRACE"] != nil {
    connection.trace = { print("trace: \($0)") }
}
connection.start()
let session = FUSESession(connection: connection)
let initOut = try await session.initialize()
func execute(_ words: [String]) async throws {
    guard let command = words.first else { return }
    let path = words.count > 1 ? words[1] : "/"
    switch command {
    case "info":
        print("config: \(config)")
        print("init: \(initOut)")
        print("statfs: \(try await session.statfs())")
    case "ls", "lsr":
        let (node, _) = try await resolve(session, path)
        try await list(session, node, prefix: "", recursive: command == "lsr")
    case "stat":
        let (_, attr) = try await resolve(session, path)
        print(describe(attr))
    case "cat":
        let (node, attr) = try await resolve(session, path)
        let fh = try await session.open(nodeID: node, flags: O_RDONLY)
        var offset: UInt64 = 0
        while true {
            let data = try await session.read(nodeID: node, fh: fh.fh, offset: offset, size: 128 * 1024)
            if data.isEmpty { break }
            FileHandle.standardOutput.write(Data(data))
            offset += UInt64(data.count)
            if !fh.flags.contains(.directIO) && offset >= attr.size { break }
        }
        try await session.release(nodeID: node, fh: fh.fh, flags: O_RDONLY)
    case "xattr":
        let (node, _) = try await resolve(session, path)
        for name in try await session.listxattr(nodeID: node) {
            let value = try await session.getxattr(nodeID: node, name: name)
            print("\(String(decoding: name, as: UTF8.self)) = \(value.count) bytes")
        }
    case "setxattr":
        guard words.count > 3 else { usage() }
        let (node, _) = try await resolve(session, path)
        try await session.setxattr(nodeID: node, name: Array(words[2].utf8), value: Array(words[3].utf8), flags: 0)
    case "write":
        guard words.count > 2 else { usage() }
        let (parent, name) = try await parentAndName(session, path)
        let (entry, fh) = try await session.create(parent: parent, name: name, mode: UInt32(S_IFREG | 0o644), flags: O_WRONLY | O_CREAT | O_TRUNC)
        let n = try await session.write(nodeID: entry.nodeID, fh: fh.fh, offset: 0, data: Data(words[2...].joined(separator: " ").utf8))
        try await session.flush(nodeID: entry.nodeID, fh: fh.fh)
        try await session.release(nodeID: entry.nodeID, fh: fh.fh, flags: O_WRONLY)
        print("wrote \(n) bytes")
    case "mkdir":
        let (parent, name) = try await parentAndName(session, path)
        print(describe(try await session.mkdir(parent: parent, name: name, mode: 0o755).attr))
    case "rm":
        let (parent, name) = try await parentAndName(session, path)
        try await session.unlink(parent: parent, name: name)
    case "rmdir":
        let (parent, name) = try await parentAndName(session, path)
        try await session.rmdir(parent: parent, name: name)
    case "mv":
        guard words.count > 2 else { usage() }
        let (p1, n1) = try await parentAndName(session, path)
        let (p2, n2) = try await parentAndName(session, words[2])
        try await session.rename(parent: p1, name: n1, newParent: p2, newName: n2)
    default:
        usage()
    }
}

// "-" reads one command per line from stdin: an endpoint accepts only one
// connection.
var failed = false
if args[2] == "-" {
    while let line = readLine() {
        let words = line.split(separator: " ").map(String.init)
        if words.isEmpty { continue }
        print("$ \(line)")
        do { try await execute(words) } catch {
            print("error: \(error)")
            failed = true
        }
    }
} else {
    do { try await execute(Array(args[2...])) } catch {
        FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
        failed = true
    }
}
connection.close()
exit(failed ? 1 : 0)
