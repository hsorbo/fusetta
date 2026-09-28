// Fusetta - an open source FUSE implementation for macOS on top of FSKit.
// Copyright (C) 2026 Håvard Sørbø <havard@hsorbo.no>
// SPDX-License-Identifier: GPL-2.0-only
//
// Each mount is an FSGenericURLResource "fusetta://mach/<service>" (see
// FusettaCore/Handshake.swift).

import ExtensionFoundation
import FSKit
import FusettaCore

@main
struct FusettaExtension: UnaryFileSystemExtension {
    var fileSystem: FusettaFileSystem { FusettaFileSystem.shared }
}

final class FusettaFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations, @unchecked Sendable {
    static let shared = FusettaFileSystem()

    private let lock = NSLock()
    private var volumes: [String: FUSEVolume] = [:]

    private static func endpoint(_ resource: FSResource) -> FusettaEndpoint? {
        guard let r = resource as? FSGenericURLResource else { return nil }
        return FusettaEndpoint(url: r.url)
    }

    func probeResource(resource: FSResource, replyHandler reply: @escaping @Sendable (FSProbeResult?, (any Error)?) -> Void) {
        guard let endpoint = Self.endpoint(resource) else {
            reply(.notRecognized, nil)
            return
        }
        // For a unary file system the container and volume identifiers match.
        reply(.usable(name: FusettaHandshake.fsShortName, containerID: FSContainerIdentifier(uuid: endpoint.volumeUUID)), nil)
    }

    func loadResource(resource: FSResource, options: FSTaskOptions, replyHandler reply: @escaping @Sendable (FSVolume?, (any Error)?) -> Void) {
        guard let endpoint = Self.endpoint(resource) else {
            reply(nil, fs_errorForPOSIXError(EINVAL))
            return
        }
        Task {
            do {
                let volume = try await FUSEVolume.connect(endpoint: endpoint)
                lock.withLock { volumes[endpoint.id] = volume }
                containerStatus = .ready
                reply(volume, nil)
            } catch {
                log.error("loadResource \(endpoint.url.absoluteString, privacy: .private) failed: \(String(describing: error), privacy: .public)")
                reply(nil, FUSEVolume.nsError(error))
            }
        }
    }

    func unloadResource(resource: FSResource, options: FSTaskOptions, replyHandler reply: @escaping @Sendable ((any Error)?) -> Void) {
        if let endpoint = Self.endpoint(resource) {
            let volume = lock.withLock { volumes.removeValue(forKey: endpoint.id) }
            volume?.shutdown()
        }
        reply(nil)
    }

    func didFinishLoading() {
        log.info("fusetta FSKit module loaded")
    }
}
