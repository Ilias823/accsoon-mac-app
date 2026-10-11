// Runs a `client.py --dump` capture through the app's parsing and decoding
// path and reports what came out. Usage: cineeye-replay capture.bin
import CineEyeProtocol
import CineEyeVideo
import CoreMedia
import Foundation
import VideoToolbox

guard CommandLine.arguments.count == 2,
      let file = FileManager.default.contents(atPath: CommandLine.arguments[1])
else {
    FileHandle.standardError.write(Data("usage: cineeye-replay capture.bin\n".utf8))
    exit(2)
}

var reassembler = Reassembler()
let builder = H264SampleBuilder()
var session: VTDecompressionSession?
var frames = 0, keyframes = 0, acks = 0, samples = 0, decoded = 0, decodeErrors = 0, idGaps = 0
var lastID: UInt32?
var size = ""
let lock = NSLock()

for (n, datagram) in readCapture(file).enumerated() {
    let out = reassembler.push(datagram, now: Double(n) * 0.001)
    acks += out.replies.count
    guard let frame = out.frames.first else { continue }
    frames += 1
    if frame.header.isKeyframe { keyframes += 1 }
    if let lastID, frame.header.frameID != lastID &+ 1 { idGaps += 1 }
    lastID = frame.header.frameID
    guard let sample = builder.makeSampleBuffer(annexB: frame.payload, isKeyframe: frame.header.isKeyframe) else { continue }
    samples += 1
    if session == nil, let format = builder.formatDescription {
        VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                                     imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &session)
    }
    guard let session else { continue }
    let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
        lock.lock()
        defer { lock.unlock() }
        if status == noErr, let image {
            decoded += 1
            size = "\(CVPixelBufferGetWidth(image))x\(CVPixelBufferGetHeight(image))"
        } else {
            decodeErrors += 1
        }
    }
    if status != noErr { decodeErrors += 1 }
}
if let session { VTDecompressionSessionWaitForAsynchronousFrames(session) }

print("frames=\(frames) keyframes=\(keyframes) acks=\(acks) dropped=\(reassembler.droppedMessages) idGaps=\(idGaps)")
print("samples=\(samples) decoded=\(decoded) decodeErrors=\(decodeErrors) size=\(size)")
exit(decoded > 0 && decodeErrors == 0 ? 0 : 1)
