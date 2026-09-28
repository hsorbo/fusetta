// Fusetta - an open source FUSE implementation for macOS on top of FSKit.
// Copyright (C) 2026 Håvard Sørbø <havard@hsorbo.no>
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

public enum SocketIO {
    public static func writeAllv(_ fd: Int32, _ parts: [UnsafeRawBufferPointer]) throws {
        var iov = parts.filter { $0.count > 0 }.map {
            iovec(iov_base: UnsafeMutableRawPointer(mutating: $0.baseAddress), iov_len: $0.count)
        }
        var index = 0
        while index < iov.count {
            let n = iov[index...].withUnsafeMutableBufferPointer {
                Darwin.writev(fd, $0.baseAddress, Int32(min($0.count, Int(IOV_MAX))))
            }
            if n < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw FUSEError(errno)
            }
            var left = n
            while left > 0 && index < iov.count {
                if left >= iov[index].iov_len {
                    left -= iov[index].iov_len
                    index += 1
                } else {
                    iov[index].iov_base = iov[index].iov_base.advanced(by: left)
                    iov[index].iov_len -= left
                    left = 0
                }
            }
        }
    }

    /// Reads exactly `count` bytes. Returns false on a clean EOF before any byte.
    public static func readExact(_ fd: Int32, _ buf: UnsafeMutableRawPointer, _ count: Int) throws -> Bool {
        var off = 0
        while off < count {
            let n = Darwin.read(fd, buf + off, count - off)
            if n < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw FUSEError(errno)
            }
            if n == 0 {
                if off == 0 { return false }
                throw FUSEError(ECONNRESET)
            }
            off += n
        }
        return true
    }

    public static func setNoSigPipe(_ fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    public static func setBufferSizes(_ fd: Int32, _ size: Int32) {
        var s = size
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &s, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &s, socklen_t(MemoryLayout<Int32>.size))
    }
}
