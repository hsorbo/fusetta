// Fusetta - an open source FUSE implementation for macOS on top of FSKit.
// Copyright (C) 2026 Håvard Sørbø <havard@hsorbo.no>
// SPDX-License-Identifier: GPL-2.0-only
//
// macOS only discovers file system extensions inside an app bundle.

import FSKit
import SwiftUI

@main
struct FusettaApp: App {
    var body: some Scene {
        WindowGroup("Fusetta") {
            StatusView()
                .frame(minWidth: 520, minHeight: 300)
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
final class ExtensionStatus: ObservableObject {
    enum State: Equatable {
        case checking
        case missing
        case disabled
        case enabled
        case failed(String)
    }

    @Published var state: State = .checking

    static let extensionBundleID = Bundle.main.bundleIdentifier.map { "\($0).fsmodule" } ?? ""

    func refresh() {
        state = .checking
        FSClient.shared.fetchInstalledExtensions { modules, error in
            let newState: State
            if let error {
                newState = .failed(error.localizedDescription)
            } else if let module = modules?.first(where: { $0.bundleIdentifier == Self.extensionBundleID }) {
                newState = module.isEnabled ? .enabled : .disabled
            } else {
                newState = .missing
            }
            Task { @MainActor in self.state = newState }
        }
    }
}

struct StatusView: View {
    @StateObject private var status = ExtensionStatus()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Fusetta").font(.largeTitle.bold())
            Text("An open source FUSE for macOS, built on FSKit.")
                .foregroundStyle(.secondary)

            GroupBox("File system extension") {
                HStack {
                    statusLabel
                    Spacer()
                    Button("Open Settings…") { _ = FSClient.shared.openFileSystemExtensionsSettings() }
                    Button("Refresh") { status.refresh() }
                }
                .padding(4)
            }

            GroupBox("Using it") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Build FUSE file systems against libfuse 3 with the Fusetta mount backend, then run them as usual:")
                    Text("sshfs host: ~/mnt/host")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    Text("Unmount with umount, or by stopping the file system.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
            Spacer()
        }
        .padding(24)
        .onAppear { status.refresh() }
    }

    @ViewBuilder private var statusLabel: some View {
        switch status.state {
        case .checking:
            Label("Checking…", systemImage: "hourglass")
        case .enabled:
            Label("Enabled", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .disabled:
            Label("Installed but disabled: enable “Fusetta” under General › Login Items & Extensions › File System Extensions", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .missing:
            Label("Extension not registered. Move the app to /Applications and open it once.", systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }
}
