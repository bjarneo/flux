import Foundation
import Darwin

/// POSIX sockets for discovery + accept. `Network.framework` cannot express
/// the acceptor's plaintext-first upgrade (see `SecureTransport.swift`), so
/// the M1b link uses BSD sockets with `SO_REUSEADDR`/`SO_BROADCAST`, mirroring
/// Go `provider.go` (`reuseAddr`) and the 1716–1764 port scan.
public enum Sockets {
    public enum SocketError: Error, Equatable {
        case unavailable(Int32)
        case timeout
        case closed
    }

    /// Framing errors shared by the raw (pre-TLS) and TLS line readers.
    public enum TLSFramingError: Error, Equatable {
        case lineTooLong
        case ioFailed(Int32)
    }

    // MARK: - TCP listener

    /// Binds the first free port in `first...max` (Go parity: 1716–1764).
    /// Returns the fd and the bound port.
    public static func listenTCP(first: Int = Lan.minTCPPort, max: Int = Lan.maxTCPPort) throws -> (fd: Int32, port: Int) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.unavailable(errno) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        for port in first...max {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(port).bigEndian
            addr.sin_addr.s_addr = INADDR_ANY
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if bound == 0 {
                listen(fd, 16)
                return (fd, port)
            }
        }
        Darwin.close(fd)
        throw SocketError.unavailable(EADDRINUSE)
    }

    /// Accepts one connection, waiting up to `timeout` seconds.
    public static func accept(fd: Int32, timeout: TimeInterval = 10) throws -> Int32 {
        var fds = fd_set()
        fdZero(&fds)
        fdSet(fd, &fds)
        var tv = timeval(tv_sec: Int(ceil(timeout)), tv_usec: 0)
        let r = select(fd + 1, &fds, nil, nil, &tv)
        if r < 0 { throw SocketError.unavailable(errno) }
        if r == 0 { throw SocketError.timeout }
        var addr = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let c = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.accept(fd, $0, &len) }
        }
        if c < 0 { throw SocketError.unavailable(errno) }
        return c
    }

    // MARK: - UDP discovery

    /// Opens the discovery socket: bound on `port`, broadcast-capable,
    /// address-reusable (coexists with other local listeners via REUSEPORT
    /// where supported).
    public static func discoverySocket(port: Int = Lan.udpPort) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw SocketError.unavailable(errno) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let e = errno
            Darwin.close(fd)
            throw SocketError.unavailable(e)
        }
        return fd
    }

    /// Sends one datagram to `host:port`.
    public static func sendTo(fd: Int32, data: Data, host: String, port: Int) throws {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { throw SocketError.unavailable(EINVAL) }
        let n = data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, ptr.baseAddress, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if n < 0 { throw SocketError.unavailable(errno) }
    }

    /// Receives one datagram, waiting up to `timeout` seconds.
    /// Returns the payload and the sender's IP string.
    public static func receiveFrom(fd: Int32, timeout: TimeInterval = 5) throws -> (Data, String)? {
        var fds = fd_set()
        fdZero(&fds)
        fdSet(fd, &fds)
        var tv = timeval(tv_sec: Int(timeout), tv_usec: __darwin_suseconds_t((timeout.truncatingRemainder(dividingBy: 1)) * 1_000_000))
        let r = select(fd + 1, &fds, nil, nil, &tv)
        if r < 0 { throw SocketError.unavailable(errno) }
        if r == 0 { return nil }
        var buf = Data(count: 65536)
        var addr = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let n = buf.withUnsafeMutableBytes { (ptr: UnsafeMutableRawBufferPointer) in
            withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, ptr.baseAddress, 65536, 0, $0, &len)
                }
            }
        }
        if n <= 0 { return nil }
        buf.count = n
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = getnameinfo($0, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            }
        }
        return (buf, String(decoding: host[..<(host.firstIndex(of: 0) ?? host.endIndex)].map { UInt8(bitPattern: $0) }, as: UTF8.self))
    }

    public static func close(_ fd: Int32) {
        Darwin.close(fd)
    }

    /// Returns the remote IP of a connected socket (the classic-fetch host).
    public static func peerAddress(fd: Int32) -> String? {
        var addr = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        guard withUnsafeMutablePointer(to: &addr, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getpeername(fd, $0, &len)
            }
        }) == 0 else { return nil }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard withUnsafePointer(to: &addr, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            }
        }) == 0 else { return nil }
        return String(decoding: host[..<(host.firstIndex(of: 0) ?? host.endIndex)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    // MARK: - Raw line reader (pre-TLS plaintext phase)

    /// Reads one `\n`-terminated line byte-at-a-time (never over-reads, so
    /// the TLS handshake starts on a clean stream — Go `provider.go accept()`
    /// parity: `readLine` + "TLS handshake must start on a clean stream").
    public static func readRawLine(fd: Int32, max: Int) throws -> Data? {
        var line = Data()
        var byte: UInt8 = 0
        while true {
            let n = recv(fd, &byte, 1, 0)
            if n == 1 {
                if byte == 0x0A { return trim(line) }
                line.append(byte)
                if line.count > max { throw TLSFramingError.lineTooLong }
            } else if n == 0 {
                return line.isEmpty ? nil : trim(line)
            } else {
                if errno == EINTR { continue }
                throw TLSFramingError.ioFailed(errno)
            }
        }
    }

    private static func trim(_ line: Data) -> Data {
        var d = line
        while let last = d.last, last == 0x0A || last == 0x0D { d.removeLast() }
        return d
    }

    // MARK: - fd_set helpers (the FD_ZERO/FD_SET macros are not imported into Swift)

    public static func fdZero(_ set: inout fd_set) {
        memset(&set, 0, MemoryLayout<fd_set>.size)
    }

    public static func fdSet(_ fd: Int32, _ set: inout fd_set) {
        withUnsafeMutableBytes(of: &set) { ptr in
            let words = ptr.bindMemory(to: Int32.self)
            let i = Int(fd) / 32
            let bit = Int(fd) % 32
            if i >= 0, i < words.count {
                words[i] |= Int32(bitPattern: 1 << UInt32(bit))
            }
        }
    }

    /// True when select() marked `fd` readable (the FD_ISSET macro).
    public static func fdIsSet(_ fd: Int32, _ set: fd_set) -> Bool {
        withUnsafeBytes(of: set) { ptr in
            let words = ptr.bindMemory(to: Int32.self)
            let i = Int(fd) / 32
            let bit = Int(fd) % 32
            guard i >= 0, i < words.count else { return false }
            return words[i] & Int32(bitPattern: 1 << UInt32(bit)) != 0
        }
    }
}
