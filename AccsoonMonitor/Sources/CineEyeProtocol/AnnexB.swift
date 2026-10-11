import Foundation

public enum AnnexB {
    /// The NAL units in an Annex-B stream, without their start codes.
    public static func nalUnits(in data: Data) -> [Data] {
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> [Data] in
            let count = buffer.count
            var units: [Data] = []
            var start: Int? = nil
            var i = 0
            while i + 2 < count {
                if buffer[i] == 0, buffer[i + 1] == 0, buffer[i + 2] == 1 {
                    if let s = start {
                        // A 4-byte start code leaves one zero that belongs to the code, not the unit.
                        let end = (i > s && buffer[i - 1] == 0) ? i - 1 : i
                        if end > s { units.append(Data(buffer[s..<end])) }
                    }
                    start = i + 3
                    i += 3
                } else {
                    i += 1
                }
            }
            if let s = start, s < count { units.append(Data(buffer[s..<count])) }
            return units
        }
    }

    public static func nalType(_ unit: Data) -> UInt8 {
        (unit.first ?? 0) & 0x1F
    }
}

/// Reads a `client.py --dump` file: repeated (u16 length, datagram).
public func readCapture(_ data: Data) -> [[UInt8]] {
    let bytes = [UInt8](data)
    var out: [[UInt8]] = []
    var offset = 0
    while offset + 2 <= bytes.count {
        let length = Int(bytes.readLE(UInt16.self, at: offset))
        offset += 2
        guard offset + length <= bytes.count else { break }
        out.append(Array(bytes[offset..<offset + length]))
        offset += length
    }
    return out
}
