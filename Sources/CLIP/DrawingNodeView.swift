import SwiftUI

/// Renders a stored DrawingStroke. The stroke's `points` are already in
/// node-local coordinates, so this view just draws the smoothed path.
struct DrawingNodeView: View {
    let stroke: DrawingStroke
    let size: CGSize
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            PathMath.smoothPath(through: stroke.points)
                .stroke(
                    stroke.color.swiftUIColor,
                    style: StrokeStyle(
                        lineWidth: stroke.width,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
                .frame(width: size.width, height: size.height)

            if hovering {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
                .tint(.red)
                .offset(x: 6, y: -6)
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
