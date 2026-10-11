import Foundation

/// Turns video datagrams into complete frames, in order.
///
/// One encoded frame is one "message", split into numbered fragments. When a
/// newer message starts while an older one is still missing fragments, the
/// missing ones are requested again and later frames are held back for a short
/// window. If the gap is not filled in time the incomplete message is dropped.
public struct Reassembler {
    public struct Output {
        /// Completed frames, oldest first.
        public var frames: [VideoFrame] = []
        /// Acks and retransmit requests for the transmitter's UDP port. Send each twice, as the original app does.
        public var replies: [Data] = []
    }

    public struct Counters: Equatable {
        /// Messages given up on.
        public var dropped = 0
        /// Retransmit requests sent.
        public var requests = 0
        /// Fragments that arrived marked as retransmissions.
        public var retransmittedFragments = 0
        /// Messages that were incomplete, requested again, and then completed.
        public var recovered = 0

        public init(dropped: Int = 0, requests: Int = 0, retransmittedFragments: Int = 0, recovered: Int = 0) {
            self.dropped = dropped
            self.requests = requests
            self.retransmittedFragments = retransmittedFragments
            self.recovered = recovered
        }
    }

    public private(set) var counters = Counters()
    public var droppedMessages: Int { counters.dropped }

    /// How long later frames wait for a retransmission, in seconds. Zero disables requests.
    public var retransmitWindow: Double

    private struct Message {
        let id: UInt16
        let total: Int
        var fragments: [[UInt8]?]
        var received = 0
        var deadline: Double?
        var requested = false
        var frame: VideoFrame?
        var complete: Bool { received == total }
    }

    private var queue: [Message] = []
    private var finished: [UInt16] = []

    public init(retransmitWindow: Double = 0.05) {
        self.retransmitWindow = retransmitWindow
    }

    /// `now` is any monotonic clock in seconds.
    public mutating func push(_ datagram: [UInt8], now: Double) -> Output {
        var output = Output()
        accept(datagram, now: now, into: &output)
        deliver(now: now, into: &output)
        return output
    }

    private mutating func accept(_ datagram: [UInt8], now: Double, into output: inout Output) {
        guard datagram.count >= Wire.controlHeaderSize + 2 else { return }
        let ctl = ControlField(raw: datagram.readLE(UInt16.self, at: 6))
        guard ctl.mainChannel == Wire.mainChannelVideo else { return }

        if ctl.type == Wire.typeControl {
            // "End of message": the original app asks for missing fragments at this point.
            if datagram.readLE(UInt16.self, at: 8) == Wire.instructEnd,
               let index = queue.firstIndex(where: { $0.id == datagram.readLE(UInt16.self, at: 10) }),
               !queue[index].complete, !queue[index].requested {
                request(index, datagram: datagram, ctl: ctl, now: now, into: &output)
            }
            return
        }
        guard ctl.type == Wire.typeData, datagram.count >= Wire.dataHeaderSize else { return }

        let id = datagram.readLE(UInt16.self, at: 8)
        let total = Int(datagram[10])
        let fragment = Int(datagram[11])
        guard !finished.contains(id) else { return }

        var index = queue.firstIndex { $0.id == id }
        if index == nil {
            guard total > 0 else { return }
            // A newer message has started: anything older that is still incomplete has lost fragments.
            for older in queue.indices where !queue[older].complete && queue[older].deadline == nil {
                request(older, datagram: datagram, ctl: ctl, now: now, into: &output)
            }
            queue.append(Message(id: id, total: total, fragments: Array(repeating: nil, count: total)))
            index = queue.count - 1
        }
        guard let index, !queue[index].complete, fragment < queue[index].total,
              queue[index].fragments[fragment] == nil
        else { return }

        queue[index].fragments[fragment] = Array(datagram[Wire.dataHeaderSize...])
        queue[index].received += 1
        if ctl.isRetransmission { counters.retransmittedFragments += 1 }
        guard queue[index].complete else { return }

        if ctl.ackEnabled {
            output.replies.append(Wire.ack(
                vid: datagram.readLE(UInt32.self, at: 0), pid: datagram.readLE(UInt16.self, at: 4),
                mainChannel: ctl.mainChannel, subChannel: ctl.subChannel, messageID: id))
        }
        let message = queue[index].fragments.flatMap { $0! }
        queue[index].fragments = []
        if let header = VideoHeader(message) {
            let end = min(message.count, VideoHeader.size + header.payloadLength)
            queue[index].frame = VideoFrame(header: header, payload: Data(message[VideoHeader.size..<end]))
        }
        return
    }

    /// Call when no datagram has arrived for a while, so a held frame is not kept past its deadline.
    public mutating func poll(now: Double) -> Output {
        var output = Output()
        deliver(now: now, into: &output)
        return output
    }

    private mutating func request(_ index: Int, datagram: [UInt8], ctl: ControlField, now: Double, into output: inout Output) {
        guard retransmitWindow > 0, ctl.retransmitEnabled else {
            queue[index].deadline = now  // nothing to wait for
            return
        }
        let missing = queue[index].fragments.indices.filter { queue[index].fragments[$0] == nil }
        output.replies.append(Wire.retransmitRequest(
            vid: datagram.readLE(UInt32.self, at: 0), pid: datagram.readLE(UInt16.self, at: 4),
            mainChannel: ctl.mainChannel, subChannel: ctl.subChannel, messageID: queue[index].id, missing: missing))
        queue[index].deadline = now + retransmitWindow
        queue[index].requested = true
        counters.requests += 1
    }

    private mutating func deliver(now: Double, into output: inout Output) {
        while let head = queue.first {
            if head.complete {
                if let frame = head.frame { output.frames.append(frame) }
                if head.requested { counters.recovered += 1 }
            } else {
                // Alone in the queue means it is simply still arriving.
                guard queue.count > 1 else { return }
                if let deadline = head.deadline, now < deadline, queue.count <= 4 { return }
                counters.dropped += 1
            }
            finished.append(head.id)
            if finished.count > 16 { finished.removeFirst() }
            queue.removeFirst()
        }
    }
}
