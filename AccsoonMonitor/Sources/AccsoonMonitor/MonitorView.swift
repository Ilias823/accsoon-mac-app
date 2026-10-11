import AVFoundation
import AppKit
import SwiftUI

struct MonitorView: View {
    @ObservedObject var client: StreamClient
    var showInfo: Bool
    var grid: GridKind
    var falseColor: Bool
    var lutName: String?
    var useSystemLayer: Bool

    private var isLive: Bool { client.status == .live }

    var body: some View {
        ZStack {
            Color.black
            VideoSurface(client: client, useSystemLayer: useSystemLayer)
            if isLive, grid != .off, client.info.width > 0 {
                GeometryReader { geometry in
                    let rect = AVMakeRect(
                        aspectRatio: CGSize(width: client.info.width, height: client.info.height),
                        insideRect: CGRect(origin: .zero, size: geometry.size))
                    GridOverlay(kind: grid)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
                .allowsHitTesting(false)
            }
            if !isLive {
                StatusMessage(status: client.status)
            }
            if isLive, showInfo {
                InfoOverlay(info: client.info, lutName: lutName)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            RecordingBadge(state: client.recording)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(12)
            if isLive, falseColor {
                FalseColorLegend()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(12)
            }
        }
        .ignoresSafeArea()
        .onTapGesture(count: 2) { NSApp.keyWindow?.toggleFullScreen(nil) }
    }
}

/// Top-right: the running recording, or for a few seconds the result of the last one.
private struct RecordingBadge: View {
    let state: Recorder.State
    @State private var notice: String?
    @State private var noticeIsError = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if state.isRecording, let start = state.startedAt {
                TimelineView(.periodic(from: start, by: 1)) { context in
                    HStack(spacing: 6) {
                        Circle().fill(.red).frame(width: 10, height: 10)
                        Text("REC \(Self.clock(context.date.timeIntervalSince(start)))")
                    }
                    .modifier(BadgeStyle())
                }
            }
            if let notice {
                Text(notice)
                    .foregroundStyle(noticeIsError ? .orange : .white)
                    .modifier(BadgeStyle())
            }
        }
        .onChange(of: state.lastFile) { _, file in
            if let file { show("Saved \(file.lastPathComponent) to Movies", isError: false) }
        }
        .onChange(of: state.error) { _, error in
            if let error { show("Recording stopped: \(error)", isError: true) }
        }
    }

    private func show(_ text: String, isError: Bool) {
        notice = text
        noticeIsError = isError
        DispatchQueue.main.asyncAfter(deadline: .now() + (isError ? 12 : 6)) {
            if notice == text { notice = nil }
        }
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }

    private struct BadgeStyle: ViewModifier {
        func body(content: Content) -> some View {
            content
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

private struct GridOverlay: View {
    let kind: GridKind

    var body: some View {
        Canvas { context, size in
            var path = Path()
            func line(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
                path.move(to: CGPoint(x: x1 * size.width, y: y1 * size.height))
                path.addLine(to: CGPoint(x: x2 * size.width, y: y2 * size.height))
            }
            switch kind {
            case .off:
                break
            case .thirds:
                for t in [1.0 / 3, 2.0 / 3] {
                    line(t, 0, t, 1)
                    line(0, t, 1, t)
                }
            case .center:
                // Arm length is the same on screen in both directions.
                let arm = 0.04
                let armX = arm * size.height / max(size.width, 1)
                line(0.5 - armX, 0.5, 0.5 + armX, 0.5)
                line(0.5, 0.5 - arm, 0.5, 0.5 + arm)
            case .safe:
                for inset in [0.05, 0.1] {  // action safe 90 %, title safe 80 %
                    path.addRect(CGRect(x: inset * size.width, y: inset * size.height,
                                        width: (1 - 2 * inset) * size.width, height: (1 - 2 * inset) * size.height))
                }
            }
            // Dark underlay so the lines read on bright and dark pictures alike.
            context.stroke(path, with: .color(.black.opacity(0.5)), lineWidth: 3)
            context.stroke(path, with: .color(.white.opacity(0.85)), lineWidth: 1)
        }
    }
}

private struct StatusMessage: View {
    let status: StreamClient.Status

    var body: some View {
        VStack(spacing: 10) {
            if showsSpinner { ProgressView().controlSize(.small).colorScheme(.dark) }
            Text(title).font(.title3.weight(.medium)).foregroundStyle(.white)
            Text(detail).font(.callout).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center)
        }
        .padding(24)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
        .padding()
    }

    private var showsSpinner: Bool {
        switch status {
        case .connecting, .waitingForVideo: true
        default: false
        }
    }

    private var title: String {
        switch status {
        case .noNetwork: "No Wi-Fi network"
        case .connecting: "Looking for the transmitter"
        case .waitingForVideo(_, .noSignal): "No video signal"
        case .waitingForVideo: "Connected, waiting for video"
        case .portBusy: "Another app is using the video port"
        case .live: ""
        }
    }

    private var detail: String {
        switch status {
        case .noNetwork: "Join the CineEye Air's Wi-Fi network."
        case .connecting(let host): "No answer from \(host). Join the CineEye Air's Wi-Fi network."
        case .waitingForVideo(let host, .noSignal):
            "\(host) reports no video signal. Check the camera's HDMI output and cable."
        case .waitingForVideo(let host, .nothingArrives):
            "\(host) says it is sending, but nothing reaches this Mac. Turn off any VPN, and quit other Accsoon viewers on this network."
        case .waitingForVideo(_, .starting):
            "Receiving data, waiting for the first complete picture."
        case .portBusy: "Quit the Accsoon app (or any other viewer), then this will connect by itself."
        case .live: ""
        }
    }
}

private struct InfoOverlay: View {
    let info: StreamClient.Info
    let lutName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                SignalBars(signal: info.signal)
                Text(signalText)
            }
            Text("\(info.width)×\(info.height)  \(info.measuredFPS, specifier: "%.0f")/\(info.nominalFPS) fps")
            Text("\(info.measuredKbps / 1000, specifier: "%.1f") Mbit/s  (target \(Double(info.bitrateKbps) / 1000, specifier: "%.1f"))")
            if info.lostFrames > 0 {
                Text("\(info.lostFrames) frames lost").foregroundStyle(.orange)
            }
            if let lutName {
                Text("LUT: \(lutName)").lineLimit(1)
            }
        }
        .font(.system(size: 12, weight: .medium).monospacedDigit())
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
    }

    private var signalText: String {
        let name = switch info.signal {
        case .good: "Signal good"
        case .fair: "Signal fair"
        case .poor: "Signal poor"
        }
        return info.recentLoss > 0 ? "\(name), \(String(format: "%.1f", info.recentLoss * 100))% lost" : name
    }
}

private struct SignalBars: View {
    let signal: StreamClient.Signal

    var body: some View {
        let lit = switch signal {
        case .good: 3
        case .fair: 2
        case .poor: 1
        }
        let color: Color = switch signal {
        case .good: .green
        case .fair: .yellow
        case .poor: .red
        }
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<3, id: \.self) { bar in
                RoundedRectangle(cornerRadius: 1)
                    .fill(bar < lit ? color : .white.opacity(0.25))
                    .frame(width: 3, height: CGFloat(5 + bar * 3))
            }
        }
    }
}

private struct FalseColorLegend: View {
    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(VideoRenderer.falseColorBands.enumerated()), id: \.offset) { index, band in
                if let rgb = band.rgb {
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z)))
                            .frame(width: 12, height: 12)
                        Text("\(band.name) \(range(index))")
                    }
                }
            }
        }
        .font(.system(size: 11, weight: .medium).monospacedDigit())
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
    }

    private func range(_ index: Int) -> String {
        let bands = VideoRenderer.falseColorBands
        let low = index == 0 ? 0 : bands[index - 1].upTo
        let format: (Float) -> String = { $0 == $0.rounded() ? String(Int($0)) : String($0) }
        return index == bands.count - 1 ? "≥\(format(low))%" : "\(format(low))–\(format(bands[index].upTo))%"
    }
}

/// Hosts the video layers and keeps them sized to the view.
private struct VideoSurface: NSViewRepresentable {
    let client: StreamClient
    let useSystemLayer: Bool

    func makeNSView(context: Context) -> LayerHostView {
        let view = LayerHostView()
        view.wantsLayer = true
        view.layer = CALayer()
        view.layer?.backgroundColor = .black
        view.renderer = client.renderer
        view.systemLayer = client.systemLayer
        view.layer?.addSublayer(client.systemLayer)
        if let metalLayer = client.renderer?.layer { view.layer?.addSublayer(metalLayer) }
        return view
    }

    func updateNSView(_ view: LayerHostView, context: Context) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        client.systemLayer.isHidden = !useSystemLayer
        client.renderer?.layer.isHidden = useSystemLayer
        CATransaction.commit()
    }

    final class LayerHostView: NSView {
        var renderer: VideoRenderer?
        var systemLayer: CALayer?

        override func layout() {
            super.layout()
            resize()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            resize()
        }

        private func resize() {
            let scale = window?.backingScaleFactor ?? 2
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            systemLayer?.frame = bounds
            renderer?.layer.frame = bounds
            renderer?.layer.contentsScale = scale
            CATransaction.commit()
            renderer?.setDrawableSize(CGSize(width: bounds.width * scale, height: bounds.height * scale))
        }
    }
}
