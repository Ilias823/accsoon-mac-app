import Foundation

/// A 3D LUT read from a .cube file.
public struct CubeLUT: Equatable {
    public enum ParseError: Error, Equatable {
        case notA3DLUT
        case badSize
        case wrongEntryCount(expected: Int, found: Int)
    }

    /// Entries per axis.
    public let size: Int
    /// RGBA floats, red index changing fastest, then green, then blue. Ready for a 3D texture.
    public let rgba: [Float]

    public init(text: String) throws {
        var size = 0
        var low: [Float] = [0, 0, 0]
        var high: [Float] = [1, 1, 1]
        var values: [Float] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            switch parts[0].uppercased() {
            case "LUT_3D_SIZE":
                size = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            case "LUT_1D_SIZE":
                throw ParseError.notA3DLUT
            case "DOMAIN_MIN":
                low = parts.dropFirst().compactMap { Float($0) }
            case "DOMAIN_MAX":
                high = parts.dropFirst().compactMap { Float($0) }
            default:
                // Data rows are three numbers; anything else (TITLE, LUT_3D_INPUT_RANGE, ...) is skipped.
                guard parts.count >= 3, let r = Float(parts[0]), let g = Float(parts[1]), let b = Float(parts[2]) else { continue }
                values.append(contentsOf: [r, g, b, 1])
            }
        }
        guard (2...129).contains(size) else { throw ParseError.badSize }
        let expected = size * size * size
        guard values.count == expected * 4 else {
            throw ParseError.wrongEntryCount(expected: expected, found: values.count / 4)
        }
        self.size = size
        self.rgba = values
        self.domainMin = low.count == 3 ? SIMD3(low[0], low[1], low[2]) : SIMD3(0, 0, 0)
        self.domainMax = high.count == 3 ? SIMD3(high[0], high[1], high[2]) : SIMD3(1, 1, 1)
    }

    /// Input range the table covers; (0,0,0)–(1,1,1) unless the file says otherwise.
    public let domainMin: SIMD3<Float>
    public let domainMax: SIMD3<Float>
}
