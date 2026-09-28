// Fusetta - an open source FUSE implementation for macOS on top of FSKit.
// Copyright (C) 2026 Håvard Sørbø <havard@hsorbo.no>
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
import Testing

@testable import FusettaCore

@Suite struct ProtocolTests {
    func sampleAttr() -> FUSEAttr {
        var a = FUSEAttr()
        a.ino = 42
        a.size = 1234
        a.blocks = 8
        a.atime = FUSETime(seconds: 100, nanoseconds: 1)
        a.mtime = FUSETime(seconds: 200, nanoseconds: 2)
        a.ctime = FUSETime(seconds: 300, nanoseconds: 3)
        a.mode = UInt32(S_IFREG) | 0o644
        a.nlink = 1
        a.uid = 501
        a.gid = 20
        a.blksize = 4096
        return a
    }

    @Test func attrRoundTrip() throws {
        let a = sampleAttr()
        var w = ByteWriter()
        a.encode(&w)
        #expect(w.bytes.count == 88)
        var r = ByteReader(w.bytes)
        #expect(try FUSEAttr.decode(&r) == a)
        #expect(r.remaining == 0)
    }

    @Test func setattrInMatchesFuseKernelH() {
        #expect(FUSESetattr().encode().count == 88)
    }

    @Test(arguments: [false, true])
    func direntListRoundTrip(plus: Bool) throws {
        let names = ["a", "longer-name.txt", "exactly8", "."]
        var w = ByteWriter()
        var expected: [FUSEDirEntry] = []
        for (i, n) in names.enumerated() {
            var attr = sampleAttr()
            attr.ino = UInt64(10 + i)
            let entry = plus ? FUSEEntry(nodeID: UInt64(100 + i), generation: 0, entryValid: 0, attrValid: 0, attr: attr) : nil
            let e = FUSEDirEntry(ino: UInt64(10 + i), nextOffset: UInt64(i + 1), type: UInt32(DT_REG), name: Array(n.utf8), entry: entry)
            e.encode(&w)
            expected.append(e)
            #expect(w.bytes.count % 8 == 0)
        }
        let decoded = try FUSEDirEntry.decodeList(w.bytes, plus: plus)
        #expect(decoded == expected)
        #expect(decoded[3].isDotOrDotDot)
    }

    @Test func truncatedReplyThrows() {
        var r = ByteReader([1, 2, 3])
        #expect(throws: FUSEError.self) { try r.u64() }
    }

    @Test func initOutParsesShortReply() throws {
        // Pre-7.23 file systems reply with the 24-byte fuse_init_out.
        var w = ByteWriter()
        w.u32(7); w.u32(19); w.u32(65536); w.u32(1)
        w.u16(12); w.u16(9); w.u32(131072)
        var r = ByteReader(w.bytes)
        let out = try FUSEInitOut.decode(&r)
        #expect(out.minor == 19)
        #expect(out.maxWrite == 131072)
        #expect(out.maxPages == 0)
    }

    @Test func configDecodingToleratesMissingKeys() throws {
        let c = try JSONDecoder().decode(FusettaMountConfig.self, from: Data(#"{"volumeName":"x"}"#.utf8))
        #expect(c.volumeName == "x")
        #expect(c.readOnly == false)
        #expect(c.appleDouble == nil)
    }

    @Test func endpointURLRoundTrip() throws {
        let id = FusettaEndpoint.randomID()
        let ep = try #require(FusettaEndpoint(serviceName: "ABCDE12345.fusetta.\(id)"))
        #expect(ep.url.absoluteString == "fusetta://mach/ABCDE12345.fusetta.\(id)")
        let parsed = try #require(FusettaEndpoint(url: ep.url))
        #expect(parsed == ep)
        #expect(parsed.id == id)
        #expect(parsed.volumeUUID == ep.volumeUUID)
        #expect(FusettaEndpoint(url: URL(string: "fusetta://127.0.0.1:4242/\(id)")!) == nil)
        #expect(FusettaEndpoint(url: URL(string: "fusetta://mach/ABCDE12345.fusetta.short")!) == nil)
        #expect(FusettaEndpoint(url: URL(string: "fusetta://mach/\(id)")!) == nil)
        #expect(FusettaEndpoint(url: URL(string: "ftp://mach/ABCDE12345.fusetta.\(id)")!) == nil)
    }

    @Test func volumeNameFallsBackToDaemonName() {
        var c = FusettaMountConfig()
        #expect(c.effectiveVolumeName == "fusetta")
        c.daemonPath = "/usr/local/bin/sshfs"
        #expect(c.effectiveVolumeName == "sshfs")
        c.volumeName = "Remote"
        #expect(c.effectiveVolumeName == "Remote")
    }
}
