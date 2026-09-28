// Fusetta - an open source FUSE implementation for macOS on top of FSKit.
// Copyright (C) 2026 Håvard Sørbø <havard@hsorbo.no>
// SPDX-License-Identifier: GPL-2.0-only
//
// fusermount3: the mount helper libfuse runs on macOS (lib/mount_darwin.c in
// patches/libfuse-3.18.3-darwin.patch), with the same interface as on Linux:
//
//   fusermount3 -o <options> -- <mountpoint>     ($_FUSE_COMMFD set)
//   fusermount3 -u [-q] [-z] -- <mountpoint>
//
// Mounting registers a Mach service, runs `mount -F -t fusetta` with it and
// waits for the FSKit extension (FusettaCore/Handshake.swift). Once the
// extension has its end of the FUSE channel and the volume is mounted, the
// other end goes back to libfuse over $_FUSE_COMMFD (SCM_RIGHTS).
//
// The Mach prefix is the app group of the FusettaFS.appex this helper ships
// with (Fusetta.app/Contents/MacOS/fusermount3 next to
// Contents/Extensions/FusettaFS.appex), whose designated requirement a peer
// must satisfy. $FUSETTA_MACH_PREFIX (or -o fusetta_prefix=) overrides it.
//
// With FUSETTA_ENDPOINT_FILE=<path> (tests, scripts/probe-fs.sh) no mount(8)
// runs: the endpoint URL goes to <path>, and any process of ours that
// connects gets the channel.

import Foundation
import FusettaCore
import Security

let program = "fusermount3"
let env = ProcessInfo.processInfo.environment

func warn(_ message: String) {
    FileHandle.standardError.write(Data("\(program): \(message)\n".utf8))
}

func fail(_ message: String) -> Never {
    warn(message)
    exit(1)
}

func usage() -> Never {
    print("""
        usage: \(program) [-o options] [--] mountpoint
               \(program) -u [-q] [-z] [--] mountpoint

        Mount helper that libfuse runs on macOS (Fusetta, via FSKit).
        """)
    exit(2)
}

/// Splits a -o list at unescaped commas (libfuse escapes "," and "\\").
func splitOptions(_ list: String) -> [String] {
    var out: [String] = []
    var current = ""
    var escaped = false
    for c in list {
        if escaped {
            current.append(c)
            escaped = false
        } else if c == "\\" {
            escaped = true
        } else if c == "," {
            out.append(current)
            current = ""
        } else {
            current.append(c)
        }
    }
    out.append(current)
    return out.filter { !$0.isEmpty }
}

func executable(of pid: pid_t) -> URL? {
    var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))  // PROC_PIDPATHINFO_MAXSIZE
    guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
    return URL(fileURLWithPath: String(cString: buf))
}

// MARK: - Where the extension listens and who it must be

struct Target {
    var prefix: String
    /// What a peer must satisfy; nil: only our user is checked.
    var requirement: SecRequirement?
}

/// The FusettaFS.appex in the app bundle we ship in: its first app group and
/// its designated requirement.
func bundledExtension() -> Target? {
    guard let exe = executable(of: getpid()) else { return nil }
    let appex = exe.deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Extensions/FusettaFS.appex")
    var code: SecStaticCode?
    var info: CFDictionary?
    var requirement: SecRequirement?
    guard SecStaticCodeCreateWithPath(appex as CFURL, [], &code) == errSecSuccess, let code,
        SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation),
                                      &info) == errSecSuccess,
        let info = info as? [String: Any],
        let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
        let group = (entitlements["com.apple.security.application-groups"] as? [String])?.first,
        SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess
    else { return nil }
    return Target(prefix: group, requirement: requirement)
}

/// For an explicit prefix: an FSKit module, of the team the prefix names
/// ("<TEAMID>.group") if it does.
func requirement(forPrefix prefix: String) -> SecRequirement? {
    var text = #"anchor apple generic and entitlement["com.apple.developer.fskit.fsmodule"] exists"#
    let team = prefix.prefix { $0 != "." }
    if team.count == 10, team.allSatisfy({ $0.isUppercase || $0.isNumber }), prefix.count > 10 {
        text += #" and certificate leaf[subject.OU] = "\#(team)""#
    }
    var requirement: SecRequirement?
    SecRequirementCreateWithString(text as CFString, [], &requirement)
    return requirement
}

func resolveTarget(override: String?, testMode: Bool) -> Target {
    if let override, !override.isEmpty {
        return Target(prefix: override, requirement: testMode ? nil : requirement(forPrefix: override))
    }
    if var target = bundledExtension() {
        if testMode { target.requirement = nil }
        return target
    }
    if testMode { return Target(prefix: "fusetta.test", requirement: nil) }
    fail("cannot find FusettaFS.appex; use the \(program) inside Fusetta.app or set FUSETTA_MACH_PREFIX")
}

// MARK: - Talking to libfuse and mount(8)

/// Passes `fd` over the socket libfuse gave us, like Linux's fusermount3.
func send(fd: Int32, over socket: Int32) -> Bool {
    // One cmsghdr (12 bytes) plus the fd: CMSG_SPACE(sizeof(int)) on Darwin.
    var control = [UInt8](repeating: 0, count: 16)
    control.withUnsafeMutableBytes {
        $0.storeBytes(of: UInt32(16), toByteOffset: 0, as: UInt32.self)  // cmsg_len
        $0.storeBytes(of: SOL_SOCKET, toByteOffset: 4, as: Int32.self)
        $0.storeBytes(of: SCM_RIGHTS, toByteOffset: 8, as: Int32.self)
        $0.storeBytes(of: fd, toByteOffset: 12, as: Int32.self)
    }
    var byte: UInt8 = 0
    return withUnsafeMutablePointer(to: &byte) { bytePtr in
        var iov = iovec(iov_base: bytePtr, iov_len: 1)
        return withUnsafeMutablePointer(to: &iov) { iovPtr in
            control.withUnsafeMutableBytes { c in
                var msg = msghdr(msg_name: nil, msg_namelen: 0, msg_iov: iovPtr, msg_iovlen: 1,
                                 msg_control: c.baseAddress, msg_controllen: socklen_t(c.count), msg_flags: 0)
                return sendmsg(socket, &msg, 0) == 1
            }
        }
    }
}

func run(_ path: String, _ arguments: [String], stderr: Any = FileHandle.standardError) throws -> Process {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = arguments
    p.standardInput = FileHandle.nullDevice
    p.standardOutput = FileHandle.nullDevice
    p.standardError = stderr
    try p.run()
    return p
}

func mountFailed(_ mount: Process, output: Pipe, prefix: String) -> Never {
    mount.waitUntilExit()
    let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    warn("mount failed (status \(mount.terminationStatus))" + (text.isEmpty ? "" : ":\n" + text))
    if text.contains("Loading resource") && text.contains("not permitted") {
        warn("the Fusetta extension may not look up \(prefix).*; is that its app group? (FUSETTA_MACH_PREFIX)")
    } else if text.contains("disabled") || !text.contains(" resource: ") {
        warn("enable Fusetta in System Settings > General > Login Items & Extensions > File System Extensions")
    }
    exit(1)
}

// MARK: - Main

var options: [String] = []
var unmount = false
var quiet = false
var mountPoint: String?
var args = CommandLine.arguments.dropFirst()
while let arg = args.popFirst() {
    switch arg {
    case "-o":
        guard let list = args.popFirst() else { usage() }
        options += splitOptions(list)
    case "-u", "--unmount": unmount = true
    case "-q", "--quiet": quiet = true
    case "-z", "--lazy", "--auto-unmount": break
    case "-V", "--version":
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        print("\(program) (Fusetta\(version.map { " " + $0 } ?? ""))")
        exit(0)
    case "-h", "--help": usage()
    case "--":
        guard let m = args.popFirst(), args.isEmpty else { usage() }
        mountPoint = m
    default:
        guard !arg.hasPrefix("-"), mountPoint == nil else { usage() }
        mountPoint = arg
    }
}
guard let mountPoint else { usage() }
let endpointFile = env["FUSETTA_ENDPOINT_FILE"]

if unmount {
    if endpointFile != nil { exit(0) }  // test mode mounted nothing
    guard let p = try? run("/sbin/umount", [mountPoint], stderr: quiet ? FileHandle.nullDevice : FileHandle.standardError)
    else { fail("cannot run umount") }
    p.waitUntilExit()
    exit(p.terminationStatus == 0 ? 0 : 1)
}

guard let commFD = env["_FUSE_COMMFD"].flatMap(Int32.init) else {
    fail("not started by libfuse ($_FUSE_COMMFD is not set)")
}

// Options libfuse did not handle itself. Linux kernel options without
// meaning under FSKit are accepted and ignored.
let ignored: Set<String> = [
    "rw", "allow_other", "allow_root", "auto_unmount", "default_permissions", "blkdev", "nonempty",
    "dev", "nodev", "suid", "nosuid", "exec", "noexec", "atime", "noatime", "nodiratime", "relatime",
    "strictatime", "nostrictatime", "async", "sync", "dirsync", "symfollow", "nosymfollow",
]
let ignoredPrefixes = ["blksize=", "fsname=", "subtype=", "max_read=", "user=", "context=", "fscontext=",
                       "defcontext=", "rootcontext=", "x-"]
var config = FusettaMountConfig()
var prefixOverride = env["FUSETTA_MACH_PREFIX"]
for option in options {
    let parts = option.split(separator: "=", maxSplits: 1)
    let value = parts.count > 1 ? String(parts[1]) : nil
    switch String(parts[0]) {
    case "volname": config.volumeName = value
    case "ro", "rdonly": config.readOnly = true
    case "debug": config.debug = true
    case "appledouble": config.appleDouble = true
    case "noappledouble": config.appleDouble = false
    case "fusetta_prefix": prefixOverride = value
    default:
        guard ignored.contains(option) || ignoredPrefixes.contains(where: option.hasPrefix) else {
            fail("unknown option '\(option)'")
        }
    }
}
config.daemonPath = executable(of: getppid())?.lastPathComponent

let target = resolveTarget(override: prefixOverride, testMode: endpointFile != nil)
let server: HandshakeServer
do {
    server = try HandshakeServer(prefix: target.prefix)
} catch {
    fail("cannot register a Mach service under \(target.prefix): \(error)")
}
let url = server.endpoint.url.absoluteString
guard let configData = try? JSONEncoder().encode(config) else { fail("cannot encode the mount configuration") }

var mount: Process?
let mountOutput = Pipe()
if let endpointFile {
    do {
        try url.write(toFile: endpointFile, atomically: true, encoding: .utf8)
    } catch {
        fail("cannot write \(endpointFile): \(error)")
    }
} else {
    do {
        mount = try run("/sbin/mount", ["-F", "-t", FusettaHandshake.fsShortName] + (config.readOnly ? ["-r"] : [])
                        + [url, URL(fileURLWithPath: mountPoint).resolvingSymlinksInPath().path], stderr: mountOutput)
    } catch {
        fail("cannot run mount: \(error)")
    }
}

// Wait for the extension, until mount(8) gives up, libfuse goes away, or we
// time out. The service goes away after the first good handshake.
let parent = getppid()
let deadline = Date().addingTimeInterval(60)
var channel: Int32 = -1
while channel < 0 {
    if let mount, !mount.isRunning { mountFailed(mount, output: mountOutput, prefix: target.prefix) }
    if getppid() != parent || Date() > deadline {
        mount?.terminate()
        fail(getppid() != parent ? "libfuse went away" : "the Fusetta extension did not connect")
    }
    switch server.accept(config: configData, timeoutMS: 250, authorize: {
        HandshakeServer.peer($0, satisfies: target.requirement)
    }) {
    case .connected(let fd): channel = fd
    case .refused(let pid, let reason): warn("refused pid \(pid): \(reason)")
    case .timedOut: continue
    }
}
server.invalidate()

// Like mount(2), report success only once the volume exists. The extension
// activates it without waiting for the file system (requests queue on the
// channel until libfuse's session loop runs), so this cannot deadlock.
if let mount {
    mount.waitUntilExit()
    if mount.terminationStatus != 0 { mountFailed(mount, output: mountOutput, prefix: target.prefix) }
}
guard send(fd: channel, over: commFD) else { fail("cannot pass the channel to libfuse: \(String(cString: strerror(errno)))") }
exit(0)
