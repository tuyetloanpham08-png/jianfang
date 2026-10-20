import AVFoundation
import CoreImage
import CoreText
import AppKit
import EditorCore

internal struct RenderLayer {
    let clip: VideoClip
    let sourceTrackID: CMPersistentTrackID?
    let image: CIImage?
    let preferredTransform: CGAffineTransform
}
internal struct RenderSubtitle {
    let startFrame: Int
    let endFrame: Int
    let image: CIImage
}

internal final class TimelineInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    let layers: [RenderLayer]
    let subtitles: [RenderSubtitle]
    let canvas: CGRect
    let fps: Int

    init(duration: CMTime, canvas: CGRect, fps: Int, tracks: [CMPersistentTrackID], layers: [RenderLayer], subtitles: [RenderSubtitle]) {
        timeRange = CMTimeRange(start: .zero, duration: duration)
        self.canvas = canvas; self.fps = fps; self.layers = layers; self.subtitles = subtitles
        requiredSourceTrackIDs = tracks.map { NSNumber(value: $0) }
        super.init()
    }
}

/// This compositor is the single rendering implementation used by preview,
/// AVAssetImageGenerator and the export reader. It performs no file I/O per frame.
internal final class TimelineCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private let queue = DispatchQueue(label: "IndependentEditor.video-compositor", qos: .userInitiated)
    private let colorSpace = VideoColorSpace.rec709
    private lazy var context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .outputColorSpace: colorSpace,
        .cacheIntermediates: false
    ])
    var sourcePixelBufferAttributes: [String: any Sendable]? { [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA] }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
         kCVPixelBufferMetalCompatibilityKey as String: true]
    }
    let supportsWideColorSourceFrames = false
    let supportsHDRSourceFrames = false
    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async { [self] in
            autoreleasepool {
                guard let instruction = request.videoCompositionInstruction as? TimelineInstruction,
                      let target = request.renderContext.newPixelBuffer() else {
                    request.finish(with: MediaEngineError.render("无法分配合成画面")); return
                }
                let frame = Int(floor(CMTimeGetSeconds(request.compositionTime) * Double(instruction.fps) + 0.00001))
                var output = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)).cropped(to: instruction.canvas)
                for layer in instruction.layers where frame >= layer.clip.startFrame && frame < layer.clip.startFrame + layer.clip.durationFrames {
                    var source: CIImage
                    if let still = layer.image { source = still }
                    else if let track = layer.sourceTrackID, let buffer = request.sourceFrame(byTrackID: track) {
                        source = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: VideoColorSpace.rec709]).transformed(by: layer.preferredTransform)
                    } else {
                        request.finish(with: MediaEngineError.render("第 \(frame) 帧缺少活动视频素材：\(layer.clip.id)")); return
                    }
                    source = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
                    if layer.clip.rotationDegrees != 0 {
                        // Project rotations are clockwise in a top-left coordinate system.
                        source = source.transformed(by: CGAffineTransform(rotationAngle: -CGFloat(layer.clip.rotationDegrees) * .pi / 180))
                        source = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
                    }
                    let rect = layer.clip.rect
                    let box = CGRect(x: rect.x * instruction.canvas.width,
                                     y: (1 - rect.y - rect.height) * instruction.canvas.height,
                                     width: rect.width * instruction.canvas.width,
                                     height: rect.height * instruction.canvas.height)
                    let scale = min(box.width / source.extent.width, box.height / source.extent.height)
                    source = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    source = source.transformed(by: CGAffineTransform(translationX: box.midX - source.extent.midX, y: box.midY - source.extent.midY))
                    if layer.clip.opacity < 1 {
                        source = source.applyingFilter("CIColorMatrix", parameters: [
                            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(layer.clip.opacity))
                        ])
                    }
                    output = source.composited(over: output).cropped(to: instruction.canvas)
                }
                for cue in instruction.subtitles where frame >= cue.startFrame && frame < cue.endFrame {
                    output = cue.image.composited(over: output)
                }
                CVBufferSetAttachment(target, kCVImageBufferCGColorSpaceKey, colorSpace, .shouldPropagate)
                CVBufferSetAttachment(target, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
                CVBufferSetAttachment(target, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
                CVBufferSetAttachment(target, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
                // AVFoundation may request a reduced renderScale. Scale once at the
                // end so placement and typography retain project-pixel semantics.
                let targetSize = request.renderContext.size
                if targetSize != instruction.canvas.size {
                    output = output.transformed(by: CGAffineTransform(scaleX: targetSize.width / instruction.canvas.width,
                                                                     y: targetSize.height / instruction.canvas.height))
                }
                context.render(output, to: target, bounds: CGRect(origin: .zero, size: targetSize), colorSpace: colorSpace)
                request.finish(withComposedVideoFrame: target)
            }
        }
    }
    func cancelAllPendingVideoCompositionRequests() {
        // Complete all requests already enqueued before returning. Serial rendering
        // avoids access races while allowing the caller to change render contexts.
        queue.sync {}
    }
}

internal enum SubtitleRasterizer {
    static func image(_ cue: SubtitleCue, canvas: CGSize) throws -> CIImage {
        let font = CTFontCreateWithName("PingFangSC-Semibold" as CFString, cue.fontSize, nil)
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let hex = cue.colorHex.replacingOccurrences(of: "#", with: "")
        guard let value = UInt32(hex, radix: 16), hex.count == 6 else { throw MediaEngineError.invalid("字幕颜色需为 #RRGGBB") }
        let color = CGColor(colorSpace: srgb, components: [CGFloat((value >> 16) & 255) / 255, CGFloat((value >> 8) & 255) / 255, CGFloat(value & 255) / 255, 1])!
        var alignment = CTTextAlignment.center
        let paragraph: CTParagraphStyle = withUnsafePointer(to: &alignment) { pointer in
            var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: pointer)
            return CTParagraphStyleCreate(&setting, 1)
        }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph
        ]
        let text = NSAttributedString(string: cue.text, attributes: attributes)
        let setter = CTFramesetterCreateWithAttributedString(text)
        let width = floor(canvas.width * 0.86)
        let inset = 16.0
        let fitted = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: text.length), nil, CGSize(width: width - 2 * inset, height: 10000), nil)
        let textHeight = ceil(fitted.height) + 8
        let height = max(ceil(cue.fontSize * 1.45), textHeight) + 2 * inset
        guard let bitmap = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw MediaEngineError.render("无法创建字幕画面") }
        bitmap.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.62))
        bitmap.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height), cornerWidth: 10, cornerHeight: 10, transform: nil))
        bitmap.fillPath()
        let path = CGPath(rect: CGRect(x: inset, y: inset + 4, width: width - 2 * inset, height: height - 2 * inset), transform: nil)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: text.length), path, nil)
        // CJK fallback fonts can have substantially taller metrics than fontSize.
        // Enforce the two-line rule against Core Text's actual layout, not a
        // font-size multiplier, and verify that no trailing text was clipped.
        let visibleRange = CTFrameGetVisibleStringRange(frame)
        guard CFArrayGetCount(CTFrameGetLines(frame)) <= 2 else {
            throw MediaEngineError.invalid("字幕排版超过两行，请缩短文字或减小字号：\(cue.text.prefix(30))")
        }
        guard visibleRange.location == 0, visibleRange.length == text.length else {
            throw MediaEngineError.render("字幕排版未能完整容纳文字")
        }
        guard height <= canvas.height else { throw MediaEngineError.invalid("字幕框高于画面，请减小字号：\(cue.text.prefix(30))") }
        CTFrameDraw(frame, bitmap)
        guard let cgImage = bitmap.makeImage() else { throw MediaEngineError.render("字幕栅格化失败") }
        let y = SubtitleLayout.originY(canvasHeight: canvas.height, boxHeight: height, positionY: cue.positionY)
        return CIImage(cgImage: cgImage, options: [.colorSpace: srgb]).transformed(by: CGAffineTransform(translationX: (canvas.width - width) / 2, y: y))
    }
}
