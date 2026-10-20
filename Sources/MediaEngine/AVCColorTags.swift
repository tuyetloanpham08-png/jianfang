import Foundation

/// AVCDecoderConfigurationRecord -> SPS VUI color description. AVFoundation may
/// omit primaries/transfer from CMFormatDescription even when both are present in
/// the H.264 bitstream, so the M1 gate reads the original labels, not decoder guesses.
internal struct AVCColorTags {
    let primaries: Int?
    let transfer: Int?
    let matrix: Int?
    let fullRange: Bool

    static func read(from avcC: Data) throws -> [AVCColorTags] {
        let bytes = Array(avcC)
        guard bytes.count >= 7, bytes[0] == 1 else { throw ParseError.invalid }
        let count = Int(bytes[5] & 31)
        guard count > 0 else { throw ParseError.invalid }
        var offset = 6
        var result: [AVCColorTags] = []
        for _ in 0..<count {
            guard offset + 2 <= bytes.count else { throw ParseError.invalid }
            let length = Int(bytes[offset]) << 8 | Int(bytes[offset + 1]); offset += 2
            guard length > 1, offset + length <= bytes.count else { throw ParseError.invalid }
            let nal = Array(bytes[offset..<(offset + length)]); offset += length
            guard nal[0] & 31 == 7 else { throw ParseError.invalid }
            var rbsp: [UInt8] = []
            for index in 1..<nal.count {
                if index >= 3, nal[index] == 3, nal[index - 1] == 0, nal[index - 2] == 0 { continue }
                rbsp.append(nal[index])
            }
            var bits = Bits(bytes: rbsp)
            result.append(try sps(&bits))
        }
        return result
    }

    private static func sps(_ bits: inout Bits) throws -> AVCColorTags {
        let profile = try bits.take(8)
        _ = try bits.take(8); _ = try bits.take(8); _ = try bits.ue()
        if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profile) {
            let chroma = try bits.ue()
            guard chroma <= 3 else { throw ParseError.invalid }
            if chroma == 3 { _ = try bits.take(1) }
            _ = try bits.ue(); _ = try bits.ue(); _ = try bits.take(1)
            if try bits.flag() {
                for index in 0..<(chroma == 3 ? 12 : 8) where try bits.flag() {
                    var last = 8, next = 8
                    for _ in 0..<(index < 6 ? 16 : 64) {
                        if next != 0 { next = (last + (try bits.se()) + 256) % 256 }
                        if next != 0 { last = next }
                    }
                }
            }
        }
        _ = try bits.ue()
        let order = try bits.ue()
        if order == 0 { _ = try bits.ue() }
        else if order == 1 {
            _ = try bits.take(1); _ = try bits.se(); _ = try bits.se()
            let count = try bits.ue()
            guard count <= 255 else { throw ParseError.invalid }
            for _ in 0..<count { _ = try bits.se() }
        } else if order != 2 { throw ParseError.invalid }
        _ = try bits.ue(); _ = try bits.take(1)
        _ = try bits.ue(); _ = try bits.ue()
        if try !bits.flag() { _ = try bits.take(1) }
        _ = try bits.take(1)
        if try bits.flag() { for _ in 0..<4 { _ = try bits.ue() } }
        let unknown = AVCColorTags(primaries: nil, transfer: nil, matrix: nil, fullRange: false)
        guard try bits.flag() else { return unknown } // vui_parameters_present_flag
        if try bits.flag() {
            if try bits.take(8) == 255 { _ = try bits.take(16); _ = try bits.take(16) }
        }
        if try bits.flag() { _ = try bits.take(1) }
        guard try bits.flag() else { return unknown } // video_signal_type_present_flag
        _ = try bits.take(3)
        let full = try bits.flag()
        guard try bits.flag() else { return AVCColorTags(primaries: nil, transfer: nil, matrix: nil, fullRange: full) }
        return AVCColorTags(primaries: try bits.take(8), transfer: try bits.take(8), matrix: try bits.take(8), fullRange: full)
    }

    private enum ParseError: Error { case invalid }
    private struct Bits {
        let bytes: [UInt8]
        var offset = 0
        mutating func take(_ count: Int) throws -> Int {
            guard (0...32).contains(count), offset + count <= bytes.count * 8 else { throw ParseError.invalid }
            var value = 0
            for _ in 0..<count {
                value = (value << 1) | Int((bytes[offset / 8] >> (7 - offset % 8)) & 1)
                offset += 1
            }
            return value
        }
        mutating func flag() throws -> Bool { try take(1) != 0 }
        mutating func ue() throws -> Int {
            var zeros = 0
            while try take(1) == 0 {
                zeros += 1
                guard zeros <= 30 else { throw ParseError.invalid }
            }
            return (1 << zeros) - 1 + (try take(zeros))
        }
        mutating func se() throws -> Int {
            let value = try ue()
            return value % 2 == 0 ? -value / 2 : (value + 1) / 2
        }
    }
}
