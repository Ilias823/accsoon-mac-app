import CineEyeProtocol
import CoreMedia
import Foundation

/// Converts the transmitter's Annex-B frames into sample buffers that
/// AVSampleBufferDisplayLayer or VideoToolbox can decode.
public final class H264SampleBuilder {
    public private(set) var formatDescription: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?

    public init() {}

    /// Returns nil until a keyframe has supplied SPS and PPS.
    public func makeSampleBuffer(annexB: Data, isKeyframe: Bool) -> CMSampleBuffer? {
        var avcc = Data(capacity: annexB.count + 16)
        var newSPS: Data?
        var newPPS: Data?
        for unit in AnnexB.nalUnits(in: annexB) {
            switch AnnexB.nalType(unit) {
            case 7: newSPS = unit
            case 8: newPPS = unit
            default:
                var length = UInt32(unit.count).bigEndian
                withUnsafeBytes(of: &length) { avcc.append(contentsOf: $0) }
                avcc.append(unit)
            }
        }
        if let newSPS, let newPPS, newSPS != sps || newPPS != pps || formatDescription == nil {
            sps = newSPS
            pps = newPPS
            formatDescription = Self.makeFormatDescription(sps: newSPS, pps: newPPS)
        }
        guard let formatDescription, !avcc.isEmpty else { return nil }

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: avcc.count, flags: 0, blockBufferOut: &blockBuffer) == noErr,
            let blockBuffer
        else { return nil }
        let copied = avcc.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard copied == noErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var size = avcc.count
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid)
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, formatDescription: formatDescription,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sampleBuffer) == noErr,
            let sampleBuffer
        else { return nil }

        // No timestamps on this link: show every frame the moment it is decoded.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            if !isKeyframe {
                CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
        }
        return sampleBuffer
    }

    /// Forget the parameter sets, e.g. after a reconnect.
    public func reset() {
        sps = nil
        pps = nil
        formatDescription = nil
    }

    private static func makeFormatDescription(sps: Data, pps: Data) -> CMVideoFormatDescription? {
        sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                let pointers = [
                    spsBytes.bindMemory(to: UInt8.self).baseAddress!,
                    ppsBytes.bindMemory(to: UInt8.self).baseAddress!,
                ]
                let sizes = [sps.count, pps.count]
                var description: CMFormatDescription?
                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &description)
                return status == noErr ? description : nil
            }
        }
    }
}
