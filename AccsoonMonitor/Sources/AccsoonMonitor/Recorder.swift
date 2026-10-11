import AVFoundation
import CineEyeProtocol
import CoreMedia
import Foundation

/// Records the incoming H.264 stream to a QuickTime file without re-encoding.
/// The file holds the clean camera picture: LUT, false colour, zebra and grids are not burned in.
final class Recorder {
    struct State: Equatable {
        var isRecording = false
        var startedAt: Date?
        var lastFile: URL?
        /// Frames in `lastFile`.
        var lastFrameCount = 0
        var error: String?
    }

    /// Called on the main thread.
    var onStateChange: ((State) -> Void)?

    static let folder = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Accsoon Monitor", isDirectory: true)

    // Everything below is confined to `queue`.
    private let queue = DispatchQueue(label: "recorder", qos: .userInitiated)
    private var state = State()
    private var wanted = false
    /// Frames since the last keyframe, so a recording can start at once instead of waiting for the next one.
    private var group: [(sample: CMSampleBuffer, header: VideoHeader)] = []
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var format: CMFormatDescription?
    private var firstID: UInt32 = 0
    private var lastID: UInt32 = 0
    private var frameRate: Int32 = 30
    private var written = 0

    func start() {
        queue.async {
            guard !self.wanted else { return }
            self.wanted = true
            self.update {
                $0.isRecording = true
                $0.startedAt = Date()
                $0.error = nil
            }
            // Begin with what is already buffered, if it starts at a keyframe.
            self.beginIfPossible()
        }
    }

    func stop(completion: (() -> Void)? = nil) {
        queue.async {
            self.wanted = false
            self.finish(error: nil, completion: completion)
        }
    }

    /// Every frame that is shown goes through here, recording or not.
    func consume(_ sample: CMSampleBuffer, header: VideoHeader) {
        queue.async {
            if header.isKeyframe { self.group.removeAll(keepingCapacity: true) }
            self.group.append((sample, header))
            guard self.wanted else { return }
            if self.writer != nil {
                // A new picture format or a restarted frame counter cannot continue the same file.
                let sameFormat = CMSampleBufferGetFormatDescription(sample).map { CFEqual($0, self.format) } ?? false
                if sameFormat, header.frameID > self.lastID {
                    self.append(sample, header: header)
                    return
                }
                self.finish(error: nil, completion: nil, keepRecording: true)
            }
            self.beginIfPossible()
        }
    }

    /// Frames were skipped: what is buffered no longer leads up to the next frame.
    func discontinuity() {
        queue.async { self.group.removeAll(keepingCapacity: true) }
    }

    // MARK: - Writing

    private func beginIfPossible() {
        guard wanted, writer == nil, let first = group.first, first.header.isKeyframe,
              let format = CMSampleBufferGetFormatDescription(first.sample)
        else { return }
        do {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            var url = Self.folder.appendingPathComponent("Recording \(formatter.string(from: Date())).mov")
            var n = 2
            while FileManager.default.fileExists(atPath: url.path) {
                url = Self.folder.appendingPathComponent("Recording \(formatter.string(from: Date())) \(n).mov")
                n += 1
            }
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            // Written in fragments, so the file survives a crash or power loss mid-recording.
            writer.movieFragmentInterval = CMTime(value: 1, timescale: 1)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw CocoaError(.fileWriteUnknown) }
            writer.add(input)
            guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            writer.startSession(atSourceTime: .zero)
            self.writer = writer
            self.input = input
            self.format = format
            firstID = first.header.frameID
            lastID = firstID &- 1
            frameRate = Int32(first.header.frameRate > 0 ? first.header.frameRate : 30)
            written = 0
            for entry in group where writer.status == .writing { append(entry.sample, header: entry.header) }
        } catch {
            wanted = false
            finish(error: error.localizedDescription, completion: nil)
        }
    }

    private func append(_ sample: CMSampleBuffer, header: VideoHeader) {
        guard let writer, let input, writer.status == .writing else { return }
        // The stream has no timestamps; the transmitter's frame counter gives an even, gap-aware clock.
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: frameRate),
            presentationTimeStamp: CMTime(value: Int64(header.frameID &- firstID), timescale: frameRate),
            decodeTimeStamp: .invalid)
        var timed: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: sample, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleBufferOut: &timed) == noErr, let timed
        else { return }
        // A compressed frame cannot be skipped without breaking the ones after it, so wait briefly if the disk is busy.
        var waited = 0
        while !input.isReadyForMoreMediaData, waited < 500 {
            usleep(2000)
            waited += 1
        }
        if input.isReadyForMoreMediaData, input.append(timed) {
            lastID = header.frameID
            written += 1
        } else {
            wanted = false
            finish(error: writer.error?.localizedDescription ?? "The disk could not keep up.", completion: nil)
        }
    }

    private func finish(error: String?, completion: (() -> Void)?, keepRecording: Bool = false) {
        let writer = self.writer
        let input = self.input
        self.writer = nil
        self.input = nil
        self.format = nil
        let frames = written
        let done: (URL?) -> Void = { url in
            self.queue.async {
                self.update {
                    if !keepRecording {
                        $0.isRecording = false
                        $0.startedAt = nil
                    }
                    if let url {
                        $0.lastFile = url
                        $0.lastFrameCount = frames
                    }
                    if let error { $0.error = error }
                }
                completion.map { DispatchQueue.main.async(execute: $0) }
            }
        }
        guard let writer, let input, writer.status == .writing else {
            done(nil)
            return
        }
        input.markAsFinished()
        writer.finishWriting { done(writer.status == .completed ? writer.outputURL : nil) }
    }

    private func update(_ change: (inout State) -> Void) {
        change(&state)
        let snapshot = state
        DispatchQueue.main.async { self.onStateChange?(snapshot) }
    }
}
