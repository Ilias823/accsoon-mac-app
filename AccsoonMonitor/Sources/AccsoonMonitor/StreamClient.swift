import AVFoundation
import CineEyeProtocol
import CineEyeVideo
import Foundation
import ImageIO

/// Connects to the transmitter, keeps the stream alive and feeds frames to the screen.
/// Reconnecting is implicit: the keep-alive never stops, and video resumes at the next keyframe.
final class StreamClient: ObservableObject {
    enum Status: Equatable {
        case noNetwork
        case connecting(String)
        case waitingForVideo(String, NoVideoReason)
        case live
        case portBusy
    }

    enum NoVideoReason: Equatable {
        /// The transmitter itself reports no HDMI signal.
        case noSignal
        /// The transmitter says it is sending, but no packets reach this Mac.
        case nothingArrives
        /// Packets arrive but no complete picture has been decoded yet.
        case starting
    }

    enum Signal: Equatable {
        case good, fair, poor
    }

    struct Info: Equatable {
        var width = 0, height = 0
        var nominalFPS = 0
        var measuredFPS = 0.0
        var bitrateKbps = 0
        var measuredKbps = 0.0
        var lostFrames = 0
        var signal = Signal.good
        /// Share of frames lost over the last ten seconds, 0–1.
        var recentLoss = 0.0
    }

    @Published private(set) var status: Status = .noNetwork
    @Published private(set) var info = Info()

    /// Metal renderer with the monitoring tools. Nil only if Metal is unavailable.
    let renderer = VideoRenderer()
    /// The system's own video layer: no tools, used as a fallback.
    let systemLayer = AVSampleBufferDisplayLayer()

    /// Empty means "find the Wi-Fi router".
    var manualHost = "" { didSet { lock.withLock { hostOverride = manualHost.trimmingCharacters(in: .whitespaces) } } }
    /// Use the system video layer instead of the Metal renderer.
    var useSystemLayer = false { didSet { lock.withLock { systemLayerSelected = useSystemLayer || renderer == nil } } }

    private let lock = NSLock()
    private var hostOverride = ""
    private var systemLayerSelected = false
    private var running = false
    private var route: Route?
    private var linkUp = false
    private var transmitterHasVideo: Bool?
    private var lastReplyHex = ""
    private var portBusy = false
    private var pinReceiveSocket = true
    private var socketOpened = Date()

    // Counters, written by the receive thread.
    private var datagrams = 0
    private var lastDatagramTime = Date.distantPast
    private var lastFrameTime = Date.distantPast
    private var header: VideoHeader?
    private var framesInWindow = 0
    private var bytesInWindow = 0
    private var lost = 0
    private var transport = Reassembler.Counters()
    private var renderSeconds = 0.0
    private var renderedFrames = 0
    private var decodeFailed = false

    // Main thread only.
    private var statsTimer: Timer?
    private var lastStatsTime = Date()
    private var history: [(frames: Int, lost: Int)] = []
    private var lostAtLastTick = 0
    private var lastLogLine = ""
    private var lastLogTime = Date.distantPast

    private let decodeQueue = DispatchQueue(label: "decode", qos: .userInteractive)
    private let decoder = H264Decoder()

    init() {
        systemLayer.videoGravity = .resizeAspect
        systemLayer.backgroundColor = .black
        systemLayerSelected = renderer == nil
        decoder.onFrame = { [weak self] image in self?.renderer?.display(image) }
    }

    func start() {
        guard !lock.withLock({ running }) else { return }
        lock.withLock { running = true }
        if let capture = ProcessInfo.processInfo.environment["ACCSOON_REPLAY"] {
            Thread.detachNewThread { [weak self] in self?.replayLoop(capture) }
        } else {
            Thread.detachNewThread { [weak self] in self?.keepAliveLoop() }
            Thread.detachNewThread { [weak self] in self?.receiveLoop() }
        }
        lastStatsTime = Date()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.publish() }
    }

    /// Tells the transmitter to stop, best effort. Safe to call at quit.
    func stop() {
        statsTimer?.invalidate()
        let route = lock.withLock { () -> Route? in
            running = false
            return self.route
        }
        if let route { _ = Sockets.exchange(route, port: Wire.tcpPort, request: Wire.stationOp(start: false), timeout: 0.3) }
    }

    // MARK: - Threads

    private func currentRoute() -> Route? {
        let manual = lock.withLock { hostOverride }
        if !manual.isEmpty { return Route(host: manual, interface: nil) }
        return RouteFinder.wifiRoute()
    }

    private func keepAliveLoop() {
        while lock.withLock({ running }) {
            let route = currentRoute()
            var up = false
            var hasVideo: Bool?
            var replyHex = "none"
            if let route, let reply = Sockets.exchange(route, port: Wire.tcpPort, request: Wire.stationOp(start: true)) {
                up = Wire.isValidReply(reply)
                hasVideo = Wire.replyReportsVideo(reply)
                replyHex = reply.map { String(format: "%02x", $0) }.joined()
            }
            lock.withLock {
                self.route = route
                self.linkUp = up
                self.transmitterHasVideo = hasVideo
                self.lastReplyHex = replyHex
            }
            Thread.sleep(forTimeInterval: 1.0)
        }
    }

    private func receiveLoop() {
        var socket: Int32?
        var socketInterface: String?
        var pipeline = FramePipeline()
        var buffer = [UInt8](repeating: 0, count: 65536)
        var sender = sockaddr_in()

        while lock.withLock({ running }) {
            // (Re)open the socket when the Wi-Fi interface changes, so it stays pinned to the right one.
            // If the transmitter says it is sending but nothing has arrived for a while, try the other
            // socket mode (pinned to the Wi-Fi interface or not): which one works depends on VPN software.
            let (route, stalled) = lock.withLock { () -> (Route?, Bool) in
                let quiet = Date().timeIntervalSince(max(lastDatagramTime, socketOpened)) > 5
                return (self.route, linkUp && transmitterHasVideo != false && quiet)
            }
            if stalled, let open = socket {
                lock.withLock { pinReceiveSocket.toggle() }
                close(open)
                socket = nil
            }
            let interface = lock.withLock { pinReceiveSocket } ? route?.interface : nil
            if socket == nil || interface != socketInterface {
                if let socket { close(socket) }
                socket = Sockets.udpSocket(port: Wire.udpPort, interface: interface)
                socketInterface = interface
                lock.withLock {
                    socketOpened = Date()
                    portBusy = socket == nil
                }
                if socket == nil {
                    Thread.sleep(forTimeInterval: 1.0)
                    continue
                }
            }
            guard let fd = socket else { continue }

            let count = Sockets.receive(fd, into: &buffer, sender: &sender)
            let now = ProcessInfo.processInfo.systemUptime
            let output: Reassembler.Output
            if count > 0 {
                lock.withLock {
                    datagrams += 1
                    lastDatagramTime = Date()
                }
                output = pipeline.reassembler.push(Array(buffer[0..<count]), now: now)
            } else {
                // Timeout: release anything held past its deadline, and after a stall start clean at a keyframe.
                output = pipeline.reassembler.poll(now: now)
                if Date().timeIntervalSince(lock.withLock { lastFrameTime }) > 1.0 {
                    pipeline.waitingForKeyframe = true
                    // The transmitter keeps counting frames while we are away; that gap is not packet loss.
                    pipeline.lastID = nil
                }
            }
            for reply in output.replies {
                Sockets.send(fd, reply, to: sender, port: Wire.udpPort)
                Sockets.send(fd, reply, to: sender, port: Wire.udpPort)
            }
            show(output.frames, &pipeline)
        }
        if let socket { close(socket) }
    }

    /// Development aid: plays a `client.py --dump` capture in a loop instead of using the network.
    /// ACCSOON_REPLAY_DROP=n discards every n-th datagram, to exercise the loss handling.
    private func replayLoop(_ path: String) {
        guard let file = FileManager.default.contents(atPath: path) else { return }
        let datagrams = readCapture(file)
        let dropEvery = Int(ProcessInfo.processInfo.environment["ACCSOON_REPLAY_DROP"] ?? "") ?? 0
        var pipeline = FramePipeline()
        var shown = 0
        while lock.withLock({ running }) {
            for (n, datagram) in datagrams.enumerated() where lock.withLock({ running }) {
                if dropEvery > 0, n % dropEvery == dropEvery - 1 { continue }
                let output = pipeline.reassembler.push(datagram, now: ProcessInfo.processInfo.systemUptime)
                show(output.frames, &pipeline)
                if !output.frames.isEmpty {
                    Thread.sleep(forTimeInterval: 1.0 / 30)
                    shown += 1
                    if shown == 240, let directory = ProcessInfo.processInfo.environment["ACCSOON_SNAPSHOT_DIR"] {
                        decodeQueue.sync { writeSnapshots(to: directory) }
                    }
                }
            }
            pipeline = FramePipeline()
        }
    }

    /// Development aid: saves the current frame rendered with each tool, to check the shader.
    private func writeSnapshots(to directory: String) {
        guard let renderer else { return }
        let variants: [(String, VideoRenderer.Options)] = [
            ("plain", .init()),
            ("lut", .init(lutEnabled: true)),
            ("falsecolor", .init(falseColor: true)),
            ("zebra20", .init(zebra: true, zebraLevel: 0.2)),
        ]
        for (name, options) in variants {
            guard let image = renderer.snapshot(options: options) else { continue }
            let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
            if let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, image, nil)
                CGImageDestinationFinalize(destination)
            }
        }
    }

    private struct FramePipeline {
        // Resend requests are off: in a live session the CineEye Air answered none of them
        // (11 requests, 0 fragments resent), so waiting for one only delays the next frame.
        var reassembler = Reassembler(retransmitWindow: 0)
        let builder = H264SampleBuilder()
        var waitingForKeyframe = true
        var lastID: UInt32?
    }

    private func show(_ frames: [VideoFrame], _ p: inout FramePipeline) {
        for frame in frames {
            // Lost frames show up as a gap in the frame counter.
            var missing = 0
            if let lastID = p.lastID, frame.header.frameID > lastID &+ 1 {
                missing = Int(frame.header.frameID - lastID) - 1
            }
            p.lastID = frame.header.frameID

            let (useSystem, failed) = lock.withLock { () -> (Bool, Bool) in
                defer { decodeFailed = false }
                return (systemLayerSelected, decodeFailed)
            }
            // After a lost frame the following P-frames would smear, so hold the last good picture until a keyframe.
            if missing > 0 || failed || (useSystem && systemLayer.status == .failed) { p.waitingForKeyframe = true }
            if p.waitingForKeyframe, frame.header.isKeyframe {
                if systemLayer.status == .failed { systemLayer.flush() }
                p.waitingForKeyframe = false
            }
            if !p.waitingForKeyframe,
               let sample = p.builder.makeSampleBuffer(annexB: frame.payload, isKeyframe: frame.header.isKeyframe) {
                if useSystem {
                    systemLayer.enqueue(sample)
                } else {
                    let arrived = ProcessInfo.processInfo.systemUptime
                    decodeQueue.async { [weak self] in
                        guard let self else { return }
                        let ok = self.decoder.decode(sample)
                        let elapsed = ProcessInfo.processInfo.systemUptime - arrived
                        self.lock.withLock {
                            if ok {
                                self.renderSeconds += elapsed
                                self.renderedFrames += 1
                            } else {
                                self.decodeFailed = true
                            }
                        }
                    }
                }
            }
            lock.withLock {
                lost += missing
                transport = p.reassembler.counters
                header = frame.header
                framesInWindow += 1
                bytesInWindow += frame.payload.count
                lastFrameTime = Date()
            }
        }
    }

    // MARK: - UI state

    private func publish() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastStatsTime)
        lastStatsTime = now
        var newInfo = info
        var newStatus = status
        var line = ""
        lock.withLock {
            let live = now.timeIntervalSince(lastFrameTime) < 1.5
            if portBusy {
                newStatus = .portBusy
            } else if live {
                newStatus = .live
            } else if let route {
                if !linkUp {
                    newStatus = .connecting(route.host)
                } else if transmitterHasVideo == false {
                    newStatus = .waitingForVideo(route.host, .noSignal)
                } else if now.timeIntervalSince(lastDatagramTime) > 3 {
                    newStatus = .waitingForVideo(route.host, .nothingArrives)
                } else {
                    newStatus = .waitingForVideo(route.host, .starting)
                }
            } else {
                newStatus = .noNetwork
            }
            if let header {
                newInfo.width = header.width
                newInfo.height = header.height
                newInfo.nominalFPS = header.frameRate
                newInfo.bitrateKbps = header.bitrateKbps
            }
            if elapsed > 0 {
                newInfo.measuredFPS = Double(framesInWindow) / elapsed
                newInfo.measuredKbps = Double(bytesInWindow) * 8 / 1000 / elapsed
            }
            newInfo.lostFrames = lost

            // Loss over the last ten seconds decides the signal rating.
            history.append((framesInWindow, lost - lostAtLastTick))
            lostAtLastTick = lost
            if history.count > 20 { history.removeFirst() }
            let frames = history.reduce(0) { $0 + $1.frames }
            let losses = history.reduce(0) { $0 + $1.lost }
            newInfo.recentLoss = frames + losses > 0 ? Double(losses) / Double(frames + losses) : 0
            newInfo.signal = newInfo.recentLoss < 0.003 ? .good : newInfo.recentLoss < 0.03 ? .fair : .poor

            let renderMs = renderedFrames > 0 ? renderSeconds / Double(renderedFrames) * 1000 : 0
            renderSeconds = 0
            renderedFrames = 0
            line = "status=\(newStatus) reply=\(lastReplyHex) interface=\(route?.interface ?? "-") pinned=\(pinReceiveSocket)"
                + " datagrams=\(datagrams) lost=\(lost) dropped=\(transport.dropped) requests=\(transport.requests)"
                + " resent=\(transport.retransmittedFragments) recovered=\(transport.recovered)"
                + " kbps=\(header?.bitrateKbps ?? 0) quality=\(header?.quality ?? 0)"
                + " render=\(systemLayerSelected ? "system" : String(format: "%.1fms", renderMs))"
            framesInWindow = 0
            bytesInWindow = 0
        }
        logIfChanged(line)
        if newStatus != status {
            // Do not leave a stale picture to be redrawn once the stream has gone.
            if newStatus != .live { renderer?.clear() }
            status = newStatus
        }
        if newInfo != info { info = newInfo }
    }

    private static let logURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/AccsoonMonitor.log")

    /// Appends to ~/Library/Logs/AccsoonMonitor.log, so a session without internet can be diagnosed afterwards.
    private func logIfChanged(_ line: String) {
        // Fast-changing numbers alone do not justify a line; while live they are logged every 10 s.
        let key = line.replacingOccurrences(
            of: #"(datagrams|kbps|quality|render|resent|requests|recovered|dropped)=\S+"#, with: "", options: .regularExpression)
        let now = Date()
        guard key != lastLogLine || now.timeIntervalSince(lastLogTime) > 10 else { return }
        lastLogLine = key
        lastLogTime = now
        let text = "\(ISO8601DateFormatter().string(from: now)) \(line)\n"
        if let handle = try? FileHandle(forWritingTo: Self.logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? Data(text.utf8).write(to: Self.logURL)
        }
    }
}
