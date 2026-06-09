import SwiftUI
import AVFoundation
import AppKit

// MARK: - Liquid Glass helper

@available(macOS 26.0, *)
private func clipGlass(tint: Color?, interactive: Bool) -> Glass {
    var g: Glass = .regular
    if let tint { g = g.tint(tint) }
    if interactive { g = g.interactive() }
    return g
}

extension View {
    /// Real macOS 26 Liquid Glass where available; a frosted-material
    /// approximation on earlier systems so the same call site works on both.
    @ViewBuilder
    func liquidGlass(in shape: some Shape, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(clipGlass(tint: tint, interactive: interactive), in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(.white.opacity(0.22), lineWidth: 0.5))
        }
    }
}

// MARK: - Figma-style floating action button

/// A small, polished floating button: rounded-rect, frosted material, hairline
/// border, soft shadow, and the app's hover lift. Reusable for any card action.
struct FloatingActionButton: View {
    let systemName: String
    var help: String = ""
    var prominent: Bool = false        // accent-filled instead of glass
    var size: CGFloat = 40
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(prominent ? Color.white : Color.white.opacity(0.95))
                .frame(width: size, height: size)
                .background(
                    Circle().fill(prominent ? Color.accentColor : Color(white: 0.20))
                )
                .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                .contentShape(Circle())
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
    /// Decode resolution for filmstrip frames (the rendered strip scales to fit).
    private let stripHeight: CGFloat = 132

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
        GeometryReader { geo in
            let W = geo.size.width
            let H = geo.size.height
            let hPad: CGFloat = max(16, min(56, W * 0.05))
            let cW = max(40, W - hPad * 2)
            // Cap the widget to a phone-like width and CENTER it, so it keeps
            // the reference's proportions instead of stretching across a huge
            // card. Filmstrip height follows from that width (~5:1).
            let widgetW = min(cW * 0.9, 1280)
            let stripH = max(64, min(widgetW * 0.18, H * 0.34, 230))
            let rulerH: CGFloat = max(16, min(34, stripH * 0.16))
            let gap: CGFloat = max(6, stripH * 0.07)
            let outset = max(3, stripH * 0.05)
            let scrubH = rulerH + gap + stripH + outset
            let btnSize = max(36, min(54, stripH * 0.28))

            ZStack {
                // Live preview fills the card; only the bottom bar is chrome.
                PlayerLayerView(player: model.player, cornerRadius: cornerRadius)

                // A Spacer pushes the whole bottom bar (strip + buttons) down as
                // one block, so the control row is always part of it and never
                // gets clipped past the card's bottom edge.
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    VStack(spacing: max(12, stripH * 0.1)) {
                        if duration > 0 {
                            scrubber(W: widgetW, rulerH: rulerH, gap: gap, stripH: stripH, fullH: scrubH)
                                .frame(width: widgetW, height: scrubH)
                        } else {
                            ProgressView().controlSize(.small).tint(.white).frame(height: stripH)
                        }
                        controlRow(size: btnSize).frame(width: widgetW)
                    }
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
                    .background(bottomPanel)
                }
            }
            .frame(width: W, height: H)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .task(id: fileURL) { await load() }
        .onDisappear { model.dispose() }
    }

    /// Top-rounded dark Liquid Glass panel behind the bottom timeline bar.
    private var bottomPanel: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 0,
                                           bottomTrailingRadius: 0, topTrailingRadius: 18,
                                           style: .continuous)
        return Color.clear
            .liquidGlass(in: shape, tint: .black.opacity(0.5))
            .overlay(shape.strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
    }

    // MARK: bottom controls (kept compact — the reference's faded bottom row)

    private func controlRow(size: CGFloat) -> some View {
        HStack(spacing: 10) {
            FloatingActionButton(systemName: "xmark", help: "Cancel", size: size) { onCancel() }
            Spacer()
            FloatingActionButton(systemName: model.isPlaying ? "pause.fill" : "play.fill",
                                 help: model.isPlaying ? "Pause" : "Play", size: size) { model.togglePlay() }
            FloatingActionButton(systemName: "arrow.counterclockwise",
                                 help: "Reset to full clip", size: size) { onReset() }
            Spacer()
            FloatingActionButton(systemName: "checkmark", help: "Apply trim",
                                 prominent: true, size: size) { onSave(inSec, outSec) }
        }
    }

    // MARK: - Scrubber (ruler + filmstrip + selection + playhead)

    private func scrubber(W: CGFloat, rulerH: CGFloat, gap: CGFloat,
                          stripH: CGFloat, fullH: CGFloat) -> some View {
        let xIn   = x(for: inSec, width: W)
        let xOut  = x(for: outSec, width: W)
        let xHead = min(max(x(for: model.playhead, width: W), 0), W)
        let stripTop = rulerH + gap
        let outset: CGFloat = max(3, stripH * 0.05)     // white frame overhangs the strip
        let selW   = max(0, xOut - xIn)
        let frameH = stripH + outset * 2
        let frameR = frameH * 0.13
        let innerR = stripH * 0.09
        let border = max(4, stripH * 0.05)
        let lineTop = rulerH / 2
        let lineBottom = fullH                          // line runs to the bottom

        return ZStack(alignment: .topLeading) {
            // Ruler across the top.
            ruler(W: W, height: rulerH)

            // Filmstrip with the un-selected portions dimmed.
            filmstrip(W: W, stripH: stripH, xIn: xIn, xOut: xOut, innerR: innerR)
                .offset(y: stripTop)

            // Selection: white frame + time badges (grips are separate, on top).
            ZStack {
                RoundedRectangle(cornerRadius: frameR, style: .continuous)
                    .strokeBorder(.white, lineWidth: border)

                VStack {
                    HStack {
                        timeBadge(formatTime(inSec), stripH: stripH)
                        Spacer(minLength: 0)
                        timeBadge(formatTime(outSec), stripH: stripH)
                    }
                    Spacer(minLength: 0)
                }
                .padding(max(8, stripH * 0.13))
            }
            .frame(width: selW, height: frameH)
            .offset(x: xIn, y: stripTop - outset)

            // Playhead line + Liquid Glass knob (knob rides the ruler).
            Rectangle().fill(.white.opacity(0.5))
                .frame(width: max(1.5, stripH * 0.012), height: lineBottom - lineTop)
                .position(x: xHead, y: lineTop + (lineBottom - lineTop) / 2)
            playKnob(diameter: max(20, min(42, stripH * 0.18)))
                .position(x: xHead, y: lineTop)
                .gesture(headDrag(W: W))

            // The two draggable grips — dark pills sitting just inside the
            // white frame's left/right borders (never clipped at the edges).
            let pillW = max(6, stripH * 0.05)
            let gInset = border * 0.5 + pillW * 0.5 + 2
            gripHandle(stripH: stripH)
                .position(x: min(max(xIn + gInset, gInset), W - gInset), y: stripTop + stripH / 2)
                .gesture(handleDrag(.start, W: W))
            gripHandle(stripH: stripH)
                .position(x: max(min(xOut - gInset, W - gInset), gInset), y: stripTop + stripH / 2)
                .gesture(handleDrag(.end, W: W))
        }
        .frame(width: W, height: fullH, alignment: .topLeading)
        .coordinateSpace(name: Self.space)
    }

    private static let space = "trimStrip"

    // MARK: ruler

    private func ruler(W: CGFloat, height: CGFloat) -> some View {
        let step = Self.niceStep(duration)
        let majors = Array(stride(from: 0, through: duration + 0.0001, by: step))
        let minors = majors.compactMap { m -> Double? in
            let t = m + step / 2
            return t < duration ? t : nil
        }
        let labelSize = max(9, min(17, height * 0.55))
        let majTick = max(4, height * 0.28)
        let minTick = majTick * 0.6
        return ZStack(alignment: .topLeading) {
            ForEach(minors, id: \.self) { t in
                Rectangle().fill(.white.opacity(0.16))
                    .frame(width: 1, height: minTick)
                    .position(x: x(for: t, width: W), y: height - minTick / 2)
            }
            ForEach(majors, id: \.self) { t in
                VStack(spacing: 2) {
                    Text(Self.tickLabel(t)).font(.clip(labelSize)).foregroundStyle(.white.opacity(0.9))
                    Rectangle().fill(.white.opacity(0.30)).frame(width: 1, height: majTick)
                }
                .fixedSize()
                .position(x: x(for: t, width: W), y: height / 2)
            }
        }
        .frame(width: W, height: height, alignment: .topLeading)
    }

    // MARK: filmstrip

    private func filmstrip(W: CGFloat, stripH: CGFloat,
                           xIn: CGFloat, xOut: CGFloat, innerR: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                ForEach(Array(thumbnails.enumerated()), id: \.offset) { _, img in
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: max(1, W / CGFloat(max(1, thumbnails.count))), height: stripH)
                        .clipped()
                }
            }
            .frame(width: W, height: stripH, alignment: .leading)

            // Dim everything outside the selection.
            Color.black.opacity(0.5).frame(width: max(0, xIn))
            Color.black.opacity(0.5).frame(width: max(0, W - xOut)).offset(x: xOut)
        }
        .frame(width: W, height: stripH, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: innerR, style: .continuous))
    }

    // MARK: small pieces

    private func playKnob(diameter: CGFloat) -> some View {
        // The element the reference renders in Liquid Glass: a glass disc with
        // a bright center dot, riding the ruler.
        Circle().fill(.white)
            .frame(width: diameter * 0.26, height: diameter * 0.26)
            .frame(width: diameter, height: diameter)
            .liquidGlass(in: Circle(), interactive: true)
            .shadow(color: .black.opacity(0.45), radius: 4, y: 1)
    }

    /// A visible dark grip pill with a generous transparent hit area around it,
    /// so it's both obvious and easy to grab.
    private func gripHandle(stripH: CGFloat) -> some View {
        let pillW = max(6, stripH * 0.05)
        let pillH = stripH * 0.46
        return ZStack {
            Color.black.opacity(0.001)
                .frame(width: max(60, stripH * 0.7), height: pillH + stripH * 0.5)
            // Dark pill that reads as a notch inside the white frame edge.
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.55))
                .overlay(Capsule(style: .continuous)
                    .strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
                .frame(width: pillW, height: pillH)
        }
        .contentShape(Rectangle())
    }

    private func timeBadge(_ s: String, stripH: CGFloat) -> some View {
        let fs = max(10, min(26, stripH * 0.14))
        return Text(s)
            .font(.clip(fs))
            .foregroundStyle(.white)
            .padding(.horizontal, fs * 0.7)
            .padding(.vertical, fs * 0.35)
            .liquidGlass(in: Capsule(style: .continuous), tint: .black.opacity(0.4))
            .fixedSize()
    }

    // MARK: gestures

    private func handleDrag(_ which: Handle, W: CGFloat) -> some Gesture {
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
    }

    private func headDrag(W: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { v in
                let t = min(max(0, Double(v.location.x / max(1, W)) * duration), duration)
                model.scrub(to: t)
            }
    }

    // MARK: formatting

    private func formatTime(_ sec: Double) -> String {
        let s = max(0, Int(sec.rounded()))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    private static func tickLabel(_ t: Double) -> String {
        t == t.rounded() ? "\(Int(t))s" : String(format: "%.1fs", t)
    }

    /// Pick a "nice" major-tick interval so the ruler shows ~4–6 labels.
    private static func niceStep(_ duration: Double) -> Double {
        guard duration > 0 else { return 1 }
        for s in [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300] where duration / s <= 6 { return s }
        return ceil(duration / 6)
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
        thumbnails = await Self.thumbnails(for: fileURL, duration: dur, count: 16,
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
