import SwiftUI
import AVFoundation
import AppKit

// MARK: - Figma-style floating action button

/// A small, polished floating button: rounded-rect, frosted material, hairline
/// border, soft shadow, and the app's hover lift. Reusable for any card action.
struct FloatingActionButton: View {
    let systemName: String
    var help: String = ""
    var prominent: Bool = false        // accent-filled instead of material
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(prominent ? Color.white : Color.primary)
                .frame(width: 34, height: 34)
                .background {
                    if prominent {
                        RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.accentColor)
                    } else {
                        RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.regularMaterial)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.20), radius: 8, y: 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.hover)
        .help(help)
    }
}

// MARK: - Seekable preview player

/// Owns a plain `AVPlayer` (not a looper) for the trim editor: seekable,
/// publishes its playhead, and loops back to the in-point when it reaches the
/// out-point so the preview shows exactly what the trimmed card will play.
final class TrimPlayerModel: ObservableObject {
    let player: AVPlayer
    @Published var playhead: Double = 0
    @Published var isPlaying = false

    private var loopRange: ClosedRange<Double>?
    private var observer: Any?

    init(url: URL) {
        player = AVPlayer(url: url)
        player.isMuted = true          // no surprise audio; this is a visual edit
        let interval = CMTime(seconds: 0.03, preferredTimescale: 600)
        // Observer fires on the main queue, so mutating @Published here is safe.
        observer = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] t in
            guard let self else { return }
            let sec = t.seconds
            guard sec.isFinite else { return }
            self.playhead = sec
            // Loop within the trimmed range.
            if let r = self.loopRange, sec >= r.upperBound - 0.015 {
                self.rawSeek(r.lowerBound)
            }
        }
    }

    func setRange(_ inSec: Double, _ outSec: Double) {
        loopRange = inSec...max(inSec + 0.05, outSec)
        if playhead < inSec || playhead > outSec { rawSeek(inSec) }
    }
    func play()  { player.play();  isPlaying = true }
    func pause() { player.pause(); isPlaying = false }
    func togglePlay() { isPlaying ? pause() : play() }

    /// Pause + jump to a time (used while dragging a handle so you see the edge).
    func scrub(to sec: Double) { pause(); rawSeek(sec) }

    private func rawSeek(_ sec: Double) {
        player.seek(to: CMTime(seconds: sec, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        playhead = sec
    }

    func dispose() {
        if let observer { player.removeTimeObserver(observer); self.observer = nil }
        player.pause()
    }
}

/// Thin `AVPlayerLayer` host bound to an external `AVPlayer` (reuses the
/// `PlayerHostView` from `TweetVideoPlayer.swift`).
private struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    var cornerRadius: CGFloat = 0

    func makeNSView(context: Context) -> PlayerHostView {
        let v = PlayerHostView()
        v.attach(player: player)
        v.playerLayer.cornerRadius = cornerRadius
        v.playerLayer.masksToBounds = cornerRadius > 0
        return v
    }
    func updateNSView(_ v: PlayerHostView, context: Context) {
        if v.playerLayer.player !== player { v.attach(player: player) }
        v.playerLayer.cornerRadius = cornerRadius
        v.playerLayer.masksToBounds = cornerRadius > 0
    }
}

// MARK: - Inline trim editor (overlaid on the card)

/// In-place video trim editor: a seekable preview filling the card, a filmstrip
/// timeline pinned along the bottom with two draggable in/out handles + a
/// playhead, and compact Done / Reset / Cancel controls. Non-destructive —
/// `onSave` hands back the chosen `[start, end]` seconds.
struct VideoTrimOverlay: View {
    let fileURL: URL
    let initialStart: Double?
    let initialEnd: Double?
    var cornerRadius: CGFloat = 14
    var onSave: (Double, Double) -> Void
    var onReset: () -> Void
    var onCancel: () -> Void

    @StateObject private var model: TrimPlayerModel
    @State private var duration: Double = 0
    @State private var thumbnails: [NSImage] = []
    @State private var inSec: Double = 0
    @State private var outSec: Double = 0
    @State private var dragging: Handle? = nil
    @State private var dragAnchor: Double = 0

    private enum Handle { case start, end }
    private let minGap: Double = 0.2
    private let stripHeight: CGFloat = 56

    init(fileURL: URL, initialStart: Double?, initialEnd: Double?,
         cornerRadius: CGFloat = 14,
         onSave: @escaping (Double, Double) -> Void,
         onReset: @escaping () -> Void,
         onCancel: @escaping () -> Void) {
        self.fileURL = fileURL
        self.initialStart = initialStart
        self.initialEnd = initialEnd
        self.cornerRadius = cornerRadius
        self.onSave = onSave
        self.onReset = onReset
        self.onCancel = onCancel
        _model = StateObject(wrappedValue: TrimPlayerModel(url: fileURL))
    }

    var body: some View {
        ZStack {
            PlayerLayerView(player: model.player, cornerRadius: cornerRadius)

            // Top controls: play/pause (left) + Reset / Cancel / Apply (right).
            VStack {
                HStack(spacing: 8) {
                    FloatingActionButton(systemName: model.isPlaying ? "pause.fill" : "play.fill",
                                         help: model.isPlaying ? "Pause" : "Play") {
                        model.togglePlay()
                    }
                    Spacer()
                    FloatingActionButton(systemName: "arrow.counterclockwise",
                                         help: "Reset to full clip") {
                        onReset()
                    }
                    FloatingActionButton(systemName: "xmark", help: "Cancel") { onCancel() }
                    FloatingActionButton(systemName: "checkmark", help: "Apply trim",
                                         prominent: true) {
                        onSave(inSec, outSec)
                    }
                }
                Spacer()
            }
            .padding(10)

            // Bottom timeline strip.
            VStack {
                Spacer()
                if duration > 0 {
                    timeline
                        .frame(height: stripHeight)
                        .padding(10)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: fileURL) { await load() }
        .onDisappear { model.dispose() }
    }

    // MARK: timeline

    private var timeline: some View {
        GeometryReader { geo in
            let W = geo.size.width
            let xIn = x(for: inSec, width: W)
            let xOut = x(for: outSec, width: W)
            let xHead = x(for: model.playhead, width: W)

            ZStack(alignment: .leading) {
                // Filmstrip.
                HStack(spacing: 0) {
                    ForEach(Array(thumbnails.enumerated()), id: \.offset) { _, img in
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: max(1, W / CGFloat(max(1, thumbnails.count))),
                                   height: stripHeight)
                            .clipped()
                    }
                }
                .frame(width: W, height: stripHeight, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                // Dim outside the selection.
                Color.black.opacity(0.55).frame(width: max(0, xIn))
                Color.black.opacity(0.55)
                    .frame(width: max(0, W - xOut))
                    .offset(x: xOut)

                // Selection border.
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .frame(width: max(0, xOut - xIn))
                    .offset(x: xIn)

                // Playhead.
                Rectangle().fill(Color.white)
                    .frame(width: 2, height: stripHeight)
                    .offset(x: min(max(xHead, 0), W) - 1)
                    .shadow(color: .black.opacity(0.5), radius: 1)

                handle(at: xIn, which: .start, width: W)
                handle(at: xOut, which: .end, width: W)
            }
            .frame(width: W, height: stripHeight)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func handle(at hx: CGFloat, which: Handle, width W: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Color.accentColor)
            .frame(width: 12, height: stripHeight + 6)
            .overlay(
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.white.opacity(0.9)).frame(width: 2, height: 18)
            )
            .offset(x: hx - 6)
            .contentShape(Rectangle().inset(by: -10))   // generous hit target
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if dragging != which {
                            dragging = which
                            dragAnchor = (which == .start ? inSec : outSec)
                            model.pause()
                        }
                        let dt = Double(v.translation.width / max(1, W)) * duration
                        if which == .start {
                            inSec = min(max(0, dragAnchor + dt), outSec - minGap)
                            model.scrub(to: inSec)
                        } else {
                            outSec = max(min(duration, dragAnchor + dt), inSec + minGap)
                            model.scrub(to: outSec)
                        }
                    }
                    .onEnded { _ in
                        dragging = nil
                        model.setRange(inSec, outSec)
                        model.play()
                    }
            )
    }

    private func x(for t: Double, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(t / duration) * width
    }

    // MARK: load

    private func load() async {
        let asset = AVURLAsset(url: fileURL)
        let dur = (try? await asset.load(.duration).seconds) ?? 0
        guard dur.isFinite, dur > 0 else { return }
        duration = dur
        inSec = max(0, initialStart ?? 0)
        outSec = min(dur, initialEnd ?? dur)
        if outSec <= inSec { inSec = 0; outSec = dur }
        model.setRange(inSec, outSec)
        model.play()
        thumbnails = await Self.thumbnails(for: fileURL, duration: dur, count: 10,
                                           height: stripHeight)
    }

    /// Evenly-spaced filmstrip frames (decoded off the main actor).
    private static func thumbnails(for url: URL, duration: Double,
                                   count: Int, height: CGFloat) async -> [NSImage] {
        await Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: url)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: height * 3, height: height * 2)
            gen.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
            gen.requestedTimeToleranceAfter  = CMTime(seconds: 0.5, preferredTimescale: 600)
            var out: [NSImage] = []
            for i in 0..<count {
                let frac = (Double(i) + 0.5) / Double(count)
                let t = CMTime(seconds: duration * frac, preferredTimescale: 600)
                if let cg = try? gen.copyCGImage(at: t, actualTime: nil) {
                    out.append(NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)))
                }
            }
            return out
        }.value
    }
}
