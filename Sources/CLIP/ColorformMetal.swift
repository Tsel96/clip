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
        v.isPaused = true                 // draw on demand (camera / bulbs changes)
        v.enableSetNeedsDisplay = true
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
        // Redraw on every camera tick (pan/zoom) + whenever the bulbs change.
        cameraStore.$camera
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        state.$colorBulbs
            .sink { [weak self] bulbs in self?.rebuildBulbs(bulbs); self?.refresh() }
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
        // σ ≈ average bulb radius → soft overlap that fills to ~the bulb radius.
        let avgR = bulbs.reduce(0) { $0 + $1.radius } / CGFloat(bulbs.count)
        uniforms.sigma = max(Float(avgR) * 0.85, 120)
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
        float wsum = 0.0, wmax = 0.0;
        float3 csum = float3(0.0);
        for (int i = 0; i < u.bulbCount; i++) {
            float2 d = world - float2(bulbs[i].px, bulbs[i].py);
            float w = exp(-dot(d, d) / (sig * sig));
            if (i == u.hoverIndex) { w *= 1.8; }     // hover-effect hook
            wsum += w; wmax = max(wmax, w);
            csum += w * float3(bulbs[i].r, bulbs[i].g, bulbs[i].b);
        }
        float3 cream = float3(u.creamR, u.creamG, u.creamB);
        float3 field = (wsum > 1e-4) ? (csum / wsum) : cream;
        field += wmax * 0.16;                        // soft seed glow
        field = clamp(field, 0.0, 1.0);
        float a = smoothstep(0.04, 0.5, wsum);       // fade to cream at the edges
        return float4(field * a, a);                 // premultiplied
    }
    """
}
