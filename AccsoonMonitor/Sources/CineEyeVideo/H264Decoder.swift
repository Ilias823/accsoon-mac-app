import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Hardware H.264 decoding to Metal-compatible pixel buffers.
/// Not thread-safe: call `decode` from one queue.
public final class H264Decoder {
    /// Called synchronously from `decode`, on the caller's queue.
    public var onFrame: ((CVPixelBuffer) -> Void)?

    private var session: VTDecompressionSession?

    public init() {}

    deinit { invalidate() }

    /// Decodes one sample. Returns false if the frame could not be decoded;
    /// the caller should then wait for the next keyframe.
    @discardableResult
    public func decode(_ sample: CMSampleBuffer) -> Bool {
        guard let format = CMSampleBufferGetFormatDescription(sample) else { return false }
        if let session, !VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: format) {
            invalidate()
        }
        if session == nil {
            // Full-range NV12: what the transmitter's stream is, and cheap to convert in a shader.
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            guard VTDecompressionSessionCreate(
                allocator: nil, formatDescription: format, decoderSpecification: nil,
                imageBufferAttributes: attributes as CFDictionary, outputCallback: nil,
                decompressionSessionOut: &session) == noErr, let session
            else { return false }
            VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        }
        guard let session else { return false }

        var ok = false
        // No asynchronous flag: the handler runs before this call returns, so frames stay in order.
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
            [weak self] status, _, image, _, _ in
            guard status == noErr, let image else { return }
            ok = true
            self?.onFrame?(image)
        }
        if status != noErr || !ok {
            invalidate()
            return false
        }
        return true
    }

    public func invalidate() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
    }
}
