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
