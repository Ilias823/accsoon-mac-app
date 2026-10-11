// Dependency-free checks for CineEyeProtocol. Exits non-zero on the first failure.
// Plain executable rather than a test target so it runs with the Command Line
// Tools alone: Scripts/build.sh builds and runs it.
import CineEyeProtocol
import CineEyeVideo
import Foundation

var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ what: String, line: UInt = #line) {
    checks += 1
    if !condition() {
        print("FAILED line \(line): \(what)")
        exit(1)
    }
}

func le<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
    withUnsafeBytes(of: value.littleEndian) { Array($0) }
}

func videoMessage(id: UInt32, keyframe: Bool, payload: [UInt8]) -> [UInt8] {
    le(UInt16(1920)) + le(UInt16(1080)) + le(UInt32(5760)) + [30, 1] + le(UInt32(0)) + le(id)
        + [keyframe ? 0 : 1] + le(UInt32(payload.count)) + payload
}

func datagrams(messageID: UInt16, message: [UInt8], fragmentSize: Int = 4082, ackEnabled: Bool = true) -> [[UInt8]] {
    let parts = stride(from: 0, to: message.count, by: fragmentSize).map {
        Array(message[$0..<min($0 + fragmentSize, message.count)])
    }
    let ctl: UInt16 = 1 | (1 << 4) | (1 << 8) | (ackEnabled ? 1 << 10 : 0)
    return parts.enumerated().map { index, part in
        le(UInt32(1)) + le(UInt16(1)) + le(ctl) + le(messageID) + [UInt8(parts.count), UInt8(index), 1, 0] + part
    }
}

// The keep-alive request, byte for byte as the real CineEye Air accepted it.
expect([UInt8](Wire.stationOp(start: true)) == Array("ACCSOON".utf8) + [1, 0, 1, 0, 10, 0, 2, 0, 0, 0, 1, 0], "start request bytes")
expect([UInt8](Wire.stationOp(start: false).suffix(2)) == [0, 0], "stop request payload")

// The reply captured from a CineEye Air on 2026-10-10.
expect(Wire.isValidReply(Data([0x41, 0x43, 0x43, 0x53, 0x4f, 0x4f, 0x4e, 1, 0, 1, 0, 0x0b, 0, 3, 0, 0, 0, 0, 1, 1])), "real reply accepted")
expect(!Wire.isValidReply(Data([1, 2, 3])), "short reply rejected")
expect(Wire.replyReportsVideo(Data(Array("ACCSOON".utf8) + [1, 0, 1, 0, 11, 0, 3, 0, 0, 0, 0, 1, 1])) == true, "reply says video present")
expect(Wire.replyReportsVideo(Data(Array("ACCSOON".utf8) + [1, 0, 1, 0, 11, 0, 3, 0, 0, 0, 0, 0, 0])) == false, "reply says no video")
expect(Wire.replyReportsVideo(Data(Array("ACCSOON".utf8) + [1, 0, 1, 0, 11, 0, 0, 0, 0, 0])) == nil, "reply without status bytes")
expect(!Wire.isValidReply(Data(repeating: 0x41, count: 20)), "wrong magic rejected")

func ctlBits(_ datagram: [UInt8]) -> UInt16 { UInt16(datagram[6]) | UInt16(datagram[7]) << 8 }

// Fragments in reverse order still produce the frame, and an ack.
do {
    let payload = (0..<10_000).map { UInt8($0 & 0xFF) }
    let grams = datagrams(messageID: 7, message: videoMessage(id: 42, keyframe: true, payload: payload))
    expect(grams.count == 3, "three fragments")
    var r = Reassembler()
    for g in grams.reversed().dropLast() {
        let early = r.push(g, now: 0)
        expect(early.frames.isEmpty && early.replies.isEmpty, "nothing before the last fragment")
    }
    let out = r.push(grams[0], now: 0)
    let frame = out.frames.first
    expect(out.frames.count == 1 && frame?.payload == Data(payload), "payload reassembled")
    expect(frame?.header.frameID == 42, "frame id")
    expect(frame?.header.isKeyframe == true, "keyframe flag")
    expect(frame?.header.width == 1920 && frame?.header.height == 1080, "size")
    expect(frame?.header.bitrateKbps == 5760 && frame?.header.frameRate == 30, "bitrate and fps")
    expect(out.replies == [Data([1, 0, 0, 0, 1, 0, 1, 0, 0, 0, 7, 0])], "ack bytes")
    expect(r.counters == Reassembler.Counters(), "no drops, no requests")
}

// No ack when the transmitter did not ask for one.
do {
    var r = Reassembler()
    let out = r.push(datagrams(messageID: 1, message: videoMessage(id: 1, keyframe: false, payload: [1, 2, 3]), ackEnabled: false)[0], now: 0)
    expect(out.frames.first?.header.isKeyframe == false && out.replies.isEmpty, "no ack without AckEN")
}

let big = Array(repeating: UInt8(9), count: 9000)   // three fragments
let small = Array(repeating: UInt8(8), count: 100)  // one fragment

// A lost fragment is requested once the next message starts; the retransmission completes it,
// and both frames come out in order.
do {
    let a = datagrams(messageID: 1, message: videoMessage(id: 1, keyframe: false, payload: big))
    let b = datagrams(messageID: 2, message: videoMessage(id: 2, keyframe: false, payload: small))
    var r = Reassembler(retransmitWindow: 0.05)
    expect(r.push(a[0], now: 0).frames.isEmpty, "incomplete")
    expect(r.push(a[0], now: 0).frames.isEmpty, "duplicate fragment ignored")
    expect(r.push(a[2], now: 0).frames.isEmpty, "still incomplete")
    let onNext = r.push(b[0], now: 0.033)
    expect(onNext.frames.isEmpty, "later frame is held while waiting")
    // prefix (VID 1, PID 1, video channel, control) + Instruct 1 + MsgID 1 + 4 bytes + fragment index 1
    expect(onNext.replies.first == Data([1, 0, 0, 0, 1, 0, 1, 0, 1, 0, 1, 0, 4, 1, 0, 0, 0]), "retransmit request bytes")
    expect(onNext.replies.count == 2, "request for the old message, ack for the new one")
    var resent = a[1]
    resent[7] |= 0x02  // ReTxFlag
    let recovered = r.push(resent, now: 0.040)
    expect(recovered.frames.map(\.header.frameID) == [1, 2], "both frames, in order")
    expect(r.counters == Reassembler.Counters(dropped: 0, requests: 1, retransmittedFragments: 1, recovered: 1), "counters after recovery")
    expect(r.push(b[0], now: 0.05).frames.isEmpty, "late duplicate of a finished message")
}

// If the retransmission never comes, the message is dropped after the window and the held frame is released.
do {
    let a = datagrams(messageID: 1, message: videoMessage(id: 1, keyframe: false, payload: big))
    let b = datagrams(messageID: 2, message: videoMessage(id: 2, keyframe: false, payload: small))
    var r = Reassembler(retransmitWindow: 0.05)
    _ = r.push(a[0], now: 0)
    expect(r.push(b[0], now: 0.033).frames.isEmpty, "held")
    expect(r.poll(now: 0.060).frames.isEmpty, "still inside the window")
    expect(r.poll(now: 0.090).frames.map(\.header.frameID) == [2], "released after the window")
    expect(r.counters.dropped == 1 && r.counters.requests == 1 && r.counters.recovered == 0, "one drop")
    expect(r.push(a[1], now: 0.1).frames.isEmpty && r.push(a[2], now: 0.1).frames.isEmpty, "fragments of a dropped message are ignored")
}

// With requests disabled (or ReTxEN clear) nothing is requested and nothing is held.
do {
    let a = datagrams(messageID: 1, message: videoMessage(id: 1, keyframe: false, payload: big))
    let b = datagrams(messageID: 2, message: videoMessage(id: 2, keyframe: false, payload: small))
    var r = Reassembler(retransmitWindow: 0)
    _ = r.push(a[0], now: 0)
    let out = r.push(b[0], now: 0.033)
    expect(out.frames.map(\.header.frameID) == [2] && out.replies.count == 1, "no request, immediate release")
    expect(r.counters.dropped == 1 && r.counters.requests == 0, "dropped without asking")

    var noRetx = Reassembler()
    var first = a[0], next = b[0]
    first[7] &= ~0x01; next[7] &= ~0x01  // clear ReTxEN
    _ = noRetx.push(first, now: 0)
    expect(noRetx.push(next, now: 0.033).frames.count == 1 && noRetx.counters.requests == 0, "ReTxEN clear: no request")
}

// An "end of message" control frame triggers the request too.
do {
    let a = datagrams(messageID: 5, message: videoMessage(id: 5, keyframe: false, payload: big))
    var r = Reassembler()
    _ = r.push(a[0], now: 0)
    let end = le(UInt32(1)) + le(UInt16(1)) + le(UInt16(1 | 1 << 8)) + le(UInt16(2)) + le(UInt16(5))
    let out = r.push(end, now: 0.01)
    expect(out.replies == [Data([1, 0, 0, 0, 1, 0, 1, 0, 1, 0, 5, 0, 8, 1, 0, 0, 0, 2, 0, 0, 0])], "request lists both missing fragments")
    expect(r.push(end, now: 0.02).replies.isEmpty, "asked only once")
}

// Junk, short datagrams and non-video channels are ignored.
do {
    var r = Reassembler()
    expect(r.push([], now: 0).frames.isEmpty && r.push([1, 2, 3], now: 0).frames.isEmpty, "short datagrams")
    let beacon = le(UInt32(1)) + le(UInt16(1)) + le(UInt16(0)) + le(UInt16(10)) + Array(repeating: UInt8(0), count: 12)
    let out = r.push(beacon, now: 0)
    expect(out.frames.isEmpty && out.replies.isEmpty, "beacon ignored")
    var bad = datagrams(messageID: 3, message: videoMessage(id: 3, keyframe: true, payload: [1]))[0]
    bad[11] = 200  // fragment index beyond the count
    expect(r.push(bad, now: 0).frames.isEmpty, "out-of-range fragment index")
}

// Annex-B splitting with both start code lengths, and on a slice with a non-zero start index.
do {
    let stream = Data([0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3, 0, 0, 0, 1, 0x65, 4, 5, 6])
    let units = AnnexB.nalUnits(in: stream)
    expect(units == [Data([0x67, 1, 2]), Data([0x68, 3]), Data([0x65, 4, 5, 6])], "units")
    expect(units.map(AnnexB.nalType) == [7, 8, 5], "types")
    expect(AnnexB.nalUnits(in: (Data([9, 9]) + stream).dropFirst(2)) == units, "slice")
    expect(AnnexB.nalUnits(in: Data([1, 2, 3])).isEmpty, "no start code")
}

// Capture file framing.
expect(readCapture(Data([2, 0, 0xAA, 0xBB, 1, 0, 0xCC, 9, 0, 1])) == [[0xAA, 0xBB], [0xCC]], "capture reader stops at a truncated record")

// Transmitter Wi-Fi settings.
do {
    let header = Array("ACCSOON".utf8) + [1, 0, 1, 0]
    expect([UInt8](Wire.accessPointRequest()) == header + [22, 0, 0, 0, 0, 0], "read request")
    let ap = AccessPoint(name: "CineEye_1234", password: "12345678", channel: 149)
    let text = Array("name=CineEye_1234\nkey=12345678\nchannel=149".utf8)
    expect(Wire.setAccessPoint(ap).map { [UInt8]($0) } == header + [24, 0, UInt8(text.count), 0, 0, 0] + text, "set request")
    let reply = Data(header + [23, 0, UInt8(text.count), 0, 0, 0] + text)
    expect(Wire.accessPoint(fromReply: reply)?.accessPoint == ap, "reply parsed")
    expect(Wire.accessPoint(fromReply: reply)?.subCmd == 23, "reply sub-command")
    expect(Wire.accessPoint(fromReply: Data(header + [11, 0, 3, 0, 0, 0, 0, 1, 1])) == nil, "stream reply is not settings")
    expect(Wire.accessPoint(fromReply: reply.dropLast(3)) == nil, "truncated reply rejected")
    // Anything the original app would refuse is never sent.
    expect(Wire.setAccessPoint(AccessPoint(name: "ok", password: "12345678", channel: 6)) == nil, "2.4 GHz channel refused")
    expect(Wire.setAccessPoint(AccessPoint(name: "ok", password: "1234567", channel: 36)) == nil, "short password refused")
    expect(Wire.setAccessPoint(AccessPoint(name: "ok", password: "abcdefgh", channel: 36)) == nil, "non-digit password refused")
    expect(Wire.setAccessPoint(AccessPoint(name: "", password: "12345678", channel: 36)) == nil, "empty name refused")
    expect(Wire.setAccessPoint(AccessPoint(name: "thirteen chars", password: "12345678", channel: 36)) == nil, "long name refused")
    expect(Wire.setAccessPoint(AccessPoint(name: "new\nline", password: "12345678", channel: 36)) == nil, "control character refused")
}

// .cube parsing.
do {
    let text = """
    # comment
    TITLE "test"
    LUT_3D_SIZE 2
    DOMAIN_MIN 0 0 0
    DOMAIN_MAX 1 1 1

    0 0 0
    1 0 0
    0 1 0
    1 1 0
    0 0 1
    1 0 1
    0 1 1
    1.5 1 -0.25
    """
    let lut = try? CubeLUT(text: text)
    expect(lut?.size == 2 && lut?.rgba.count == 32, "2x2x2 LUT")
    expect(lut.map { Array($0.rgba[4..<8]) } == [1, 0, 0, 1], "red changes fastest")
    expect(lut.map { Array($0.rgba[28..<32]) } == [1.5, 1, -0.25, 1], "out-of-range values kept")
    expect((try? CubeLUT(text: "LUT_3D_SIZE 2\n0 0 0\n")) == nil, "too few entries rejected")
    expect((try? CubeLUT(text: "LUT_1D_SIZE 4\n0 0 0\n")) == nil, "1D LUT rejected")
    expect((try? CubeLUT(text: "hello")) == nil, "garbage rejected")
}

print("protocol-check: \(checks) checks passed")
