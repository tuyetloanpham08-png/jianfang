import Foundation

/// Integer-only conversion between rational media time (value/timescale seconds)
/// and project frames. Floating-point seconds × fps loses whole frames for many
/// exact durations (e.g. 4.1 s × 30 = 122.999…), so it is never used for lengths.
public enum FrameMath {
    /// floor(value / timescale × fps).
    public static func floorFrames(value: Int64, timescale: Int32, fps: Int) -> Int {
        precondition(timescale > 0 && fps > 0)
        let (product, overflow) = value.multipliedReportingOverflow(by: Int64(fps))
        precondition(!overflow, "媒体时间过大")
        let t = Int64(timescale)
        let q = product / t
        return Int(product % t != 0 && product < 0 ? q - 1 : q)
    }
    /// ceil(value / timescale × fps).
    public static func ceilFrames(value: Int64, timescale: Int32, fps: Int) -> Int {
        -floorFrames(value: -value, timescale: timescale, fps: fps)
    }
    /// Half-open range of whole project frames fully inside [start, end) of one source track.
    public static func usableFrames(start: (Int64, Int32), end: (Int64, Int32), fps: Int) -> Range<Int>? {
        let first = ceilFrames(value: start.0, timescale: start.1, fps: fps)
        let last = floorFrames(value: end.0, timescale: end.1, fps: fps)
        return last > first ? first..<last : nil
    }
    /// Constant-frame-rate test on sorted presentation timestamps in seconds. Each step may
    /// differ from 1/fps by at most max(one timebase tick, 1% of a frame) — a 1/1000 timebase
    /// stores 30 fps as alternating 33/34 ms steps — and the accumulated position may drift
    /// from n/fps by at most half a frame, so slow drift cannot hide inside the step tolerance.
    public static func isConstantFrameRate(_ timestamps: [Double], fps: Double, tick: Double) -> Bool {
        guard let first = timestamps.first, fps > 0 else { return false }
        let frame = 1 / fps, step = max(tick, frame * 0.01) + 1e-9
        for index in timestamps.indices.dropFirst() {
            if abs(timestamps[index] - timestamps[index - 1] - frame) > step { return false }
            if abs(timestamps[index] - first - Double(index) * frame) > frame / 2 { return false }
        }
        return true
    }
    /// Ticks to sample a CFR source late by. When the timebase is not a multiple of the frame
    /// rate (e.g. 30 fps in 1/1000), stored timestamps are rounded and up to half a tick late
    /// (frame 2 at 67 ms, not 66.67 ms), so sampling at the exact project instant would show the
    /// previous frame. One tick compensates and stays far below the 1/150 s minimum gap between
    /// a project instant and the next 24/25/30 fps source frame. Exact timebases need none.
    public static func roundedTimestampGuardTicks(timescale: Int32, fps: Int) -> Int64 {
        timescale > 0 && fps > 0 && Int(timescale) % fps != 0 ? 1 : 0
    }
    /// Linked picture/original-audio clips must share start, source entry and
    /// length, so they are cut to the overlap of both tracks. `mismatchFrames`
    /// is how many frames the longer track lost; callers report it above 1 frame.
    public static func linkedRange(video: Range<Int>, audio: Range<Int>?) -> (sourceStartFrame: Int, durationFrames: Int, mismatchFrames: Int)? {
        guard let audio else { return (video.lowerBound, video.upperBound - video.lowerBound, 0) }
        let start = max(video.lowerBound, audio.lowerBound), end = min(video.upperBound, audio.upperBound)
        guard end > start else { return nil }
        let longer = max(video.upperBound - video.lowerBound, audio.upperBound - audio.lowerBound)
        return (start, end - start, longer - (end - start))
    }
}
