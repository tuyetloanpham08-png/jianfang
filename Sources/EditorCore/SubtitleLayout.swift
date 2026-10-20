import Foundation

/// Vertical placement of a rasterized subtitle box, shared by preview and export.
public enum SubtitleLayout {
    /// Bottom-left origin Y (Core Image convention) of a box of `boxHeight` pixels.
    /// `positionY` is the box center measured from the top (nil keeps the legacy 7% bottom
    /// margin). The box is clamped to stay fully inside the canvas, so large two-line
    /// subtitles near the top or bottom edge are moved inward instead of being cut off.
    public static func originY(canvasHeight: Double, boxHeight: Double, positionY: Double?) -> Double {
        let wanted = positionY.map { floor(canvasHeight * (1 - $0) - boxHeight / 2) } ?? floor(canvasHeight * 0.07)
        return min(max(wanted, 0), max(0, canvasHeight - boxHeight))
    }
}
