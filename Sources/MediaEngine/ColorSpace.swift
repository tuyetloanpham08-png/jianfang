import Foundation
import CoreGraphics

/// Standard BT.709 camera OETF / inverse OETF, with sRGB/BT.709 primaries.
/// macOS's named HDTV / ITUR_709 ICC profiles are display-oriented and do not
/// consistently encode the BT.709 piecewise transfer function used by video
/// metadata. A small ICC profile derived from sRGB's primaries makes conversion
/// explicit rather than interpreting incoming video through a guessed profile.
internal enum VideoColorSpace {
    static let rec709: CGColorSpace = {
        let original = CGColorSpace(name: CGColorSpace.sRGB)!.copyICCData()! as Data
        func read32(_ data: Data, _ offset: Int) -> Int {
            (0..<4).reduce(0) { ($0 << 8) | Int(data[offset + $1]) }
        }
        func be16(_ value: UInt16) -> Data { Data([UInt8((value >> 8) & 255), UInt8(value & 255)]) }
        func be32(_ value: UInt32) -> Data {
            Data([UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)])
        }
        var curve = Data("para".utf8)
        curve.append(Data(count: 4)); curve.append(be16(4)); curve.append(be16(0))
        // ICC parametricCurveType function 4:
        // y = (a*x+b)^g+e for x>=d, else c*x+f.
        for value in [1.0 / 0.45, 1.0 / 1.099, 0.099 / 1.099, 1.0 / 4.5, 0.081, 0.0, 0.0] {
            curve.append(be32(UInt32(bitPattern: Int32((value * 65536).rounded()))))
        }
        let count = read32(original, 128)
        var tags: [(Data, Data)] = []
        for index in 0..<count {
            let row = 132 + index * 12
            let signature = original.subdata(in: row..<(row + 4))
            let offset = read32(original, row + 4), size = read32(original, row + 8)
            let name = String(data: signature, encoding: .ascii) ?? ""
            let payload = ["rTRC", "gTRC", "bTRC"].contains(name) ? curve : original.subdata(in: offset..<(offset + size))
            tags.append((signature, payload))
        }
        var result = original.prefix(128)
        // The original profile digest no longer identifies the modified profile.
        result.replaceSubrange(84..<100, with: Data(count: 16))
        result.append(be32(UInt32(count)))
        var payload = Data()
        let payloadStart = 132 + count * 12
        for (signature, data) in tags {
            result.append(signature)
            result.append(be32(UInt32(payloadStart + payload.count)))
            result.append(be32(UInt32(data.count)))
            payload.append(data)
            while payload.count % 4 != 0 { payload.append(0) }
        }
        result.append(payload)
        result.replaceSubrange(0..<4, with: be32(UInt32(result.count)))
        guard let space = CGColorSpace(iccData: result as CFData) else { preconditionFailure("Unable to construct standard BT.709 ICC profile") }
        return space
    }()
}
