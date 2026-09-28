// Fusetta - an open source FUSE implementation for macOS on top of FSKit.
// Copyright (C) 2026 Håvard Sørbø <havard@hsorbo.no>
// SPDX-License-Identifier: GPL-2.0-only
//
// macOS only discovers file system extensions inside an app bundle. Nothing
// needs the app running: fusermount3 mounts and fskitd loads the extension.
// So the app is a setup checklist that quits when its window closes, and
// fusermount3 opens it when a mount fails because the extension is off.

import AppKit
import CoreServices
import FSKit
import SwiftUI

@main
struct FusettaApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        Window("Fusetta", id: "setup") {
            SetupView()
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// MARK: - What is set up

@MainActor @Observable
final class Setup {
    enum Extension: Equatable {
        case checking
        case missing
        /// Registered from another bundle, which keeps the Settings switch
        /// from sticking.
        case otherCopy(String)
        case disabled
        case enabled
        case failed(String)
    }

    enum Helper: Equatable {
        case checking
        case missing
        case installed(String)
        /// A fusermount3 libfuse would run instead of ours: (path, what it is).
        case foreign(String, String)
    }

    var inApplications = Setup.isInApplications
    var ext: Extension = .checking
    var helper: Helper = .checking
    var helperError: String?
    private var triedRegistering = false

    var isComplete: Bool {
        guard inApplications, ext == .enabled, case .installed = helper else { return false }
        return true
    }

    static let extensionBundleID = Bundle.main.bundleIdentifier.map { "\($0).fsmodule" } ?? ""
    static let bundledHelper = Bundle.main.url(forAuxiliaryExecutable: "fusermount3")?.resolvingSymlinksInPath()
    /// Where libfuse looks for fusermount3 when it is not in $PATH
    /// (mount_darwin.c), which is always the case under launchd.
    static let helperDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]

    static var isInApplications: Bool {
        let dir = Bundle.main.bundleURL.resolvingSymlinksInPath().deletingLastPathComponent().path
        return dir == "/Applications"
            || dir == FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications").path
    }

    func refresh() async {
        inApplications = Self.isInApplications
        ext = await fetchExtension()
        if ext == .missing, inApplications, !triedRegistering {
            // LaunchServices registers apps on launch, but may not have
            // picked the extension up yet.
            triedRegistering = true
            LSRegisterURL(Bundle.main.bundleURL as CFURL, true)
            ext = await fetchExtension()
        }
        helper = findHelper()
    }

    private func fetchExtension() async -> Extension {
        let modules: [FSModuleIdentity]
        do {
            modules = try await FSClient.shared.installedExtensions
        } catch {
            return .failed(error.localizedDescription)
        }
        guard let module = modules.first(where: { $0.bundleIdentifier == Self.extensionBundleID }) else {
            return .missing
        }
        if module.isEnabled { return .enabled }
        let ours = Bundle.main.bundleURL.resolvingSymlinksInPath().path + "/"
        let url = module.url.resolvingSymlinksInPath()
        return url.path.hasPrefix(ours) ? .disabled : .otherCopy(url.path)
    }

    private func findHelper() -> Helper {
        let fm = FileManager.default
        for dir in Self.helperDirectories {
            let path = dir + "/fusermount3"
            guard (try? fm.attributesOfItem(atPath: path)) != nil else { continue }
            let target = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            if target == Self.bundledHelper { return .installed(path) }
            if !fm.fileExists(atPath: target.path) { return .foreign(path, "a broken link") }
            return .foreign(path, target.path == path ? "another program" : "a link to \(target.path)")
        }
        return .missing
    }

    /// Links fusermount3 from a directory libfuse searches, asking for an
    /// administrator password if that directory is not ours to write.
    func installHelper() {
        helperError = nil
        guard let bundled = Self.bundledHelper else {
            helperError = "fusermount3 is missing from Fusetta.app."
            return
        }
        let fm = FileManager.default
        let link: String
        switch helper {
        case .foreign(let path, _):
            guard (try? fm.destinationOfSymbolicLink(atPath: path)) != nil else {
                helperError = "\(path) is not a link; remove it first."
                return
            }
            link = path
        default:
            let dir = Self.helperDirectories.first { fm.fileExists(atPath: $0) } ?? Self.helperDirectories.last!
            link = dir + "/fusermount3"
        }
        let dir = (link as NSString).deletingLastPathComponent
        do {
            if fm.fileExists(atPath: dir), fm.isWritableFile(atPath: dir) {
                if (try? fm.destinationOfSymbolicLink(atPath: link)) != nil { try fm.removeItem(atPath: link) }
                try fm.createSymbolicLink(atPath: link, withDestinationPath: bundled.path)
            } else {
                try runAsAdministrator("mkdir -p \(shellQuoted(dir)) && ln -sf \(shellQuoted(bundled.path)) \(shellQuoted(link))")
            }
        } catch {
            helperError = error.localizedDescription
        }
        helper = findHelper()
    }

    private func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    private func runAsAdministrator(_ command: String) throws {
        let literal = command.replacingOccurrences(of: #"\"#, with: #"\\"#).replacingOccurrences(of: "\"", with: #"\""#)
        var error: NSDictionary?
        NSAppleScript(source: "do shell script \"\(literal)\" with administrator privileges")?.executeAndReturnError(&error)
        guard let error, error[NSAppleScript.errorNumber] as? Int != -128 else { return }  // -128: cancelled
        let message = error[NSAppleScript.errorMessage] as? String ?? "unknown error"
        throw NSError(domain: "Fusetta", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

// MARK: - The checklist

struct SetupView: View {
    @State private var setup = Setup()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Fusetta").font(.title.bold())
                    Text("FUSE for macOS, built on FSKit").foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 16) {
                locationRow
                extensionRow
                helperRow
            }

            Divider()
            footer
        }
        .padding(24)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            // Cheap, and catches the Settings switch while both windows are
            // on screen.
            while !Task.isCancelled {
                await setup.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await setup.refresh() }
        }
    }

    private var locationRow: some View {
        CheckRow(state: setup.inApplications ? .done : .todo,
                 title: "In the Applications folder",
                 detail: setup.inApplications
                    ? "macOS finds the file system extension inside Fusetta.app."
                    : "Move Fusetta.app to the Applications folder and open it from there.")
    }

    @ViewBuilder private var extensionRow: some View {
        let settings = Button("Open System Settings…") { _ = FSClient.shared.openFileSystemExtensionsSettings() }
        switch setup.ext {
        case .checking:
            CheckRow(state: .checking, title: "File system extension enabled", detail: "Checking…")
        case .enabled:
            CheckRow(state: .done, title: "File system extension enabled",
                     detail: "Fusetta is on under Login Items & Extensions › File System Extensions.")
        case .disabled:
            CheckRow(state: .todo, title: "File system extension enabled",
                     detail: "Turn on Fusetta under General › Login Items & Extensions › File System Extensions. If the switch turns itself off again, see the README.") {
                settings
            }
        case .otherCopy(let path):
            CheckRow(state: .todo, title: "File system extension enabled",
                     detail: "Another copy of Fusetta is registered (\(path)), which keeps the switch from staying on. Delete that copy, then enable the extension.") {
                settings
            }
        case .missing:
            CheckRow(state: .todo, title: "File system extension enabled",
                     detail: setup.inApplications
                        ? "macOS has not registered the extension yet. Quit Fusetta and open it again."
                        : "macOS registers the extension once Fusetta is in the Applications folder.")
        case .failed(let message):
            CheckRow(state: .todo, title: "File system extension enabled", detail: message) { settings }
        }
    }

    @ViewBuilder private var helperRow: some View {
        let title = "Mount helper installed"
        let install = Button(setup.helper == .missing ? "Install" : "Replace") { setup.installHelper() }
            .disabled(!setup.inApplications)
        let error = setup.helperError.map { "\n" + $0 } ?? ""
        switch setup.helper {
        case .checking:
            CheckRow(state: .checking, title: title, detail: "Checking…")
        case .installed(let path):
            CheckRow(state: .done, title: title, detail: "libfuse runs fusermount3 from \(path).")
        case .missing:
            CheckRow(state: .todo, title: title,
                     detail: "libfuse needs fusermount3 from Fusetta.app in /opt/homebrew/bin or /usr/local/bin." + error) {
                install
            }
        case .foreign(let path, let what):
            CheckRow(state: .todo, title: title,
                     detail: "\(path) is \(what), not the one in this Fusetta.app." + error) {
                install
            }
        }
    }

    @ViewBuilder private var footer: some View {
        if setup.isComplete {
            VStack(alignment: .leading, spacing: 6) {
                Text("All set. Fusetta doesn’t need to stay open; mount file systems as usual:")
                Text("sshfs host: ~/mnt/host")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
        } else {
            Text("If a mount fails because Fusetta isn’t set up, this window opens again.")
                .foregroundStyle(.secondary)
        }
    }
}

struct CheckRow<Accessory: View>: View {
    enum State { case checking, done, todo }

    let state: State
    let title: String
    let detail: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            icon.frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 12)
            accessory
        }
    }

    @ViewBuilder private var icon: some View {
        switch state {
        case .checking: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .todo: Image(systemName: "circle.dashed").foregroundStyle(.orange)
        }
    }
}

extension CheckRow where Accessory == EmptyView {
    init(state: State, title: String, detail: String) {
        self.init(state: state, title: title, detail: detail) { EmptyView() }
    }
}
