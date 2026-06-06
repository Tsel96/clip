import SwiftUI
import AppKit
import CoreImage

/// Local image card. Decodes the in-memory `Data` into an `NSImage` and
/// draws it scaled to the parent frame.
///
/// **Semantic zoom.** When `isLive` is false (the card is off-viewport
/// or projected below the live breakpoint), we skip the full-resolution
/// `Image` render and draw a lightweight placeholder instead — no
/// `CALayer` backed by the decoded image is added to the view tree, so
/// the GPU has nothing to composite for this card. The decoded `NSImage`
/// stays cached in Swift memory so reappearance is instant. The
/// placeholder is tinted with the image's **average color** so a zoomed-
/// out canvas reads as a map of colors, not identical gray boxes.
struct ImageNodeView: View {
    let data: Data
    let filename: String
    let isLive: Bool

    @State private var nsImage: NSImage? = nil
    @State private var avgColor: Color? = nil
    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            if isLive, let nsImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            } else if !isLive {
                placeholder
                    .frame(width: geo.size.width, height: geo.size.height)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .figmaCardStyle(isElevated: hovering)
        .onHover { hovering = $0 }
        .task(id: filename) {
            // NSImage(data:) is fast, but do it off the SwiftUI evaluation
            // path so the very first frame isn't a giant decode. Compute the
            // average color in the same pass for the low-zoom placeholder.
            let bytes = data
            await Task.detached(priority: .userInitiated) {
                let img = NSImage(data: bytes)
                let avg = img.flatMap { ImageNodeView.averageColor(of: $0) }
                await MainActor.run {
                    self.nsImage = img
                    self.avgColor = avg
                }
            }.value
        }
    }

    /// Resting state shown when the card is below the live-render
    /// breakpoint. Filled with the image's average color (so it stays
    /// identifiable when zoomed out) with a faint photo glyph that reads at
    /// medium sizes and simply fades into the swatch when tiny.
    @ViewBuilder
    private var placeholder: some View {
        ZStack {
            (avgColor ?? Color(nsColor: .quaternaryLabelColor))
            Image(systemName: "photo")
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    /// Average color of the image via a 1×1 `CIAreaAverage` downsample.
    /// `nonisolated static` so it can run inside the off-main decode task.
    nonisolated static func averageColor(of image: NSImage) -> Color? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let ci = CIImage(cgImage: cg)
        let extent = ci.extent
        guard extent.width > 0, extent.height > 0,
              let filter = CIFilter(name: "CIAreaAverage", parameters: [
                  kCIInputImageKey: ci,
                  kCIInputExtentKey: CIVector(cgRect: extent),
              ]),
              let output = filter.outputImage else {
            return nil
        }
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CIContext(options: [.workingColorSpace: NSNull()])
        ctx.render(output,
                   toBitmap: &px,
                   rowBytes: 4,
                   bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                   format: .RGBA8,
                   colorSpace: CGColorSpaceCreateDeviceRGB())
        return Color(.sRGB,
                     red: Double(px[0]) / 255.0,
                     green: Double(px[1]) / 255.0,
                     blue: Double(px[2]) / 255.0,
                     opacity: 1.0)
    }
}
