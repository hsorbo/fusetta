// swift-tools-version: 6.2
//
// Fusetta - an open source FUSE implementation for macOS on top of FSKit.
// Copyright (C) 2026 Håvard Sørbø <havard@hsorbo.no>
// SPDX-License-Identifier: GPL-2.0-only

import PackageDescription

let package = Package(
    name: "fusetta",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "FusettaCore", targets: ["FusettaCore"]),
        .executable(name: "fusetta-probe", targets: ["fusetta-probe"]),
        .executable(name: "fusermount3", targets: ["fusermount3"]),
    ],
    targets: [
        // FUSE wire protocol, transport and the kernel-side client session.
        // Shared by the FSKit extension, fusermount3, the probe and the tests.
        .target(name: "FusettaCore"),

        // The mount helper libfuse runs (lib/mount_darwin.c in
        // patches/libfuse-3.18.3-darwin.patch):
        // mounts through FSKit and hands libfuse the FUSE channel. Shipped
        // inside Fusetta.app next to the extension.
        .executableTarget(
            name: "fusermount3",
            dependencies: ["FusettaCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        // Debug tool: plays the role of the kernel against a FUSE file system
        // without FSKit (ls/cat/stat over the FUSE protocol).
        .executableTarget(
            name: "fusetta-probe",
            dependencies: ["FusettaCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        .testTarget(
            name: "FusettaCoreTests",
            dependencies: ["FusettaCore"]
        ),
    ]
)
