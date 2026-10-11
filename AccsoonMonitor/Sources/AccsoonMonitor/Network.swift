import CoreWLAN
import Darwin
import Foundation
import SystemConfiguration

/// Where the transmitter is: the router of the Wi-Fi interface.
struct Route: Equatable {
    var host: String
    /// Interface to pin sockets to, so a VPN's default route cannot hijack the traffic.
    var interface: String?
}

enum RouteFinder {
    /// The Wi-Fi interface's router, read per interface rather than from the default route.
    static func wifiRoute() -> Route? {
        guard let store = SCDynamicStoreCreate(nil, "AccsoonMonitor" as CFString, nil, nil),
              let all = SCDynamicStoreCopyMultiple(store, nil, ["State:/Network/Service/.*/IPv4"] as CFArray)
                as? [String: [String: Any]]
        else { return nil }
        let routes = all.values.compactMap { entry -> Route? in
            guard let router = entry["Router"] as? String, let name = entry["InterfaceName"] as? String else { return nil }
            return Route(host: router, interface: name)
        }
        let wifi = CWWiFiClient.shared().interface()?.interfaceName
        return routes.first { $0.interface == wifi } ?? routes.first { $0.interface?.hasPrefix("en") == true }
    }
}

enum Sockets {
    private static func address(_ host: String, _ port: UInt16) -> sockaddr_in? {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return nil }
        return addr
    }

    private static func pin(_ fd: Int32, to interface: String?) {
        guard let interface else { return }
        var index = if_nametoindex(interface)
        guard index != 0 else { return }
        setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size))
    }

    private static func setTimeout(_ fd: Int32, _ option: Int32, _ seconds: Double) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, option, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// One short TCP exchange: connect, send, read one reply, close. Nil on any failure.
    static func exchange(_ route: Route, port: UInt16, request: Data, timeout: Double = 0.8) -> Data? {
        guard var addr = address(route.host, port) else { return nil }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        pin(fd, to: route.interface)
        var on: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        // Non-blocking connect so an unreachable transmitter costs `timeout`, not 75 s.
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if result != 0 {
            guard errno == EINPROGRESS else { return nil }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&pfd, 1, Int32(timeout * 1000)) == 1 else { return nil }
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
            guard error == 0 else { return nil }
        }
        _ = fcntl(fd, F_SETFL, flags)
        setTimeout(fd, SO_SNDTIMEO, timeout)
        setTimeout(fd, SO_RCVTIMEO, 1.0)

        let sent = request.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, request.count, 0) }
        guard sent == request.count else { return nil }
        var buffer = [UInt8](repeating: 0, count: 128)
        let count = recv(fd, &buffer, buffer.count, 0)
        return count > 0 ? Data(buffer[0..<count]) : nil
    }

    /// A UDP socket bound to `port` on all addresses, with a short receive timeout.
    static func udpSocket(port: UInt16, interface: String?) -> Int32? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var size: Int32 = 2 << 20
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        setTimeout(fd, SO_RCVTIMEO, 0.1)
        pin(fd, to: interface)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    /// Receives one datagram. Returns the byte count (<= 0 on timeout or error) and fills `sender`.
    static func receive(_ fd: Int32, into buffer: inout [UInt8], sender: inout sockaddr_in) -> Int {
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        return withUnsafeMutablePointer(to: &sender) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &length) }
        }
    }

    /// Sends `data` to the sender's address on `port`.
    static func send(_ fd: Int32, _ data: Data, to sender: sockaddr_in, port: UInt16) {
        var addr = sender
        addr.sin_port = port.bigEndian
        data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    _ = sendto(fd, bytes.baseAddress, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }
}
