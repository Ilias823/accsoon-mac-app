import Foundation

/// Wire formats of the CineEye / CineEye Air link. See docs/protocol.md.
/// All fields are little-endian and packed.
public enum Wire {
    public static let tcpPort: UInt16 = 8001
    public static let udpPort: UInt16 = 8000

    static let tcpBegin = Array("ACCSOON".utf8)
    static let tcpHeaderSize = 17
    static let cmdControl: UInt16 = 1
    static let subCmdStationOp: UInt16 = 10

    static let prefixSize = 8
    static let dataHeaderSize = 14
    static let mainChannelVideo: UInt8 = 1
    static let typeControl: UInt8 = 0
    static let typeData: UInt8 = 1
    static let instructAck: UInt16 = 0
    static let instructRequest: UInt16 = 1
    static let instructEnd: UInt16 = 2
    static let controlHeaderSize = 10

    /// The TCP request that starts the stream and keeps it alive (`start == true`), or stops it.
    public static func stationOp(start: Bool, channel: UInt8 = 0, pid: UInt16 = 1) -> Data {
        var out = Data(tcpBegin)
        out.appendLE(pid)
        out.appendLE(cmdControl)
        out.appendLE(subCmdStationOp)
        out.appendLE(UInt32(2))
        out.append(start ? 1 : 0)
        out.append(channel)
        return out
    }

    static let subCmdGetAccessPoint: UInt16 = 22
    static let subCmdSetAccessPoint: UInt16 = 24

    private static func control(_ subCmd: UInt16, payload: Data = Data(), pid: UInt16 = 1) -> Data {
        var out = Data(tcpBegin)
        out.appendLE(pid)
        out.appendLE(cmdControl)
        out.appendLE(subCmd)
        out.appendLE(UInt32(payload.count))
        out.append(payload)
        return out
    }

    /// Asks for the transmitter's Wi-Fi name, password and channel.
    public static func accessPointRequest() -> Data {
        control(subCmdGetAccessPoint)
    }

    /// Sets the transmitter's Wi-Fi name, password and channel. The three always travel together,
    /// so to change one, send the other two exactly as `accessPointRequest` reported them.
    /// Returns nil unless all three pass the same checks the original app applies.
    public static func setAccessPoint(_ ap: AccessPoint) -> Data? {
        guard ap.isValid else { return nil }
        return control(subCmdSetAccessPoint, payload: Data("name=\(ap.name)\nkey=\(ap.password)\nchannel=\(ap.channel)".utf8))
    }

    /// Reads the settings out of a reply to either request. Also returns the reply's sub-command.
    public static func accessPoint(fromReply reply: Data) -> (accessPoint: AccessPoint, subCmd: UInt16)? {
        let bytes = [UInt8](reply)
        guard isValidReply(reply) else { return nil }
        let length = Int(bytes.readLE(UInt32.self, at: 13))
        guard length > 0, bytes.count >= tcpHeaderSize + length,
              let text = String(bytes: bytes[tcpHeaderSize..<tcpHeaderSize + length], encoding: .utf8)
        else { return nil }
        let lines = text.components(separatedBy: "\n")
        guard lines.count == 3, lines[0].hasPrefix("name="), lines[1].hasPrefix("key="), lines[2].hasPrefix("channel="),
              let channel = Int(lines[2].dropFirst(8).trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        let ap = AccessPoint(name: String(lines[0].dropFirst(5)), password: String(lines[1].dropFirst(4)), channel: channel)
        return (ap, bytes.readLE(UInt16.self, at: 11))
    }

    /// True if `reply` is a well-formed control frame from the transmitter.
    public static func isValidReply(_ reply: Data) -> Bool {
        let bytes = [UInt8](reply)
        guard bytes.count >= tcpHeaderSize, Array(bytes[0..<7]) == tcpBegin else { return false }
        return bytes.readLE(UInt16.self, at: 9) == cmdControl
    }

    /// Whether the transmitter's keep-alive reply says it has a video signal to send.
    /// Nil if the reply does not carry the three status bytes seen on a CineEye Air.
    public static func replyReportsVideo(_ reply: Data) -> Bool? {
        let bytes = [UInt8](reply)
        guard isValidReply(reply), bytes.count >= tcpHeaderSize + 3 else { return nil }
        return bytes[tcpHeaderSize + 1] != 0
    }

    static func ack(vid: UInt32, pid: UInt16, mainChannel: UInt8, subChannel: UInt8, messageID: UInt16) -> Data {
        var out = Data()
        out.appendLE(vid)
        out.appendLE(pid)
        out.appendLE(UInt16(mainChannel & 3) | UInt16(subChannel & 3) << 2)
        out.appendLE(instructAck)
        out.appendLE(messageID)
        return out
    }

    /// Asks the transmitter to resend fragments of a message. Layout as the original app
    /// builds it (never observed on the wire): the count byte is the list's length in
    /// bytes, and each missing fragment index is a 32-bit integer.
    static func retransmitRequest(vid: UInt32, pid: UInt16, mainChannel: UInt8, subChannel: UInt8,
                                  messageID: UInt16, missing: [Int]) -> Data {
        let list = missing.prefix(63)
        var out = Data()
        out.appendLE(vid)
        out.appendLE(pid)
        out.appendLE(UInt16(mainChannel & 3) | UInt16(subChannel & 3) << 2)
        out.appendLE(instructRequest)
        out.appendLE(messageID)
        out.append(UInt8(list.count * 4))
        for index in list { out.appendLE(UInt32(index)) }
        return out
    }
}

/// The transmitter's Wi-Fi access point settings.
public struct AccessPoint: Equatable {
    /// The 5 GHz channels the original app offers.
    public static let channels = [36, 40, 44, 48, 149, 153, 157, 161, 165]

    public var name: String
    public var password: String
    public var channel: Int

    public init(name: String, password: String, channel: Int) {
        self.name = name
        self.password = password
        self.channel = channel
    }

    /// The original app's rules: name 1–12 printable ASCII characters, password 8–12 digits,
    /// channel from the list above.
    public var isValid: Bool {
        (1...12).contains(name.utf8.count) && name.utf8.allSatisfy { (0x20..<0x7F).contains($0) }
            && (8...12).contains(password.utf8.count) && password.utf8.allSatisfy { (0x30...0x39).contains($0) }
            && Self.channels.contains(channel)
    }
}

/// The 16-bit control field in every datagram.
public struct ControlField: Equatable {
    public let raw: UInt16
    public var mainChannel: UInt8 { UInt8(raw & 3) }
    public var subChannel: UInt8 { UInt8((raw >> 2) & 3) }
    public var type: UInt8 { UInt8((raw >> 4) & 15) }
    public var retransmitEnabled: Bool { raw & (1 << 8) != 0 }
    /// Set on fragments that are being sent again.
    public var isRetransmission: Bool { raw & (1 << 9) != 0 }
    public var ackEnabled: Bool { raw & (1 << 10) != 0 }
}

/// The 23-byte header at the start of every reassembled video message.
public struct VideoHeader: Equatable {
    public static let size = 23

    public let width: Int
    public let height: Int
    public let bitrateKbps: Int
    public let frameRate: Int
    public let stationCount: Int
    /// The transmitter's own link quality figure. Its scale is not understood yet.
    public let quality: Float
    public let frameID: UInt32
    public let isKeyframe: Bool
    public let payloadLength: Int

    init?(_ bytes: [UInt8]) {
        guard bytes.count >= Self.size else { return nil }
        width = Int(bytes.readLE(UInt16.self, at: 0))
        height = Int(bytes.readLE(UInt16.self, at: 2))
        bitrateKbps = Int(bytes.readLE(UInt32.self, at: 4))
        frameRate = Int(bytes[8])
        stationCount = Int(bytes[9])
        quality = Float(bitPattern: bytes.readLE(UInt32.self, at: 10))
        frameID = bytes.readLE(UInt32.self, at: 14)
        isKeyframe = bytes[18] == 0
        payloadLength = Int(bytes.readLE(UInt32.self, at: 19))
    }
}

public struct VideoFrame {
    public let header: VideoHeader
    /// H.264 Annex-B. A keyframe carries SPS, PPS, SEI and the IDR slice.
    public let payload: Data
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

extension Array where Element == UInt8 {
    func readLE<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self)) }
    }
}
