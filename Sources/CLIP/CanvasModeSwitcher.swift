import SwiftUI

/// Mode switcher — a 3-tab segmented control matching the Figma spec exactly:
/// a green (#3DA726) trough with inner shadow, and a yellow-gradient active pill
/// that slides between tabs. Font: SF Mono Semibold 17pt, uppercase labels.
/// (Figma node 73-37182, 357×50pt. Sidebar stays SwiftUI.)
struct CanvasModeSwitcher: View {
    @EnvironmentObject var state: CanvasState
    @Namespace private var pill

    // Candy colours shared with the tool palette (sRGB, matching Figma hex).
    private static let green     = Color(.sRGB, red: 0.239, green: 0.655, blue: 0.149, opacity: 1)  // #3DA726
    private static let rimYellow = Color(.sRGB, red: 1.000, green: 0.988, blue: 0.663, opacity: 1)  // #FFFCA9
    private static let topYellow = Color(.sRGB, red: 1.000, green: 0.957, blue: 0.231, opacity: 1)  // #FFF53B
    private static let botYellow = Color(.sRGB, red: 0.973, green: 0.871, blue: 0.278, opacity: 1)  // #F8DE47

    var body: some View {
        HStack(spacing: 0) {
            tab(for: .canvas)
            tab(for: .colorform)
            tab(for: .archive)
        }
        .frame(height: 50)
        .background(trough)
        .clipShape(Capsule(style: .continuous))
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: state.canvasMode)
    }

    // Green capsule with inner-shadow overlay (dark top stroke simulates depth).
    @ViewBuilder
    private var trough: some View {
        Capsule(style: .continuous)
            .fill(Self.green)
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.black.opacity(0.22), .clear],
                            startPoint: .top,
                            endPoint: .init(x: 0.5, y: 0.35)
                        ),
                        lineWidth: 1.5
                    )
            )
    }

    @ViewBuilder
    private func tab(for mode: CanvasMode) -> some View {
        let isActive = state.canvasMode == mode
        let isComputing = mode == .colorform && state.isComputingColorform

        Button { state.setMode(mode) } label: {
            HStack(spacing: 5) {
                if isComputing {
                    ProgressView().controlSize(.mini)
                        .colorScheme(.light)   // spinner is visible on green bg
                        .frame(width: 14, height: 14)
                }
                Text(mode.label)
                    .textCase(.uppercase)
                    .font(.system(size: 17, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .foregroundStyle(isActive ? Color.black : Color.white.opacity(0.92))
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if isActive {
                    Capsule(style: .continuous)
                        .fill(LinearGradient(
                            stops: [
                                .init(color: Self.rimYellow, location: 0),
                                .init(color: Self.rimYellow, location: 0.034),
                                .init(color: Self.topYellow, location: 0.034),
                                .init(color: Self.botYellow, location: 1),
                            ],
                            startPoint: .top, endPoint: .bottom))
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(.black.opacity(0.08), lineWidth: 0.5)
                        )
                        .padding(3)
                        .matchedGeometryEffect(id: "pill", in: pill)
                }
            }
        }
        .buttonStyle(.plain)
        .help(helpText(for: mode))
        .accessibilityLabel(mode.label)
        .accessibilityIdentifier("mode.switcher.\(mode.rawValue)")
    }

    private func helpText(for mode: CanvasMode) -> String {
        switch mode {
        case .canvas:    return "Edit on the infinite canvas (⌘1)"
        case .colorform: return "Group cards by dominant color (⌘2)"
        case .archive:   return "Everything you've added, newest first (⌘3)"
        }
    }
}
