import SwiftUI
import AppKit

/// Wraps `MinimapView` in a draggable + resizable floating panel that lives
/// inside the main canvas window. A "detach" button hands the minimap off to
/// a separate `NSPanel` floating window (see `MinimapWindowController`).
struct MinimapPanel: View {
    @EnvironmentObject var state: CanvasState

    @State private var size: CGSize = CGSize(width: 240, height: 200)
    @State private var origin: CGPoint? = nil   // top-left in canvas coords; nil = uninitialized

    @State private var moveStart: CGPoint? = nil
    @State private var resizeStart: CGSize? = nil

    private let titleBarHeight: CGFloat = 26
    private let cornerRadius: CGFloat = 10
    private let edgeMargin: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            panelView
                .position(
                    x: (origin?.x ?? defaultOrigin(in: geo.size).x) + size.width / 2,
                    y: (origin?.y ?? defaultOrigin(in: geo.size).y) + size.height / 2
                )
                .onAppear {
                    if origin == nil {
                        origin = defaultOrigin(in: geo.size)
                    }
                }
                .onChange(of: geo.size) { newSize in
                    // Keep panel within the new bounds when window resizes.
                    if let o = origin {
                        origin = CGPoint(
                            x: clamp(o.x, 0, max(0, newSize.width  - size.width)),
                            y: clamp(o.y, 0, max(0, newSize.height - size.height))
                        )
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
    }

    // MARK: - Panel

    private var panelView: some View {
        VStack(spacing: 0) {
            titleBar
            MinimapView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: size.width, height: size.height)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 4)
        .overlay(alignment: .bottomTrailing) { resizeHandle }
    }

    private var titleBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "map")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text("Minimap")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                state.detachMinimap()
            } label: {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.hover)
            .help("Detach to floating window")
        }
        .padding(.horizontal, 10)
        .frame(height: titleBarHeight)
        .background(.bar)
        .contentShape(Rectangle())
        .gesture(moveGesture)
    }

    private var resizeHandle: some View {
        // Bottom-right diagonal-arrow grip with a generous hit area.
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(5)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.7), in: Circle())
            .overlay(Circle().strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5))
            .padding(4)
            .gesture(resizeGesture)
            .help("Drag to resize")
    }

    // MARK: - Gestures

    private var moveGesture: some Gesture {
        DragGesture(coordinateSpace: .global)
            .onChanged { value in
                if moveStart == nil { moveStart = origin ?? .zero }
                guard let start = moveStart else { return }
                origin = CGPoint(
                    x: start.x + value.translation.width,
                    y: start.y + value.translation.height
                )
            }
            .onEnded { _ in moveStart = nil }
    }

    private var resizeGesture: some Gesture {
        DragGesture(coordinateSpace: .global)
            .onChanged { value in
                if resizeStart == nil { resizeStart = size }
                guard let start = resizeStart else { return }
                size = CGSize(
                    width:  max(160, start.width  + value.translation.width),
                    height: max(140, start.height + value.translation.height)
                )
            }
            .onEnded { _ in resizeStart = nil }
    }

    // MARK: - Helpers

    private func defaultOrigin(in canvas: CGSize) -> CGPoint {
        // Default to top-right so the bottom-right toggles pill stays clear.
        CGPoint(
            x: max(0, canvas.width  - size.width  - edgeMargin),
            y: edgeMargin
        )
    }

    private func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        max(lo, min(hi, v))
    }
}
