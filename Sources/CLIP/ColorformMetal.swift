import SwiftUI
import MetalKit
import Combine

/// GPU color field for Colorform mode — replaces the SwiftUI Voronoi+blur in
/// `ColorformLayer`. A single fragment shader blends the bulb colours by a
/// gaussian distance weight (pure centres, soft boundaries with NO blur pass,
/// cream-fading edges), so a pan/zoom is just a uniform update + one GPU draw
/// instead of a per-frame CPU Voronoi and three big SwiftUI blurs.
struct ColorformMetalView: NSViewRepresentable {
    let state: CanvasState
    let cameraStore: CameraStore

    func makeCoordinator() -> ColorformRenderer {
        ColorformRenderer(state: state, cameraStore: cameraStore)
    }

    func makeNSView(context: Context) -> MTKView {
        let v = MTKView(frame: .zero, device: context.coordinator.device)
        v.delegate = context.coordinator
        v.isPaused = false                // continuous: draw() pulls the live camera
        v.enableSetNeedsDisplay = false
        v.framebufferOnly = true
        v.colorPixelFormat = .bgra8Unorm
        v.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        v.layer?.isOpaque = false         // transparent edges → canvas bg/grid show through
        context.coordinator.attach(to: v)
        return v
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.refresh()
    }
}

// Swift mirrors of the Metal structs — all 4-byte scalars, tightly packed, so
// the layout matches the shader with no alignment surprises.
private struct CFUniforms {
    var zoom: Float = 1
    var camX: Float = 0
    var camY: Float = 0
    var pixelScale: Float = 2
    var creamR: Float = 0.985
    var creamG: Float = 0.965
    var creamB: Float = 0.945
    var sigma: Float = 300
    var bulbCount: Int32 = 0
    var hoverIndex: Int32 = -1
}
private struct CFBulb {
    var px: Float; var py: Float
    var r: Float; var g: Float; var b: Float
    var radius: Float
}

/// MTKView delegate + renderer. Subscribes to the camera + bulbs and redraws on
/// change — no SwiftUI re-render in the hot path. Main-actor: an on-demand MTKView
/// (`isPaused`+`enableSetNeedsDisplay`) drives `draw(in:)` from the main run-loop.
@MainActor
final class ColorformRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private var pipeline: MTLRenderPipelineState?
    private weak var view: MTKView?

    private var uniforms = CFUniforms()
    private var bulbBuffer: MTLBuffer?

    private let state: CanvasState
    private let cameraStore: CameraStore
    private var cancellables = Set<AnyCancellable>()

    init(state: CanvasState, cameraStore: CameraStore) {
        self.state = state
        self.cameraStore = cameraStore
        self.device = MTLCreateSystemDefaultDevice()!
        self.queue = device.makeCommandQueue()!
        super.init()
        buildPipeline()
        rebuildBulbs(state.colorBulbs)
        // The camera is pulled live in draw(in:) (continuous render); only the bulb
        // BUFFER needs rebuilding when the clusters change.
        state.$colorBulbs
            .sink { [weak self] bulbs in self?.rebuildBulbs(bulbs) }
            .store(in: &cancellables)
    }

    func attach(to v: MTKView) { view = v; refresh() }

    private func buildPipeline() {
        do {
            let lib = try device.makeLibrary(source: Self.shaderSource, options: nil)
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "cf_vertex")
            d.fragmentFunction = lib.makeFunction(name: "cf_fragment")
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: d)
        } catch {
            NSLog("Colorform Metal pipeline error: \(error)")
        }
    }

    private func rebuildBulbs(_ bulbs: [ColorBulb]) {
        guard !bulbs.isEmpty else { bulbBuffer = nil; uniforms.bulbCount = 0; return }
        var arr = bulbs.map {
            CFBulb(px: Float($0.center.x), py: Float($0.center.y),
                   r: Float($0.color.r), g: Float($0.color.g), b: Float($0.color.b),
                   radius: Float($0.radius))
        }
        bulbBuffer = device.makeBuffer(bytes: &arr,
                                       length: MemoryLayout<CFBulb>.stride * arr.count,
                                       options: .storageModeShared)
        uniforms.bulbCount = Int32(arr.count)
        // σ = average nearest-neighbour distance (the constellation's natural
        // spacing). The field/mask scale off this so the colour blobs fill BETWEEN
        // adjacent bulbs regardless of zoom — bulb `radius` is far smaller than the
        // spacing in the engine's layout, which is why the old σ made tiny dots.
        var nnSum: CGFloat = 0, nnCount = 0
        for i in bulbs.indices {
            var best = CGFloat.greatestFiniteMagnitude
            for j in bulbs.indices where j != i {
                let dx = bulbs[i].center.x - bulbs[j].center.x
                let dy = bulbs[i].center.y - bulbs[j].center.y
                best = min(best, dx * dx + dy * dy)
            }
            if best.isFinite { nnSum += best.squareRoot(); nnCount += 1 }
        }
        let nn = nnCount > 0 ? nnSum / CGFloat(nnCount) : (bulbs.first?.radius ?? 300)
        uniforms.sigma = max(Float(nn), 50)
    }

    func refresh() {
        guard let view else { return }
        let cam = cameraStore.camera
        uniforms.zoom = Float(max(cam.zoom, 0.0001))
        uniforms.camX = Float(cam.x)
        uniforms.camY = Float(cam.y)
        uniforms.pixelScale = Float(view.window?.backingScaleFactor ?? 2)
        view.setNeedsDisplay(view.bounds)
    }

    func draw(in view: MTKView) {
        // Pull the LIVE camera every frame so pan/zoom tracks without any SwiftUI
        // round-trip (this is the cheap GPU path the rewrite is all about).
        let cam = cameraStore.camera
        uniforms.zoom = Float(max(cam.zoom, 0.0001))
        uniforms.camX = Float(cam.x)
        uniforms.camY = Float(cam.y)
        uniforms.pixelScale = Float(view.window?.backingScaleFactor ?? 2)
        guard let pipeline,
              let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&uniforms, length: MemoryLayout<CFUniforms>.stride, index: 0)
        if let bb = bulbBuffer { enc.setFragmentBuffer(bb, offset: 0, index: 1) }
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { refresh() }

    // MARK: - Shader (compiled at runtime → no SwiftPM .metal/metallib step)

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms { float zoom; float camX; float camY; float pixelScale;
                      float creamR; float creamG; float creamB; float sigma;
                      int bulbCount; int hoverIndex; };
    struct Bulb { float px; float py; float r; float g; float b; float radius; };
    struct VOut { float4 pos [[position]]; };

    vertex VOut cf_vertex(uint vid [[vertex_id]]) {
        float2 p[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
        VOut o; o.pos = float4(p[vid], 0.0, 1.0); return o;
    }

    fragment float4 cf_fragment(VOut in [[stage_in]],
                                constant Uniforms& u [[buffer(0)]],
                                constant Bulb* bulbs [[buffer(1)]]) {
        // pixel → world: inverse of screen = world*zoom + camOffset (points).
        float2 screenPt = in.pos.xy / max(u.pixelScale, 0.001);
        float2 world = (screenPt - float2(u.camX, u.camY)) / u.zoom;
        if (u.bulbCount == 0) return float4(0.0);

        float sig = max(u.sigma, 1.0);
        // Inverse-distance weighted blend → a smooth, FULL-BLEED colour field: every
        // pixel is the softly-blended nearest bulb colours (no gaps, no cream, no
        // hard cell edges) — the vibrant "nebula" look. `soft` sets how molten the
        // transitions are; larger = smoother.
        float soft = sig * sig * 0.30;
        float wsum = 0.0;
        float3 csum = float3(0.0);
        for (int i = 0; i < u.bulbCount; i++) {
            float2 d = world - float2(bulbs[i].px, bulbs[i].py);
            float w = 1.0 / (dot(d, d) + soft);
            if (i == u.hoverIndex) { w *= 2.2; }       // hover-effect hook
            wsum += w;
            csum += w * float3(bulbs[i].r, bulbs[i].g, bulbs[i].b);
        }
        float3 col = csum / max(wsum, 1e-6);
        // Vibrancy. The extracted card colours are often dark (real photos), which
        // read as a "dark background". Lift EVERY pixel to full value: take the
        // hue at unit value, scale to a uniform brightness, and for near-black
        // regions (no chroma to lift, e.g. an Onyx cluster) fall back to a light
        // neutral so NOTHING ever renders dark — the luminous rainbow of the ref.
        float mx = max(col.r, max(col.g, col.b));
        float3 hue   = col / max(mx, 0.001);                       // unit-value chroma
        float3 vivid = hue * 0.94;                                 // uniform brightness
        float3 base  = mix(float3(0.86), vivid, smoothstep(0.015, 0.07, mx));
        float lum = dot(base, float3(0.299, 0.587, 0.114));
        col = clamp(mix(float3(lum), base, 1.4), 0.0, 1.0);        // saturation boost
        return float4(col, 1.0);                                   // opaque, full-bleed
    }
    """
}
