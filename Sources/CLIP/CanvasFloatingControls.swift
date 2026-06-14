import SwiftUI

// MARK: - Bottom-left zoom pill  (Freeform-style)

struct ZoomControlsPill: View {
    @EnvironmentObject var state: CanvasState

    var body: some View {
        HStack(spacing: 0) {
            iconButton(systemName: "minus", action: state.zoomOut)
                .help("Zoom out  (⌘−)")
                .accessibilityLabel("Zoom out")
                .accessibilityIdentifier("zoom.out")

            ZoomPercentMenu()
                .accessibilityIdentifier("zoom.level")

            iconButton(systemName: "plus", action: state.zoomIn)
                .help("Zoom in  (⌘+)")
                .accessibilityLabel("Zoom in")
                .accessibilityIdentifier("zoom.in")
        }
        .padding(.horizontal, 4)
        .background(.regularMaterial, in: Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.07), radius: 5, y: 1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("zoom.pill")
        // Fit-to-view + zoom-to-selection live in the chevron dropdown
        // (and have ⌘1 / ⇧1 shortcuts) — keeping the pill itself tight
        // and symmetrical, Freeform-style.
    }

    private func iconButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                // 30pt target — comfortably above the ~24pt Fitts floor.
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.hover)
    }
}

// MARK: - Zoom % dropdown (Figma-style)

/// The clickable `XX %` readout in the centre of the zoom pill. Tapping it
/// drops a menu with presets, "Zoom to fit", "Zoom to selection", and a
/// free-form % input.
private struct ZoomPercentMenu: View {
    @EnvironmentObject var state: CanvasState
    @EnvironmentObject var cameraStore: CameraStore
    @State private var customZoom: String = ""

    var body: some View {
        Menu {
            // Custom % input row.
            customInputRow
            Divider()
            Button("Zoom to 100%  ⌘0") { state.resetView() }
            Button("Zoom to fit   ⌘1") { state.zoomToFit() }
            Button("Zoom to selection  ⇧1") { state.zoomToSelection() }
            Divider()
            ForEach(Self.presets, id: \.self) { pct in
                Button("\(pct)%") { state.setZoom(Double(pct) / 100) }
            }
        } label: {
            HStack(spacing: 3) {
                Text("\(Int(cameraStore.camera.zoom * 100)) %")
                    // Monospaced digits — the live readout must not change
                    // width (and shift the pill) as the zoom level changes.
                    .font(.clip(11.5).monospacedDigit())
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 50)
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Change zoom level")
    }

    /// Top row of the menu: editable % field. Pressing return jumps the
    /// camera there; clamped through `setZoom`.
    @ViewBuilder
    private var customInputRow: some View {
        // SwiftUI Menus on macOS render arbitrary content in a label
        // container. A small TextField sized to the menu width gives the
        // user a precise input without leaving the dropdown.
        TextField("Custom %", text: $customZoom)
            .textFieldStyle(.plain)
            .frame(width: 90)
            .onSubmit {
                let trimmed = customZoom.trimmingCharacters(in: .whitespaces)
                if let pct = Int(trimmed), pct > 0 {
                    state.setZoom(CGFloat(pct) / 100)
                }
                customZoom = ""
            }
    }

    /// Standard Figma-ish preset levels.
    private static let presets: [Int] = [25, 50, 100, 200, 400]
}

// MARK: - Bottom-right connectors / grid toggle pill

struct CanvasTogglesPill: View {
    @EnvironmentObject var state: CanvasState

    var body: some View {
        HStack(spacing: 0) {
            toggleButton(
                // Connected-points glyph (filled when on) — reads as
                // "connections" far better than a bare bezier curve.
                systemName: state.showConnectors
                    ? "point.3.filled.connected.trianglepath.dotted"
                    : "point.3.connected.trianglepath.dotted",
                isOn: state.showConnectors,
                onToggle: { state.showConnectors.toggle() },
                helpOn: "Hide connectors",
                helpOff: "Show connectors"
            )
            .accessibilityLabel("Toggle connectors")
            .accessibilityIdentifier("toggle.connectors")

            Divider()
                .frame(height: 14)
                .padding(.horizontal, 2)

            toggleButton(
                systemName: state.showGrid ? "circle.grid.3x3.fill" : "circle.grid.3x3",
                isOn: state.showGrid,
                onToggle: { state.showGrid.toggle() },
                helpOn: "Hide grid",
                helpOff: "Show grid"
            )
            .accessibilityLabel("Toggle grid")
            .accessibilityIdentifier("toggle.grid")

            Divider()
                .frame(height: 14)
                .padding(.horizontal, 2)

            toggleButton(
                // Slashed-play = playback disabled (previews only). The
                // old pause glyph read backwards.
                systemName: state.videosShowPreviewOnly ? "play.slash.fill" : "play.fill",
                isOn: state.videosShowPreviewOnly,
                onToggle: { state.videosShowPreviewOnly.toggle() },
                helpOn: "Resume video playback",
                helpOff: "Show video previews only"
            )
            .accessibilityLabel("Toggle video previews")
            .accessibilityIdentifier("toggle.videoPreview")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 0)
        .background(.regularMaterial, in: Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.07), radius: 5, y: 1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("canvas.toggles")
    }

    private func toggleButton(
        systemName: String,
        isOn: Bool,
        onToggle: @escaping () -> Void,
        helpOn: String,
        helpOff: String
    ) -> some View {
        Button(action: onToggle) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(isOn ? Color.primary : Color.secondary)
                // 32×30 target — comfortably above the ~24pt Fitts floor.
                .frame(width: 32, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.hover)
        .help(isOn ? helpOn : helpOff)
    }
}

// MARK: - Active tool chip (top-center)

/// Acute mode visibility: while a non-Select tool is active, this chip
/// floats at the top of the canvas so it's always clear WHY clicks now
/// draw / place text / connect instead of selecting. Click it (or press
/// V) to return to Select.
struct ActiveToolChip: View {
    @EnvironmentObject var state: CanvasState

    var body: some View {
        Button {
            state.toolMode = .select
        } label: {
            HStack(spacing: 7) {
                Image(systemName: state.toolMode.systemImage)
                    .font(.system(size: 12, weight: .medium))
                Text("\(state.toolMode.label) tool")
                    .font(.system(size: 12, weight: .semibold))
                Text("·  press V to select")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(.regularMaterial, in: Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.10), radius: 6, y: 2)
        .help("Click to switch back to the Select tool (V)")
        .accessibilityLabel("Active tool: \(state.toolMode.label). Click to return to Select.")
        .accessibilityIdentifier("canvas.activeToolChip")
    }
}
