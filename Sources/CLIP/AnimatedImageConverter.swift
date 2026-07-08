import AVFoundation
import ImageIO

/// R18 — animated gif/webp → looping H.264 mp4 (Spatial does the same), so
/// animated drops play through the existing AVPlayerLooper video pipeline
/// instead of freezing on frame 0 in the static-image path. CGImageSource
/// decodes the frames + per-format delays; AVAssetWriter emits an even-
/// dimensioned, network-optimized mp4 into the media store. Call `mp4(from:)`
/// OFF the main thread — it blocks on encode.
enum AnimatedImageConverter {

    /// Cheap animation probe — counts frames without decoding any.
    static func isAnimated(_ data: Data) -> Bool {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(src) > 1
    }

    enum Err: Error { case badSource, writer }

    static func mp4(from data: Data) throws -> URL {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(src) > 1,
              let first = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw Err.badSource
        }
        let count = CGImageSourceGetCount(src)
        // H.264 requires even dimensions.
        let w = max(2, first.width & ~1), h = max(2, first.height & ~1)

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".mp4")
        let writer = try AVAssetWriter(outputURL: tmp, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
            ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? Err.writer }
        writer.startSession(atSourceTime: .zero)

        var t = 0.0
        // Don't let ImageIO cache every decoded frame — a 500-frame gif would
        // pin them all in memory; we touch each frame exactly once.
        let frameOpts = [kCGImageSourceShouldCache: false] as CFDictionary
        for i in 0..<count {
            guard let cg = CGImageSourceCreateImageAtIndex(src, i, frameOpts) else { continue }
            while !input.isReadyForMoreMediaData { usleep(2000) }
            // The pool appears asynchronously after startSession — wait for it
            // like the input, instead of failing the whole conversion.
            var poolWait = 0
            while adaptor.pixelBufferPool == nil, poolWait < 500 { usleep(2000); poolWait += 1 }
            guard let pool = adaptor.pixelBufferPool else { throw Err.writer }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let buf = pb else { throw Err.writer }
            CVPixelBufferLockBaseAddress(buf, [])
            if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buf),
                                   width: w, height: h, bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(buf),
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) {
                // mp4 has no alpha — composite gif/webp transparency on white
                // (matches the white card body behind the content).
                ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
            }
            CVPixelBufferUnlockBaseAddress(buf, [])
            adaptor.append(buf, withPresentationTime: CMTime(seconds: t, preferredTimescale: 600))
            t += frameDelay(src, i)
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: t, preferredTimescale: 600))
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        guard writer.status == .completed else { throw writer.error ?? Err.writer }

        let stored = MediaStore.importFile(tmp)
        try? FileManager.default.removeItem(at: tmp)
        return stored
    }

    /// Per-frame delay with the browser convention: sub-11 ms delays are a
    /// legacy-gif speed exploit and render as 100 ms everywhere.
    private static func frameDelay(_ src: CGImageSource, _ i: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil)
                as? [CFString: Any] else { return 0.1 }
        var delay: Double?
        if let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
            delay = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double
                ?? gif[kCGImagePropertyGIFDelayTime] as? Double
        } else if let webp = props[kCGImagePropertyWebPDictionary] as? [CFString: Any] {
            delay = webp[kCGImagePropertyWebPUnclampedDelayTime] as? Double
                ?? webp[kCGImagePropertyWebPDelayTime] as? Double
        }
        let v = delay ?? 0.1
        return v < 0.011 ? 0.1 : v
    }
}
