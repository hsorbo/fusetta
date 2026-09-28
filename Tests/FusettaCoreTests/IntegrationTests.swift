// Fusetta - an open source FUSE implementation for macOS on top of FSKit.
// Copyright (C) 2026 Håvard Sørbø <havard@hsorbo.no>
// SPDX-License-Identifier: GPL-2.0-only
//
// Runs real libfuse file systems (built by scripts/build-libfuse.sh) with the
// Darwin mount backend and our fusermount3 in test mode
// (FUSETTA_ENDPOINT_FILE: no mount(8)) and drives them with FUSESession,
// i.e. the whole stack except FSKit.

import Foundation
import Testing

@testable import FusettaCore

private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func binary(_ relative: String) -> URL? {
    let url = root.appending(path: relative)
    return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
}

final class RunningFS {
    let process = Process()
    let session: FUSESession
    let config: FusettaMountConfig
    let tmp: URL
    let endpoint: FusettaEndpoint

    static func launch(_ executable: URL, args: [String] = [], process: Process, tmp: URL) async throws -> FusettaEndpoint {
        try FileManager.default.createDirectory(at: tmp.appending(path: "mnt"), withIntermediateDirectories: true)
        let endpointFile = tmp.appending(path: "endpoint")
        process.executableURL = executable
        process.arguments = args + ["-f", tmp.appending(path: "mnt").path]
        var env = ProcessInfo.processInfo.environment
        env["FUSETTA_ENDPOINT_FILE"] = endpointFile.path
        // libfuse finds the mount helper in $PATH.
        let helper = try #require(binary(".build/debug/fusermount3"), "build fusermount3 first: swift build")
        env["PATH"] = helper.deletingLastPathComponent().path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        for _ in 0..<100 {
            if let s = try? String(contentsOf: endpointFile, encoding: .utf8), !s.isEmpty,
                let url = URL(string: s), let endpoint = FusettaEndpoint(url: url)
            {
                return endpoint
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        process.terminate()
        throw FUSEError(ETIMEDOUT)
    }

    init(_ executable: URL, args: [String] = []) async throws {
        tmp = FileManager.default.temporaryDirectory.appending(path: "fusetta-test-\(UUID().uuidString)")
        endpoint = try await Self.launch(executable, args: args, process: process, tmp: tmp)
        let (fd, config) = try FusettaHandshake.connect(to: endpoint)
        self.config = config
        let connection = FUSEConnection(fd: fd)
        connection.start()
        session = FUSESession(connection: connection)
        _ = try await session.initialize()
    }

    func stop() {
        session.connection.close()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: tmp)
    }

    func lookupPath(_ path: String) async throws -> FUSEEntry {
        var node = FUSEConstants.rootID
        var entry: FUSEEntry?
        for c in path.split(separator: "/") {
            entry = try await session.lookup(parent: node, name: Array(c.utf8))
            node = entry!.nodeID
        }
        return try #require(entry)
    }

    func listDir(_ node: UInt64, plus: Bool = false) async throws -> [FUSEDirEntry] {
        let dh = try await session.opendir(nodeID: node)
        var all: [FUSEDirEntry] = []
        var offset: UInt64 = 0
        while true {
            let batch = try await session.readdir(nodeID: node, fh: dh.fh, offset: offset, size: 4096, plus: plus)
            if batch.isEmpty { break }
            all += batch
            offset = batch.last!.nextOffset
        }
        try await session.release(nodeID: node, fh: dh.fh, flags: O_RDONLY, directory: true)
        return all
    }
}

@Suite(.serialized) struct IntegrationTests {
    @Test func handshakeIsOneShot() async throws {
        let exe = try #require(binary("build/libfuse/example/hello_ll"), "build libfuse first: scripts/build-libfuse.sh")
        let process = Process()
        let tmp = FileManager.default.temporaryDirectory.appending(path: "fusetta-test-\(UUID().uuidString)")
        defer {
            process.terminate()
            try? FileManager.default.removeItem(at: tmp)
        }
        let endpoint = try await RunningFS.launch(exe, process: process, tmp: tmp)
        let prefix = endpoint.serviceName.dropLast(endpoint.id.count)
        let forged = try #require(FusettaEndpoint(serviceName: prefix + FusettaEndpoint.randomID()))
        #expect(throws: HandshakeError.self) { _ = try FusettaHandshake.connect(to: forged) }
        let (fd, config) = try FusettaHandshake.connect(to: endpoint)
        defer { close(fd) }
        #expect(config.daemonPath == "hello_ll")
        // fusermount3 drops the service once connected.
        #expect(throws: HandshakeError.self) { _ = try FusettaHandshake.connect(to: endpoint) }
    }

    @Test func helloLowLevel() async throws {
        let exe = try #require(binary("build/libfuse/example/hello_ll"), "build libfuse first: scripts/build-libfuse.sh")
        let fs = try await RunningFS(exe)
        defer { fs.stop() }

        #expect(fs.config.daemonPath == "hello_ll")
        let names = try await fs.listDir(FUSEConstants.rootID).map { String(decoding: $0.name, as: UTF8.self) }
        #expect(names.contains("hello"))

        let hello = try await fs.lookupPath("hello")
        #expect(hello.attr.size == 13)
        #expect(hello.attr.fileType == UInt32(S_IFREG))
        let fh = try await fs.session.open(nodeID: hello.nodeID, flags: O_RDONLY)
        let data = try await fs.session.read(nodeID: hello.nodeID, fh: fh.fh, offset: 0, size: 4096)
        #expect(String(decoding: data, as: UTF8.self) == "Hello World!\n")
        let tail = try await fs.session.read(nodeID: hello.nodeID, fh: fh.fh, offset: 6, size: 5)
        #expect(String(decoding: tail, as: UTF8.self) == "World")
        try await fs.session.release(nodeID: hello.nodeID, fh: fh.fh, flags: O_RDONLY)

        await #expect(throws: FUSEError.noEntry) { try await fs.session.lookup(parent: FUSEConstants.rootID, name: Array("missing".utf8)) }
        fs.session.forget(nodeID: hello.nodeID, nlookup: 1)
    }

    @Test func passthroughReadWrite() async throws {
        let exe = try #require(binary("build/libfuse/example/passthrough"), "build libfuse first: scripts/build-libfuse.sh")
        let fs = try await RunningFS(exe)
        defer { fs.stop() }

        // The passthrough examples mirror "/", so work inside our temp dir.
        let work = fs.tmp.appending(path: "work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let dir = try await fs.lookupPath(work.path)
        #expect(dir.attr.isDirectory)

        let (file, fh) = try await fs.session.create(parent: dir.nodeID, name: Array("a.txt".utf8), mode: UInt32(S_IFREG) | 0o640, flags: O_RDWR | O_CREAT | O_EXCL)
        let payload = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        var off = 0
        while off < payload.count {
            let chunk = payload[off..<min(payload.count, off + fs.session.maxWrite, off + 131_072)]
            off += try await fs.session.write(nodeID: file.nodeID, fh: fh.fh, offset: UInt64(off), data: Data(chunk))
        }
        try await fs.session.flush(nodeID: file.nodeID, fh: fh.fh)
        try await fs.session.release(nodeID: file.nodeID, fh: fh.fh, flags: O_RDWR)
        #expect(try Data(contentsOf: work.appending(path: "a.txt")) == payload)

        let attr = try await fs.session.getattr(nodeID: file.nodeID).attr
        #expect(attr.size == UInt64(payload.count))
        #expect(attr.mode & 0o777 == 0o640)

        var s = FUSESetattr()
        s.valid = [.size, .mode, .mtime]
        s.size = 10
        s.mode = UInt32(S_IFREG) | 0o600
        s.mtime = FUSETime(seconds: 1_000_000_000, nanoseconds: 0)
        let after = try await fs.session.setattr(nodeID: file.nodeID, s).attr
        #expect(after.size == 10)
        #expect(after.mode & 0o777 == 0o600)
        #expect(after.mtime.seconds == 1_000_000_000)

        try await fs.session.setxattr(nodeID: file.nodeID, name: Array("user.fusetta".utf8), value: Array("yes".utf8), flags: 0)
        #expect(try await fs.session.getxattr(nodeID: file.nodeID, name: Array("user.fusetta".utf8)) == Array("yes".utf8))
        #expect(try await fs.session.listxattr(nodeID: file.nodeID).contains(Array("user.fusetta".utf8)))
        try await fs.session.removexattr(nodeID: file.nodeID, name: Array("user.fusetta".utf8))

        let sub = try await fs.session.mkdir(parent: dir.nodeID, name: Array("sub".utf8), mode: 0o755)
        let link = try await fs.session.symlink(parent: dir.nodeID, name: Array("ln".utf8), target: Array("a.txt".utf8))
        #expect(try await fs.session.readlink(nodeID: link.nodeID) == Array("a.txt".utf8))
        let hard = try await fs.session.link(nodeID: file.nodeID, newParent: sub.nodeID, newName: Array("hard".utf8))
        #expect(hard.attr.nlink == 2)
        try await fs.session.rename(parent: dir.nodeID, name: Array("a.txt".utf8), newParent: sub.nodeID, newName: Array("b.txt".utf8))
        #expect(FileManager.default.fileExists(atPath: work.appending(path: "sub/b.txt").path))

        let names = Set(try await fs.listDir(dir.nodeID).map { String(decoding: $0.name, as: UTF8.self) })
        #expect(names.isSuperset(of: ["sub", "ln"]))
        if fs.session.supportsReaddirplus {
            let plus = try await fs.listDir(sub.nodeID, plus: true)
            let entries = plus.filter { !$0.isDotOrDotDot }
            #expect(entries.count == 2)
            fs.session.batchForget(entries.compactMap { $0.entry }.filter { $0.nodeID != 0 }.map { ($0.nodeID, 1) })
        }

        let st = try await fs.session.statfs()
        #expect(st.blocks > 0)

        try await fs.session.unlink(parent: sub.nodeID, name: Array("b.txt".utf8))
        try await fs.session.unlink(parent: sub.nodeID, name: Array("hard".utf8))
        try await fs.session.unlink(parent: dir.nodeID, name: Array("ln".utf8))
        try await fs.session.rmdir(parent: dir.nodeID, name: Array("sub".utf8))
        await #expect(throws: FUSEError.self) { try await fs.session.rmdir(parent: dir.nodeID, name: Array("sub".utf8)) }
    }
}
