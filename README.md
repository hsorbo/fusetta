<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/logo-dark.png">
    <img src="docs/logo.png" alt="Fusetta" width="480">
  </picture>
</p>

# Fusetta

FUSE for macOS, built on Apple's FSKit. Fusetta is fully open source under
the GPL-2.0 (see [License](#license)). It runs upstream libfuse 3 with a small
macOS mount backend and needs no kernel extension.

File systems written against libfuse 3 (sshfs, gocryptfs, s3fs, …) build and
run unmodified. libfuse 2 is not supported.

> Status: early. Live FSKit mounts of the libfuse examples work on macOS 27
> (read/write, rename, symlinks, xattrs, chmod, truncate, 20 MB copies, clean
> unmount from either side), and the protocol layer is covered by tests that
> run real libfuse file systems.

## Installing with Homebrew

Needs macOS 27 or newer.

```sh
brew tap hsorbo/tap
brew trust hsorbo/tap         # Homebrew only loads third-party taps you trust
brew install --cask fusetta   # Fusetta.app, with fusermount3 linked into Homebrew's bin
open -a Fusetta
```

The app shows a setup checklist: enable **fusetta** in System Settings ›
General › Login Items & Extensions › File System Extensions (it has a button
for this). The cask already installed the mount helper.

Then install a file system. The tap's sshfs is built against its libfuse,
which has the Fusetta mount backend:

```sh
brew install hsorbo/tap/sshfs
mkdir -p ~/mnt/remote
sshfs user@host: ~/mnt/remote
umount ~/mnt/remote
```

Other libfuse 3 file systems build unmodified against
`brew install hsorbo/tap/libfuse` (`pkg-config fuse3`). If the System Settings
switch will not stay on, see [Installing and using](#installing-and-using).

## How it works

```
 FUSE file system (sshfs, hello_ll, …)
   └─ upstream libfuse 3 + patches/libfuse-3.18.3-darwin.patch
        │ runs fusermount3, receives the FUSE channel (a socket)
        │   fusermount3 (in Fusetta.app): Mach rendezvous with the extension,
        │   mount -F -t fusetta, hands out the two ends of a socketpair
        │ FUSE wire protocol
        ▼
 FusettaFS.appex  (FSKit module, sandboxed)
   FSKit volume operations → FUSE requests (lookup/forget accounting,
   file handles, readdir(plus), xattrs, access, fallocate, lseek)
        ▲
        │ fskitd / LIFS (macOS)
 Kernel
```

1. The file system calls `fuse_session_mount()`. As on Linux without root,
   libfuse runs the mount helper, `fusermount3 -o <options> -- <mountpoint>`,
   and waits for it to pass back the FUSE channel over `$_FUSE_COMMFD`. The
   Darwin backend knows nothing else about Fusetta.
2. `fusermount3` registers a Mach service `<prefix>.<random>` with launchd and
   runs `mount -F -t fusetta fusetta://mach/<service> <mountpoint>` as the
   user. No root.
3. FSKit loads the Fusetta extension with that URL as an
   `FSGenericURLResource`. The extension looks the service up and says hello;
   `fusermount3` checks the sender's code signature (from the message's audit
   token) and hands it the mount options and one end of a `socketpair` (as a
   fileport). Once the volume is mounted, libfuse gets the other end and
   `fusermount3` exits.
4. From then on the extension plays the FUSE kernel module and libfuse runs
   its normal session loop on the socket (through libfuse's custom I/O).
5. `umount` makes the extension close the socket and the file system exits;
   stopping the file system makes libfuse drop the socket and run
   `fusermount3 -u`.

The sandboxed extension may only look up Mach services named under its app
group (`<TEAMID>.fusetta`), so `<prefix>` must be that group. `fusermount3`
reads it from the signature of the `FusettaFS.appex` it ships with, and only
hands the channel to a process satisfying that extension's designated
requirement. `FUSETTA_MACH_PREFIX=<group>` (or `-o fusetta_prefix=<group>`)
overrides the prefix. The service is only reachable by the user's own
processes and is dropped after the first successful handshake.

## Layout

| Path | What |
|------|------|
| `patches/libfuse-3.18.3-darwin.patch` | Portability fixes and the Darwin mount backend (`lib/mount_darwin.c`: runs `fusermount3`, reframes the stream); applied by `scripts/build-libfuse.sh` |
| `Sources/FusettaCore` | FUSE wire protocol, stream transport, typed FUSE session (the "kernel" side), handshake |
| `Sources/fusermount3` | The mount helper libfuse runs; shipped in `Fusetta.app/Contents/MacOS` |
| `Sources/fusetta-probe` | Debug tool: drives a FUSE file system without FSKit (`ls`, `cat`, `stat`, …) |
| `Extension/FSExtension` | The FSKit module (`FSUnaryFileSystem` + `FSVolume` v3 handlers) |
| `Extension/App` | Host app that carries the extension; a setup checklist `fusermount3` opens when the extension is off |
| `Tests/FusettaCoreTests` | Unit tests and end-to-end tests against real libfuse file systems |

## Requirements

- macOS 27 or newer (FSKit v3 handler API with caller credentials).
- Xcode 27, and for the extension a paid Apple Developer team: the
  `com.apple.developer.fskit.fsmodule` entitlement needs a provisioning profile.
- meson, ninja, cmake to build libfuse (`brew install meson ninja cmake`).
- xcodegen to generate the Xcode project from `Extension/project.yml`.

## Building

```sh
# upstream libfuse 3.18.3 (downloaded to build/) + the Darwin backend, into build/libfuse
scripts/build-libfuse.sh
PREFIX=/usr/local scripts/build-libfuse.sh install   # optional: libfuse3 + fuse3.pc

# protocol layer and probe; tests include libfuse end-to-end runs
swift build
swift test

# app + extension (signed with the team in Extension/Config/Local.xcconfig)
cp Extension/Config/Local.xcconfig.example Extension/Config/Local.xcconfig
$EDITOR Extension/Config/Local.xcconfig
scripts/build-app.sh
```

## Installing and using

1. Copy `Fusetta.app` to `/Applications` and open it. It shows a setup
   checklist and quits when you close it; nothing needs it running.
2. Enable **fusetta** in System Settings › General › Login Items &
   Extensions › File System Extensions (the app has a button for this).
3. Let the app install the mount helper, or put its `fusermount3` where
   libfuse finds it yourself: in `$PATH`, or in `/opt/homebrew/bin` or
   `/usr/local/bin`:

   ```sh
   ln -s /Applications/Fusetta.app/Contents/MacOS/fusermount3 /opt/homebrew/bin/
   ```
4. Run any file system linked against the libfuse built above:

   ```sh
   mkdir -p ~/mnt/hello
   build/libfuse/example/hello_ll ~/mnt/hello
   cat ~/mnt/hello/hello
   umount ~/mnt/hello
   ```

If a mount fails because the extension is off (or not registered),
`fusermount3` opens the app, unless the session has no screen (ssh).

If the System Settings switch bounces back to off (seen on macOS 27.0
26A428 for every FSKit extension, Apple's included), `mount` reports
`Module … is disabled!`. The switch only edits a list of bundle IDs, which
you can edit yourself:

```sh
f=~/Library/Group\ Containers/group.com.apple.fskit.settings/enabledModules.plist
cp "$f" ~/enabledModules.plist.bak
plutil -insert 0 -string <your-prefix>.Fusetta.fsmodule "$f"
killall -9 fskit_agent   # it caches the list and ignores SIGTERM; launchd restarts it
```

Only one copy of the app may be registered: a second bundle with the same
extension ID (e.g. Xcode's build output) also keeps the switch from sticking.
`scripts/build-app.sh` unregisters its build output for that reason.

Mount options (handled by `fusermount3`): `volname=`, `ro`, `appledouble`,
`noappledouble`. Linux-only kernel options (`allow_other`,
`default_permissions`, `fsname=`, …) are accepted and ignored; anything else
is an error.

### Debugging without FSKit

With `FUSETTA_ENDPOINT_FILE=<path>` in the environment, `fusermount3` skips
`mount(8)` and writes its endpoint to `<path>`; `fusetta-probe` then plays the
kernel (after `swift build`, which builds both):

```sh
printf 'ls /\ncat /hello\nstat /hello\n' | scripts/probe-fs.sh build/libfuse/example/hello_ll
```

## Limitations

Mostly inherited from FSKit:

- No ioctl, no byte-range/flock locks forwarded to the file system, no
  `copy_file_range`, no poll, no `mknod` of devices through FSKit's API.
- FUSE notifications (`inval_inode`, `inval_entry`, …) are received but
  cannot be acted on yet; FSKit keeps a negative lookup cache.
- No per-request pid (FSKit only exposes uid/gid).
- Open/close is per item, not per file descriptor: Fusetta keeps one FUSE
  file handle per item and widens it (read → read/write) when needed.
- FSKit only calls `synchronize` on URL volumes in some releases; fsync is
  forwarded when it is called.
- No creation time or BSD flags (Finder's hidden flag and friends): the FUSE
  protocol has no fields for them.
- If the file system process is killed, the volume stays mounted and returns
  errors until you `umount` it (as on Linux).
- Every user has to enable the extension once in System Settings.

## License

Fusetta is licensed under the GNU General Public License, version 2 (see
[LICENSE](LICENSE)). libfuse and `patches/libfuse-3.18.3-darwin.patch` are
under libfuse's LGPL-2.1.
