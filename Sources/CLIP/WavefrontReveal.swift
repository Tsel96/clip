import SwiftUI
import MetalKit
import AppKit
import QuartzCore
import WebKit
import AVFoundation
import AVKit

/*  Wavefront image reveal — ported from DopeDrop's Metal shader.

    A luminous band sweeps across an image and the picture materialises
    behind it. The original ships 19 looks (see `RevealStyle`); style 0,
    AURORA, is the iridescent energy band.

    Usage on the canvas: a freshly dropped image node plays the reveal once
    (see `RevealingImageNode`, wired into `DraggableNode`). The shader is
    compiled from source at runtime — exactly as the original app does — so
    there is no .metal file / metallib bundling to configure in SwiftPM.

    Requires Metal (Apple Silicon / any Metal GPU). Degrades to the plain
    image when Metal is unavailable or Reduce Motion is on.
*/


// MARK: - Styles (raw value == the shader's `style` switch index)

enum RevealStyle: Float {
    case aurora = 0, cleanWipe = 1, dissolve = 2, liquidGlass = 3, heatmap = 4
    case halftone = 5, motionBlur = 6, pixelMosaic = 7, chromaticGlitch = 8
    case ripple = 9, inkBleed = 10, crtPhosphor = 11, crystallize = 12
    case lightSweep = 13, holographic = 14, topographic = 15, plasma = 16
    case venetianSlats = 17, frostThaw = 18
}

// MARK: - Uniforms (field order + layout must match the MSL `Uniforms` struct)

struct RevealUniforms {
    var progress: Float = 0
    var time: Float = 0
    var dir: Float = 1
    var padding: Float = 0
    var bandWidth: Float = 0.16
    var organicAmp: Float = 0.04
    var organicFreq: Float = 7
    var organicSpeed: Float = 1.3
    var elevation: Float = 0.16
    var swellAmount: Float = 1
    var refractStrength: Float = 0.06
    var curl: Float = 0.5
    var highlights: Float = 1
    var brightness: Float = 1.06
    var hueCenter: Float = 0.40   // green→cyan, on the CLIP palette
    var hueSpread: Float = 0.55
    var tintStrength: Float = 0.7
    var bloomStrength: Float = 0.55
    var dimAmount: Float = 0.55
    var blurBase: Float = 0
    var blurPeak: Float = 0.018
    var attack: Float = 0.18
    var release: Float = 0.18
    var overshoot: Float = 0.12
    var style: Float = 0
    var kbZoom: Float = 1
    var kbPanX: Float = 0
    var kbPanY: Float = 0
}

// MARK: - Shared Metal objects (device, queue, pipeline, sampler compiled once)

enum RevealEngine {
    static let device: MTLDevice? = MTLCreateSystemDefaultDevice()
    static let queue: MTLCommandQueue? = device?.makeCommandQueue()

    static let pipeline: MTLRenderPipelineState? = {
        guard let device else { return nil }
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: shaderSource, options: nil)
        } catch {
            return nil
        }
        guard let vfn = library.makeFunction(name: "vmain"),
              let ffn = library.makeFunction(name: "fmain")
        else { return nil }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        guard let ca = desc.colorAttachments[0] else { return nil }
        ca.pixelFormat = .rgba8Unorm   // CPU-readable; offscreen render target matches
        // The shader returns premultiplied alpha ("over" compositing).
        ca.isBlendingEnabled = true
        ca.rgbBlendOperation = .add
        ca.alphaBlendOperation = .add
        ca.sourceRGBBlendFactor = .one
        ca.sourceAlphaBlendFactor = .one
        ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
        ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try? device.makeRenderPipelineState(descriptor: desc)
    }()

    static let sampler: MTLSamplerState? = {
        guard let device else { return nil }
        let d = MTLSamplerDescriptor()
        d.minFilter = .linear
        d.magFilter = .linear
        d.sAddressMode = .clampToEdge
        d.tAddressMode = .clampToEdge
        return device.makeSamplerState(descriptor: d)
    }()

    static func makeTexture(_ cgImage: CGImage) -> MTLTexture? {
        guard let device else { return nil }
        let w = cgImage.width, h = cgImage.height
        guard w > 0, h > 0 else { return nil }
        // Normalise ANY CGImage (NSImage-decoded *or* ImageRenderer output) into
        // a known 8-bit premultiplied-RGBA, top-down bitmap, then upload directly.
        // MTKTextureLoader rejects some ImageRenderer formats; this never does.
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: bitmapInfo),
              let ptr = ctx.data else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))   // row 0 = top → v=0 = top
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                    withBytes: ptr, bytesPerRow: ctx.bytesPerRow)
        return tex
    }

    /// Whether the reveal can actually run right now.
    static var isAvailable: Bool { pipeline != nil && sampler != nil && queue != nil }

    static let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
  float progress, time, dir, padding, bandWidth, organicAmp, organicFreq, organicSpeed,
        elevation, swellAmount, refractStrength, curl, highlights, brightness,
        hueCenter, hueSpread, tintStrength, bloomStrength, dimAmount, blurBase, blurPeak,
        attack, release, overshoot, style, kbZoom, kbPanX, kbPanY;
};

struct VSOut { float4 pos [[position]]; float2 uv; };

constant float2 verts[6] = {
  float2(-1,-1), float2(1,-1), float2(-1,1),
  float2(-1,1),  float2(1,-1), float2(1,1)
};

vertex VSOut vmain(uint vid [[vertex_id]]) {
  float2 p = verts[vid];
  VSOut o;
  o.pos = float4(p, 0, 1);
  // top-down uv, matching the WebGL build
  o.uv = float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
  return o;
}

static float3 hsv2rgb(float3 c) {
  float4 K = float4(1.0, 2.0/3.0, 1.0/3.0, 3.0);
  float3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
  return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}
static float hash21(float2 p) {
  p = fract(p * float2(123.34, 456.21));
  p += dot(p, p + 45.32);
  return fract(p.x * p.y);
}
static float noise2(float2 p) {
  float2 i = floor(p), f = fract(p);
  float a = hash21(i);
  float b = hash21(i + float2(1.0, 0.0));
  float c = hash21(i + float2(0.0, 1.0));
  float d = hash21(i + float2(1.0, 1.0));
  float2 u = f * f * (3.0 - 2.0 * f);
  return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}
static float2 hash22(float2 p) {
  p = float2(dot(p, float2(127.1, 311.7)), dot(p, float2(269.5, 183.3)));
  return fract(sin(p) * 43758.5453);
}
static float fbm(float2 p) {
  float v = 0.0, a = 0.5;
  for (int i = 0; i < 5; i++) { v += a * noise2(p); p *= 2.02; a *= 0.5; }
  return v;
}
// FLIR-style thermal ramp: indigo (cold) -> blue -> magenta -> red -> orange -> white (hot)
static float3 heatRamp(float t) {
  t = clamp(t, 0.0, 1.0);
  float3 c0 = float3(0.02, 0.01, 0.18);
  float3 c1 = float3(0.10, 0.12, 0.85);
  float3 c2 = float3(0.62, 0.05, 0.78);
  float3 c3 = float3(1.00, 0.18, 0.12);
  float3 c4 = float3(1.00, 0.70, 0.05);
  float3 c5 = float3(1.00, 1.00, 0.88);
  float x = t * 5.0;
  int i = int(floor(x));
  float f = smoothstep(0.0, 1.0, fract(x));
  if (i <= 0) return mix(c0, c1, f);
  if (i == 1) return mix(c1, c2, f);
  if (i == 2) return mix(c2, c3, f);
  if (i == 3) return mix(c3, c4, f);
  return mix(c4, c5, f);
}
static float3 blurSample(texture2d<float> tex, sampler s, float2 uv, float radius) {
  if (radius < 0.0008) return tex.sample(s, uv).rgb;
  float3 acc = float3(0.0);
  float wsum = 0.0;
  for (int j = -2; j <= 2; j++) {
    for (int i = -2; i <= 2; i++) {
      float2 o = float2(float(i), float(j)) * radius * 0.5;
      float w = exp(-dot(o, o) / max(radius * radius * 0.5, 1e-5));
      float2 ss = clamp(uv + o, 0.0, 1.0);
      acc += tex.sample(s, ss).rgb * w;
      wsum += w;
    }
  }
  return acc / max(wsum, 1e-4);
}

fragment float4 fmain(VSOut in [[stage_in]],
                      texture2d<float> tex [[texture(0)]],
                      sampler samp [[sampler(0)]],
                      constant Uniforms& u [[buffer(0)]]) {
  // Work in a transposed space so the band sweeps along the screen's Y axis
  // (top -> bottom). The texture is sampled back in normal orientation, so
  // the image stays upright; only the sweep direction rotates 90 degrees.
  float2 uv = float2(in.uv.y, in.uv.x);

  float pad = u.bandWidth * 1.5;
  // overshoot extends the EXIT side only, so the wavefront travels well past
  // the trailing edge and the trail fully cools to the clean image by p=1.
  float startX = u.dir > 0.0 ? -pad : 1.0 + pad + u.overshoot;
  float endX   = u.dir > 0.0 ? 1.0 + pad + u.overshoot : -pad - u.overshoot;
  float bandX = mix(startX, endX, u.progress);
  float dx = uv.x - bandX;

  float phase = uv.y * u.organicFreq + u.time * u.organicSpeed;
  float wobble = sin(phase) * 0.55
               + sin(phase * 1.93 + 1.1) * 0.30
               + (noise2(float2(uv.y * 6.0, u.time * 0.6)) - 0.5) * 0.80;
  wobble *= u.organicAmp;
  float dx_eff = dx - wobble;

  float e1 = dx_eff / max(u.bandWidth, 0.01);
  float energy = exp(-e1 * e1);

  float topPadNoise = (noise2(float2(uv.x * 5.0,  u.time * 0.4)) - 0.5) * 0.012;
  float botPadNoise = (noise2(float2(uv.x * 5.0, -u.time * 0.4 + 13.7)) - 0.5) * 0.012;
  float topEdge = u.padding + topPadNoise;
  float botEdge = (1.0 - u.padding) + botPadNoise;
  float maskY = smoothstep(topEdge, topEdge + 0.025, uv.y)
              * (1.0 - smoothstep(botEdge - 0.025, botEdge, uv.y));
  energy *= maskY;

  float r = max(u.bandWidth, 0.01);
  float e2 = dx / r;
  float bulge = exp(-e2 * e2) * maskY;
  float dz_dx = u.elevation * bulge * (-2.0 * dx / (r * r));
  float3 N = normalize(float3(-dz_dx, 0.0, 1.0));

  float magnify = 1.0 + bulge * 0.35 * u.swellAmount;
  float magX = bandX + (uv.x - bandX) / magnify;
  float2 anchor = float2(bandX, 0.5);
  float2 toAnchor = anchor - float2(magX, uv.y);
  float2 curled = float2(magX, uv.y) + toAnchor * bulge * u.curl * 0.35;
  float2 sampleUV = clamp(float2(curled.x + N.x * u.refractStrength * bulge, curled.y),
                          float2(0.0), float2(1.0));

  float attackEnv  = smoothstep(0.0, max(u.attack, 0.001), u.progress);
  float releaseEnv = 1.0 - smoothstep(1.0 - max(u.release, 0.001), 1.0, u.progress);
  float envelope = attackEnv * releaseEnv;

  float bt = clamp(u.progress / max(u.attack, 0.001), 0.0, 1.0);
  float blurAttackEnv = bt * bt * bt * (bt * (bt * 6.0 - 15.0) + 10.0);
  float blurEnvelope = blurAttackEnv * releaseEnv;
  float blurAmt = mix(u.blurBase, u.blurPeak, energy) * blurEnvelope;

  // Transpose the sample coordinate back to image space (keeps image upright).
  float2 kbPan = float2(u.kbPanX, u.kbPanY);
  float2 texUV = clamp((float2(sampleUV.y, sampleUV.x) - 0.5) / u.kbZoom + 0.5 + kbPan, 0.0, 1.0);   // Ken-Burns zoom/pan (identity by default)
  float3 toRGB = blurSample(tex, samp, texUV, blurAmt);
  float toA = tex.sample(samp, texUV).a;

  float wipeCross = u.bandWidth * 0.4;
  float wipeT = smoothstep(-wipeCross, wipeCross, dx_eff);
  float pageMix = u.dir > 0.0 ? (1.0 - wipeT) : wipeT;
  float3 page = toRGB * pageMix;
  float pageA = toA * pageMix;

  // Shared reveal helpers for the post-aurora styles. These styles reveal EXACTLY
  // like 0–3: `revealA` gates alpha so everything AHEAD of the wavefront is fully
  // transparent (the image doesn't exist yet — the wave paints it in). The effect
  // is a TRAIL that rides just behind the front and resolves to the clean photo,
  // so it ends on the real preview. `behindDist` = how far a revealed pixel sits
  // behind the front; `iuv` is the upright (untransposed) image uv.
  float sd = dx_eff * u.dir;            // < 0 on the already-revealed side
  float behindDist = max(0.0, -sd);     // distance behind the wavefront
  float revealA = pageMix * toA;        // master visibility — transparent ahead
  float2 iuv = clamp((in.uv - 0.5) / u.kbZoom + 0.5 + kbPan, 0.0, 1.0);   // Ken-Burns zoom/pan

  // Shared surface lighting (used by every style).
  float3 surfPos = float3((uv.x - 0.5) * 2.0, (0.5 - uv.y) * 2.0, u.elevation * bulge);
  float3 L = normalize(float3(-0.5, 0.7, 1.6) - surfPos);
  float3 V = normalize(-surfPos);
  float3 H = normalize(L + V);
  float NdotV = clamp(dot(N, V), 0.0, 1.0);
  float fresnel = pow(1.0 - NdotV, 3.0) * bulge;
  float spec = pow(clamp(dot(N, H), 0.0, 1.0), 96.0) * bulge;

  float3 col;
  float alpha;

  if (u.style < 0.5) {
    // ── 0 · AURORA — the original iridescent energy band. ──────────────
    float luma = dot(page, float3(0.299, 0.587, 0.114));
    float3 dimmed = mix(page, float3(luma) * 0.45, energy * u.dimAmount);
    dimmed *= mix(1.0, 1.0 - u.dimAmount * 0.4, energy);
    float hueDrift = (noise2(float2(uv.y * 1.4, u.time * 0.22)) - 0.5) * 0.05;
    float hue = u.hueCenter + (uv.y - 0.5) * u.hueSpread * 0.55 + hueDrift;
    float sat = 0.80 + sin(uv.y * 2.6 + u.time * 0.4) * 0.05;
    float val = 0.97 + sin(uv.y * 4.1 - u.time * 0.3) * 0.03;
    float3 iri = hsv2rgb(float3(fract(hue), sat, val)) * u.brightness;
    float3 tinted = mix(dimmed, dimmed * iri * 1.25, energy * u.tintStrength);
    float3 bloom = iri * energy * u.bloomStrength;
    float3 highlights = (iri * fresnel * 0.55 + float3(spec) * 1.6) * u.highlights;
    col = tinted + (bloom + highlights) * envelope;
    alpha = clamp(pageA + energy * envelope * 0.9, 0.0, 1.0);

  } else if (u.style < 1.5) {
    // ── 1 · CLEAN WIPE — a crisp light edge sweeps across, leaving the photo. ──
    //   Two-tier crest: a razor AA hairline core (fwidth-locked, so it stays
    //   sharp at any sweep speed) rides a soft bloom halo. A brief brightness
    //   "pop" lifts freshly-revealed pixels so it reads as light passing OVER the
    //   image rather than a flat line drawn on top.
    float lineW = max(fwidth(dx_eff) * 1.5, u.bandWidth * 0.04);
    float core  = (1.0 - smoothstep(0.0, lineW, abs(dx_eff))) * maskY;
    float halo  = pow(energy, 2.2);
    float pop   = (1.0 - smoothstep(0.0, u.bandWidth * 0.8, behindDist)) * pageMix;
    float3 lit  = page * (1.0 + pop * 0.22);
    float3 cool = float3(0.6, 0.78, 1.0);
    col = lit + (cool * halo * 0.45 + float3(1.0) * core * 0.9
              + float3(spec) * 0.8) * envelope;
    alpha = clamp(pageA + (halo * 0.45 + core) * envelope * 0.7, 0.0, 1.0);

  } else if (u.style < 2.5) {
    // ── 2 · DISSOLVE — the photo materialises through a ragged, multi-scale ──
    //   front. fbm warps the erosion threshold (organic edge, not regular
    //   noise); soft ROUND sparks with a fade-in/out lifetime scatter at the
    //   rim, and the rim itself carries a faint energising glow.
    float grain = (fbm(uv * 9.0 + float2(u.time * 0.25, 0.0)) - 0.5)
                + (noise2(uv * 30.0) - 0.5) * 0.35;
    float wt = smoothstep(-wipeCross * 2.4, wipeCross * 2.4, dx_eff + grain * u.bandWidth * 1.8);
    float pm = u.dir > 0.0 ? (1.0 - wt) : wt;
    float near = pow(max(0.0, 1.0 - abs(dx_eff) / max(u.bandWidth, 0.01)), 2.2);
    // round soft sparkles: jitter a point inside each cell, gaussian falloff, twinkle.
    float2 sg  = uv * 90.0;
    float2 sid = floor(sg);
    float2 spt = hash22(sid);
    float life = 0.5 + 0.5 * sin(u.time * 7.0 + hash21(sid) * 6.2831);
    float sd2  = length(fract(sg) - spt);
    float spark = exp(-sd2 * sd2 * 50.0) * step(0.55, hash21(sid + 3.1))
                * near * life * life;
    float3 sparkCol = mix(float3(1.0, 0.95, 0.85), float3(0.8, 0.9, 1.0), hash21(sid));
    col = toRGB * pm + sparkCol * spark * envelope * 1.1
        + float3(0.55, 0.7, 1.0) * near * pm * envelope * 0.12;
    alpha = clamp(toA * pm + spark * envelope, 0.0, 1.0);

  } else if (u.style < 3.5) {
    // ── 3 · LIQUID GLASS — a clear lens sweeps THROUGH the image. Chromatic ──
    //   dispersion splits R/B along the refraction normal (prismatic edge — the
    //   single biggest "this is real glass" tell), a caustic band focuses light
    //   just behind the lens, and the leading edge darkens slightly so the lens
    //   body reads with genuine volume against the bright crest.
    float disp = N.x * u.refractStrength * bulge * 1.4;
    float rC = tex.sample(samp, clamp(float2(texUV.x, texUV.y + disp), 0.0, 1.0)).r;
    float bC = tex.sample(samp, clamp(float2(texUV.x, texUV.y - disp), 0.0, 1.0)).b;
    float3 glass = float3(rC, toRGB.g, bC) * pageMix;
    float caustic = pow(max(0.0, 1.0 - abs(dx_eff + u.bandWidth * 0.35 * u.dir)
                                  / max(u.bandWidth, 0.01)), 3.0);
    float edgeShadow = pow(energy, 1.2) * 0.10 * envelope;
    float crest = energy * envelope;
    col = glass * (1.0 - edgeShadow)
        + (float3(spec) * 2.2 + float3(0.8, 0.9, 1.0) * fresnel * 0.6) * envelope
        + float3(0.85, 0.92, 1.0) * caustic * envelope * 0.35
        + float3(0.7, 0.85, 1.0) * crest * 0.10;
    alpha = clamp(pageA + crest * 0.5, 0.0, 1.0);

  } else if (u.style < 4.5) {
    // ── 4 · HEATMAP — the image materialises THROUGH a thermal front and
    //        cools into the true photo behind it (FLIR seam). Hidden ahead.
    float trail = 1.0 - smoothstep(0.0, 0.55, behindDist);
    float luma = dot(toRGB, float3(0.299, 0.587, 0.114));
    float3 thermal = heatRamp(pow(luma, 0.85));
    float crest = pow(energy, 1.4) * envelope;
    col = mix(toRGB, thermal, trail) + float3(1.0, 0.92, 0.78) * crest * 0.40;
    alpha = clamp(revealA + crest * 0.40, 0.0, 1.0);

  } else if (u.style < 5.5) {
    // ── 5 · HALFTONE — a rotated print screen: colour dots arrive at the front
    //   and GROW + merge into the full photo behind it. The grid is rotated to a
    //   classic ~22° screen angle (so it reads as ink dots, never a pixel grid),
    //   and the inter-dot field is light paper, not black tiles.
    float trail = 1.0 - smoothstep(0.0, 0.42, behindDist);
    float cells = 84.0;
    float ca = 0.924, sa = 0.383;                 // cos/sin(22.5°)
    float2 ruv = float2(iuv.x * ca - iuv.y * sa, iuv.x * sa + iuv.y * ca);
    float2 gv = ruv * cells;
    float2 cell = floor(gv) + 0.5;
    // rotate the cell centre back into image space to fetch its colour.
    float2 cuv = float2(cell.x * ca + cell.y * sa, -cell.x * sa + cell.y * ca) / cells;
    float3 cc = tex.sample(samp, clamp(cuv, 0.0, 1.0)).rgb;
    float ink = clamp(dot(cc, float3(0.299, 0.587, 0.114)), 0.0, 1.0);
    float2 off = fract(gv) - 0.5;
    float d = length(off);
    // dots grow from ink-sized toward fully merged (≈0.95 fills the cell) as the trail passes.
    float dr = mix(sqrt(ink) * 0.72, 0.95, trail * 0.6);
    float aa = max(fwidth(d), 0.0015);
    float cov = smoothstep(dr, dr - aa, d);
    float3 paper = mix(float3(0.92, 0.93, 0.96), toRGB, 0.35);
    float3 ht = mix(paper, cc * 1.1, cov);
    float crest = pow(energy, 1.5) * envelope;
    col = mix(toRGB, ht, trail) + float3(0.55, 0.7, 1.0) * crest * 0.22;
    alpha = clamp(revealA + crest * 0.25, 0.0, 1.0);

  } else if (u.style < 6.5) {
    // ── 6 · MOTION BLUR — the photo rushes in along the sweep axis and sharpens
    //   as it settles. A longer, weighted tap-tail keeps the streak smooth (no
    //   banding), the blur eases in (trail²) so it SNAPS to crisp, and a bright
    //   light-streak stretches the highlights along the motion axis for energy.
    float trail = 1.0 - smoothstep(0.0, 0.34, behindDist);
    float amt = trail * trail * 0.11;
    float3 acc = float3(0.0); float wsum = 0.0;
    for (int i = 0; i < 13; i++) {
      float t = float(i) / 12.0;
      float2 o = float2(0.0, t * amt * u.dir);
      float w = 1.0 - t * 0.7;
      acc += tex.sample(samp, clamp(iuv - o, 0.0, 1.0)).rgb * w;
      wsum += w;
    }
    float3 smeared = acc / max(wsum, 1e-3);
    float br = max(0.0, dot(smeared, float3(0.299, 0.587, 0.114)) - 0.55);
    float crest = pow(energy, 1.5) * envelope;
    col = mix(toRGB, smeared, trail)
        + float3(0.7, 0.82, 1.0) * (crest * 0.30 + br * trail * 0.5)
        + float3(spec) * 0.5 * envelope;
    alpha = clamp(revealA + crest * 0.35, 0.0, 1.0);

  } else if (u.style < 7.5) {
    // ── 7 · PIXEL MOSAIC — coarse blocks at the front snap down to full
    //        res behind it; tile gaps glow at the wave. Hidden ahead.
    float trail = 1.0 - smoothstep(0.0, 0.40, behindDist);
    float blocks = max(mix(150.0, 12.0, trail), 4.0);
    float2 quv = (floor(iuv * blocks) + 0.5) / blocks;
    float3 px = tex.sample(samp, clamp(quv, 0.0, 1.0)).rgb;
    float2 g = fract(iuv * blocks);
    float gap = min(min(g.x, g.y), min(1.0 - g.x, 1.0 - g.y));
    float grid = (1.0 - smoothstep(0.0, 0.06, gap)) * energy * envelope;
    float crest = pow(energy, 1.4) * envelope;
    col = mix(toRGB, px, trail)
        + float3(0.4, 0.6, 1.0) * grid * 0.4 + float3(0.8, 0.9, 1.0) * crest * 0.2;
    alpha = clamp(revealA + crest * 0.25, 0.0, 1.0);

  } else if (u.style < 8.5) {
    // ── 8 · CHROMATIC GLITCH — RGB channel split + scanline jitter at the
    //        front, converging to a clean frame behind it. Hidden ahead.
    float trail = 1.0 - smoothstep(0.0, 0.32, behindDist);
    float sep = trail * 0.02;
    float jitter = (noise2(float2(iuv.y * 90.0, u.time * 3.5)) - 0.5) * trail * 0.03;
    float2 j = float2(jitter, 0.0);
    float rC = tex.sample(samp, clamp(iuv + float2(sep, 0.0) + j, 0.0, 1.0)).r;
    float gC = tex.sample(samp, clamp(iuv + j, 0.0, 1.0)).g;
    float bC = tex.sample(samp, clamp(iuv - float2(sep, 0.0) + j, 0.0, 1.0)).b;
    float scan = 1.0 - trail * 0.18 * step(0.5, fract(iuv.y * 180.0));
    float3 eff = float3(rC, gC, bC) * scan;
    float3 fringe = float3(0.0, 1.0, 1.0) * step(0.0, dx_eff)
                  + float3(1.0, 0.1, 0.5) * step(dx_eff, 0.0);
    col = mix(toRGB, eff, trail) + fringe * energy * envelope * 0.3;
    alpha = clamp(revealA + energy * envelope * 0.25, 0.0, 1.0);

  } else if (u.style < 9.5) {
    // ── 9 · RIPPLE — concentric water ripples trail the front, refracting the
    //        image; caustic glints ride the crests, then settle to the photo.
    float trail = 1.0 - smoothstep(0.0, 0.6, behindDist);
    float wavePhase = behindDist * 90.0 - u.time * 6.0;
    float ripple = sin(wavePhase) * trail * 0.012;
    float3 water = tex.sample(samp, clamp(iuv + float2(ripple * 0.5, ripple), 0.0, 1.0)).rgb;
    float caustic = pow(max(0.0, sin(wavePhase)), 8.0) * trail;
    float crest = pow(energy, 1.4) * envelope;
    col = mix(toRGB, water, trail)
        + float3(0.6, 0.85, 1.0) * caustic * 0.25 + float3(spec) * 0.6 * envelope;
    alpha = clamp(revealA + crest * 0.3, 0.0, 1.0);

  } else if (u.style < 10.5) {
    // ── 10 · INK BLEED — the photo seeps in through a ragged, noise-warped
    //         front like watercolour on paper, pigment pooling at the wet rim.
    float grain = fbm(uv * 7.0) - 0.5;
    float wt = smoothstep(-wipeCross * 2.5, wipeCross * 2.5, dx_eff + grain * u.bandWidth * 2.2);
    float pm = u.dir > 0.0 ? (1.0 - wt) : wt;
    float trail = 1.0 - smoothstep(0.0, 0.5, behindDist);
    float2 warp = (float2(fbm(iuv * 9.0), fbm(iuv * 9.0 + 7.3)) - 0.5) * trail * 0.018;
    float3 ink = tex.sample(samp, clamp(iuv + warp, 0.0, 1.0)).rgb;
    float lum = dot(ink, float3(0.299, 0.587, 0.114));
    ink = mix(ink, mix(ink, float3(lum), 0.35), trail * 0.5);
    float rim = pow(max(0.0, 1.0 - abs(dx_eff) / max(u.bandWidth, 0.01)), 2.0);
    col = mix(toRGB, ink, trail) - float3(0.06, 0.05, 0.04) * rim * envelope;
    alpha = clamp(toA * pm, 0.0, 1.0);

  } else if (u.style < 11.5) {
    // ── 11 · CRT PHOSPHOR — a bright beam paints the image through an RGB
    //   phosphor stripe mask + soft scanlines, with a hot power-on flash at the
    //   front and a gentle tube vignette. Mask/scan frequencies adapt to pixel
    //   size (fwidth-derived) so they never moiré at small chip sizes.
    float trail = 1.0 - smoothstep(0.0, 0.45, behindDist);
    float stripeFreq = clamp(1.0 / max(fwidth(iuv.x) * 7.0, 1e-4), 60.0, 300.0);
    float scanFreq   = clamp(1.0 / max(fwidth(iuv.y) * 4.0, 1e-4), 70.0, 220.0);
    float stripe = fract(iuv.x * stripeFreq);
    float3 mask = float3(smoothstep(0.66, 0.5, abs(stripe - 0.17)),
                         smoothstep(0.66, 0.5, abs(stripe - 0.50)),
                         smoothstep(0.66, 0.5, abs(stripe - 0.83)));
    mask = mix(float3(1.0), mask * 1.6, trail);
    float scan = 1.0 - 0.22 * trail * (0.5 + 0.5 * sin(iuv.y * scanFreq * 6.2831));
    float3 crt = toRGB * mask * scan;
    float beam  = pow(energy, 2.0) * envelope;
    float flash = pow(energy, 6.0) * envelope;       // hot power-on snap
    float2 vc = iuv - 0.5;
    float vig = 1.0 - dot(vc, vc) * 0.6 * trail;      // tube curvature falloff
    col = mix(toRGB, crt, trail) * vig
        + float3(0.7, 1.0, 0.9) * beam * 0.35
        + float3(1.0) * flash * 0.6;
    alpha = clamp(revealA + (beam + flash) * 0.4, 0.0, 1.0);

  } else if (u.style < 12.5) {
    // ── 12 · CRYSTALLIZE — the image forms as Voronoi facets (large at the
    //         front, refining behind), glowing along the cell seams.
    float trail = 1.0 - smoothstep(0.0, 0.5, behindDist);
    float cells = mix(120.0, 26.0, trail);
    float2 g = iuv * cells;
    float2 ip = floor(g), fp = fract(g);
    float md = 8.0; float2 mc = float2(0.0);
    for (int y = -1; y <= 1; y++) {
      for (int x = -1; x <= 1; x++) {
        float2 o = float2(float(x), float(y));
        float2 r = o + hash22(ip + o) - fp;
        float d = dot(r, r);
        if (d < md) { md = d; mc = ip + o + hash22(ip + o); }
      }
    }
    float3 cellCol = tex.sample(samp, clamp(mc / cells, 0.0, 1.0)).rgb;
    float edge = smoothstep(0.0, 0.05, sqrt(md));
    float3 crys = mix(float3(0.8, 0.9, 1.0), cellCol, edge);
    float crest = pow(energy, 1.4) * envelope;
    col = mix(toRGB, crys, trail)
        + float3(0.5, 0.7, 1.0) * (1.0 - edge) * trail * 0.3 + float3(spec) * 0.5 * envelope;
    alpha = clamp(revealA + crest * 0.3, 0.0, 1.0);

  } else if (u.style < 13.5) {
    // ── 13 · LIGHT SWEEP — a bright anamorphic flare with horizontal streaks
    //         rides the wavefront over the revealed photo (lens-flare bloom).
    float crest = pow(energy, 2.0) * envelope;
    float3 streak = float3(0.0); float ws = 0.0;
    for (int i = -6; i <= 6; i++) {
      float2 o = float2(float(i) * 0.012, 0.0);
      float3 s = tex.sample(samp, clamp(iuv + o, 0.0, 1.0)).rgb;
      float br = max(0.0, dot(s, float3(0.299, 0.587, 0.114)) - 0.6);
      float w = 1.0 - abs(float(i)) / 7.0;
      streak += s * br * w; ws += w;
    }
    streak /= max(ws, 1e-3);
    float3 flare = float3(0.6, 0.8, 1.0) + streak * 3.0;
    col = toRGB + flare * crest * 0.7 + float3(1.0) * crest * 0.3;
    alpha = clamp(revealA + crest * 0.5, 0.0, 1.0);

  } else if (u.style < 14.5) {
    // ── 14 · HOLOGRAPHIC — thin-film iridescence (driven by view angle,
    //         surface normal + position) sheens over the image as it lands.
    float trail = 1.0 - smoothstep(0.0, 0.5, behindDist);
    float band = fresnel * 2.0 + N.x * 3.0 + behindDist * 6.0 + iuv.x * 2.0;
    float3 holo = 0.5 + 0.5 * cos(6.2831 * (band + float3(0.0, 0.33, 0.67)));
    float3 sheen = mix(toRGB, toRGB * 0.6 + holo * 0.7, trail * 0.6);
    float crest = pow(energy, 1.4) * envelope;
    col = mix(toRGB, sheen, trail) + holo * crest * 0.4 + float3(spec) * 0.8 * envelope;
    alpha = clamp(revealA + crest * 0.35, 0.0, 1.0);

  } else if (u.style < 15.5) {
    // ── 15 · TOPOGRAPHIC — the image first reads as glowing luminance contour
    //         lines over a dark map, then fills to the full photo behind.
    float trail = 1.0 - smoothstep(0.0, 0.5, behindDist);
    float luma = dot(toRGB, float3(0.299, 0.587, 0.114));
    float lv = luma * 14.0;
    float fline = abs(fract(lv) - 0.5);
    float aa = max(fwidth(lv), 0.001);
    float contour = 1.0 - smoothstep(0.0, aa * 1.5, fline);
    float3 base = mix(float3(0.02, 0.04, 0.06), toRGB, 0.2);
    float3 topo = base + float3(0.3, 0.9, 0.6) * contour;
    float crest = pow(energy, 1.5) * envelope;
    col = mix(toRGB, topo, trail) + float3(0.3, 0.9, 0.6) * contour * trail * 0.4;
    alpha = clamp(revealA + crest * 0.3, 0.0, 1.0);

  } else if (u.style < 16.5) {
    // ── 16 · PLASMA — a turbulent electric field (multi-octave noise) burns
    //         the image in and cools into the photo behind the front.
    float trail = 1.0 - smoothstep(0.0, 0.55, behindDist);
    float pl = fbm(iuv * 6.0 + float2(u.time * 0.6, u.time * 0.4))
             + 0.5 * fbm(iuv * 12.0 - u.time * 0.3);
    float3 plasma = float3(0.4 + 0.6 * sin(pl * 6.0),
                           0.2 + 0.5 * sin(pl * 6.0 + 2.0),
                           0.8 + 0.4 * sin(pl * 6.0 + 4.0));
    float hot = pow(energy, 1.3) * envelope;
    col = mix(toRGB, plasma, trail * 0.85) + plasma * hot * 0.5;
    alpha = clamp(revealA + hot * 0.4, 0.0, 1.0);

  } else if (u.style < 17.5) {
    // ── 17 · VENETIAN SLATS — louvered strips open in sequence as the wave
    //         passes, each slat tilting to reveal the photo, seams aglow.
    float trail = 1.0 - smoothstep(0.0, 0.45, behindDist);
    float slats = 22.0;
    float strip = fract(iuv.y * slats);
    float openAmt = smoothstep(0.0, 0.35, behindDist);
    float louver = smoothstep(openAmt, openAmt + 0.5, strip);
    float3 slatCol = mix(float3(0.05, 0.06, 0.08), toRGB, louver);
    float edgeGlow = (1.0 - smoothstep(0.0, 0.08, abs(strip - openAmt))) * energy * envelope;
    col = mix(toRGB, slatCol, trail) + float3(0.6, 0.8, 1.0) * edgeGlow * 0.3;
    alpha = clamp(revealA + energy * envelope * 0.2, 0.0, 1.0);

  } else {
    // ── 18 · FROST THAW — a frosty crystalline blur thaws to a clear photo;
    //         facets sparkle in the cold front, then melt away.
    float trail = 1.0 - smoothstep(0.0, 0.55, behindDist);
    float n = noise2(iuv * 40.0);
    float radius = trail * 0.02 * (0.6 + 0.8 * n);
    float3 frosted = blurSample(tex, samp, iuv, radius);
    float facet = step(0.92, hash21(floor(iuv * 120.0))) * trail;
    float3 ice = frosted * mix(float3(1.0), float3(0.85, 0.93, 1.0), trail)
               + float3(0.9, 0.95, 1.0) * facet * 0.5;
    float crest = pow(energy, 1.5) * envelope;
    col = mix(toRGB, ice, trail)
        + float3(0.7, 0.85, 1.0) * crest * 0.25 + float3(spec) * 0.5 * envelope;
    alpha = clamp(revealA + crest * 0.3, 0.0, 1.0);
  }

  // Confine every reveal effect to the object's own silhouette: gate the final
  // alpha by the texture's coverage at THIS output pixel (in.uv, unrefracted),
  // not the refracted sample — refraction near the edge can pull alpha from
  // inside the shape and leave faint strokes just outside it (very visible on a
  // white background). Sampling the true coverage clips bands, glows, sparkles
  // and crests exactly to the silhouette. Full-bleed photos (coverage == 1
  // everywhere) are unaffected.
  float coverageA = tex.sample(samp, iuv).a;
  alpha *= smoothstep(0.0, 0.08, coverageA);

  // premultiplied alpha for CALayer compositing over the transparent window
  return float4(col * alpha, alpha);
}
"""
}

private func easeInOutCubic(_ t: Double) -> Double {
    t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
}

// MARK: - Offscreen renderer

/// Renders the reveal shader into an offscreen texture and reads it back as a
/// CGImage. Offscreen (rather than an MTKView) so the result composes with the
/// canvas's SwiftUI transforms — AppKit views don't render under `.scaleEffect`.
final class RevealRenderer {
    private let texture: MTLTexture?
    private var target: MTLTexture?
    private var buffer: [UInt8] = []
    private let style: RevealStyle
    private var width = 0
    private var height = 0

    init(cgImage: CGImage, style: RevealStyle) {
        self.style = style
        self.texture = RevealEngine.makeTexture(cgImage)
    }

    func ensureTarget(width: Int, height: Int) {
        guard width > 0, height > 0, let device = RevealEngine.device else { return }
        if target != nil, self.width == width, self.height == height { return }
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        target = device.makeTexture(descriptor: d)
        self.width = width
        self.height = height
        buffer = [UInt8](repeating: 0, count: width * height * 4)
    }

    /// Render one frame at `progress`; returns a premultiplied-RGBA CGImage.
    func render(progress: Float, time: Float) -> CGImage? {
        guard let pipeline = RevealEngine.pipeline,
              let sampler = RevealEngine.sampler,
              let queue = RevealEngine.queue,
              let texture, let target, width > 0, height > 0 else { return nil }

        var u = RevealUniforms()
        u.style = style.rawValue
        u.progress = progress
        u.time = time

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = target
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        rpd.colorAttachments[0].storeAction = .store

        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return nil }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(texture, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.setFragmentBytes(&u, length: MemoryLayout<RevealUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()

        let bytesPerRow = width * 4
        buffer.withUnsafeMutableBytes { raw in
            target.getBytes(raw.baseAddress!, bytesPerRow: bytesPerRow,
                            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        guard let provider = CGDataProvider(data: Data(buffer) as CFData) else { return nil }
        let bitmap = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmap,
                       provider: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }
}

// MARK: - Frame driver

/// Steps progress 0→1 over `duration`, rendering each frame off the main thread
/// and publishing the resulting CGImage for SwiftUI to display.
@MainActor
final class RevealAnimator: ObservableObject {
    @Published var frame: CGImage?
    private var running = false

    func start(renderer: RevealRenderer, pixelWidth: Int, pixelHeight: Int,
               duration: CFTimeInterval, onComplete: @escaping () -> Void) {
        guard !running else { return }
        running = true
        renderer.ensureTarget(width: pixelWidth, height: pixelHeight)
        Task {
            let t0 = CACurrentMediaTime()
            var produced = false
            while true {
                let t = CACurrentMediaTime() - t0
                let p = min(t / duration, 1)
                let img = await Task.detached {
                    renderer.render(progress: Float(easeInOutCubic(p)), time: Float(t))
                }.value
                if let img {
                    frame = img
                    produced = true
                } else if !produced {
                    break   // first render failed → bail, fall back to the plain image
                }
                if p >= 1 { break }
                try? await Task.sleep(nanoseconds: 16_000_000)   // ~60 fps
            }
            // Reset BEFORE completing so `onComplete` (or a later state change)
            // can re-trigger a reveal — `running` was never cleared, which
            // blocked re-triggers. (`frame` is deliberately NOT nilled: the
            // view may still composite it this frame; one retained bitmap per
            // animator is cheaper than a completion blink.)
            running = false
            onComplete()
        }
    }
}

// MARK: - SwiftUI view (a plain Image, so it composes with canvas transforms)

struct WavefrontRevealImageView: View {
    let renderer: RevealRenderer
    var duration: CFTimeInterval = 1.5
    var onComplete: () -> Void = {}

    @StateObject private var anim = RevealAnimator()

    var body: some View {
        GeometryReader { geo in
            Group {
                if let frame = anim.frame {
                    Image(decorative: frame, scale: 1).resizable()
                } else {
                    Color.clear
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .onAppear {
                let dpr = min(NSScreen.main?.backingScaleFactor ?? 2, 2)
                let cap: CGFloat = 900   // keep GPU→CPU readback cheap
                var w = geo.size.width * dpr
                var h = geo.size.height * dpr
                let s = min(1, cap / max(w, h, 1))
                w *= s; h *= s
                anim.start(renderer: renderer,
                           pixelWidth: max(1, Int(w)), pixelHeight: max(1, Int(h)),
                           duration: duration, onComplete: onComplete)
            }
        }
    }
}

// MARK: - Canvas integration: reveal a freshly dropped image node, once

struct RevealingImageNode: View {
    let data: Data
    let filename: String
    let isLive: Bool
    /// True while this node id is in `CanvasState.pendingRevealNodeIDs`.
    let shouldReveal: Bool
    /// Clears the pending id so the reveal never re-fires for this node.
    let onConsumed: () -> Void

    var style: RevealStyle = .aurora
    var duration: CFTimeInterval = 1.5

    @State private var phase: Phase = .idle
    @State private var renderer: RevealRenderer? = nil

    // idle → preparing (decoding, image still shown) → revealing (image hidden,
    // the wave paints it in from nothing) → done (settled image).
    private enum Phase { case idle, preparing, revealing, done }

    var body: some View {
        ZStack {
            ImageNodeView(data: data, filename: filename, isLive: isLive)
                .opacity(phase == .revealing ? 0 : 1)

            if phase == .revealing, let renderer {
                WavefrontRevealImageView(renderer: renderer, duration: duration) {
                    withAnimation(Motion.fade) { phase = .done }
                }
                .allowsHitTesting(false)
            }
        }
        .task(id: shouldReveal) { await maybeStart() }
    }

    @MainActor
    private func maybeStart() async {
        guard phase == .idle, shouldReveal else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard isLive, !reduceMotion, RevealEngine.isAvailable else {
            onConsumed()                 // can't (or shouldn't) reveal — just consume the flag
            return
        }
        onConsumed()                     // consume up front so it can't double-fire
        phase = .preparing               // keep showing the real image while we decode
        let bytes = data
        let cg = await Task.detached(priority: .userInitiated) {
            NSImage(data: bytes)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }.value
        guard phase == .preparing else { return }
        if let cg {
            renderer = RevealRenderer(cgImage: cg, style: style)
            phase = .revealing
        } else {
            phase = .done
        }
    }
}

// MARK: - Reveal for rich cards (tweet / youtube / instagram / webclip)

/// Capture the *actual on-screen* pixels of a card — its loaded poster/text, not
/// a fresh re-rendered copy — by asking the host window's content view to draw
/// the card's region into a bitmap. `ImageRenderer` can't do this: it re-renders
/// a fresh, unloaded copy (blank for async / web content).
/// Render a card off-screen (invisible) so its async content — poster images,
/// web posters — loads WITHOUT the user seeing it, then capture it. This lets
/// the card materialise *through* the wave (like an image) instead of appearing
/// first and then getting an effect.
@MainActor
func renderOffscreen<V: View>(_ view: V, width: CGFloat, fixedHeight: CGFloat?,
                              settleNanos: UInt64) async -> CGImage? {
    guard width >= 1 else { return nil }
    // Auto-height cards (tweets) get only a width so they size to their media
    // aspect; fixed-height cards (IG / YT / webclip) get both.
    let framed: AnyView = fixedHeight != nil
        ? AnyView(view.frame(width: width, height: fixedHeight!))
        : AnyView(view.frame(width: width))
    let host = NSHostingView(rootView: framed)
    host.frame = CGRect(x: 0, y: 0, width: width, height: fixedHeight ?? 4000)
    let win = NSWindow(contentRect: host.frame, styleMask: .borderless,
                       backing: .buffered, defer: false)
    win.isReleasedWhenClosed = false
    win.alphaValue = 0                                   // invisible
    win.ignoresMouseEvents = true
    win.setFrameOrigin(NSPoint(x: -30000, y: -30000))   // and off-screen
    win.contentView = host
    win.orderFrontRegardless()                           // rendered → async content loads
    // Tear the window down fully on exit: `orderOut` alone (with
    // `isReleasedWhenClosed = false`) left the NSWindow + its hosting view
    // alive after every reveal — one leaked window per animated card.
    defer { win.orderOut(nil); win.contentView = nil; win.close() }
    try? await Task.sleep(nanoseconds: settleNanos)
    host.layoutSubtreeIfNeeded()
    var h = fixedHeight ?? host.fittingSize.height       // media-aspect height for tweets
    if !(h >= 1) || h > 8000 { h = width }               // sane fallback
    let size = CGSize(width: width, height: h)
    win.setContentSize(size)
    host.frame = CGRect(origin: .zero, size: size)
    host.layoutSubtreeIfNeeded()
    // WKWebView (tweet / instagram / youtube / webclip) does NOT paint into
    // cacheDisplay while off-screen → a black capture. `takeSnapshot` forces a
    // render of the loaded DOM regardless of visibility, so we snapshot the web
    // view directly when the card hosts one. cacheDisplay stays the fallback.
    if let web = findWebView(in: host), web.bounds.width > 1, web.bounds.height > 1 {
        let cfg = WKSnapshotConfiguration()
        cfg.rect = web.bounds
        let snap: NSImage? = await withCheckedContinuation { cont in
            web.takeSnapshot(with: cfg) { image, _ in cont.resume(returning: image) }
        }
        if let cg = snap?.cgImage(forProposedRect: nil, context: nil, hints: nil),
           cg.width > 1, cg.height > 1 {
            return cg
        }
    }
    // VIDEO: an AVPlayerLayer renders BLACK into cacheDisplay off-screen (same as
    // web views). Instead generate a real poster frame from the asset so the
    // aurora has actual content to sweep over.
    if let asset = findPlayerAsset(in: host) {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .positiveInfinity
        gen.requestedTimeToleranceAfter = .positiveInfinity
        gen.maximumSize = CGSize(width: width * 2, height: h * 2)
        let at = CMTime(seconds: 0.1, preferredTimescale: 600)
        if let result = try? await gen.image(at: at), result.image.width > 1 {
            return result.image
        }
    }
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
    host.cacheDisplay(in: host.bounds, to: rep)
    return rep.cgImage
}

/// Depth-first search for the first `WKWebView` hosted under `view` (tweet /
/// instagram / youtube / webclip cards are web-view backed). Used so the reveal
/// can `takeSnapshot` it instead of cacheDisplay-ing a black off-screen frame.
@MainActor
private func findWebView(in view: NSView) -> WKWebView? {
    if let web = view as? WKWebView { return web }
    for sub in view.subviews {
        if let web = findWebView(in: sub) { return web }
    }
    return nil
}

/// Find the asset of the first AVPlayer hosted under `view` (an `AVPlayerView` or
/// a layer-hosted `AVPlayerLayer`) so a video card's reveal can use a real poster
/// frame instead of a black off-screen capture.
@MainActor
private func findPlayerAsset(in view: NSView) -> AVAsset? {
    if let pv = view as? AVPlayerView, let a = pv.player?.currentItem?.asset { return a }
    if let layer = view.layer, let a = playerAssetInLayer(layer) { return a }
    for sub in view.subviews {
        if let a = findPlayerAsset(in: sub) { return a }
    }
    return nil
}
private func playerAssetInLayer(_ layer: CALayer) -> AVAsset? {
    if let pl = layer as? AVPlayerLayer, let a = pl.player?.currentItem?.asset { return a }
    for s in layer.sublayers ?? [] {
        if let a = playerAssetInLayer(s) { return a }
    }
    return nil
}

/// Wraps any card view: when the node is freshly added, the on-screen card is
/// hidden while an off-screen copy loads, then it materialises through the same
/// aurora wave (incl. lens distortion) as images — never appearing beforehand.
/// TEMP DIAG (reveal): append one line to /tmp/clip_reveal.txt. Remove once the
/// blank-card / missing-aurora issue is understood.
func clipRevealLog(_ s: String) {
    let line = "[reveal] \(s)\n"
    let p = "/tmp/clip_reveal.txt"
    if let h = FileHandle(forWritingAtPath: p) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
    else { try? line.write(toFile: p, atomically: true, encoding: .utf8) }
}

/// TEMP DIAG: downsample a captured CGImage to 8×8 and report luminance spread.
/// min≈max≈high → the capture is blank/white (e.g. an off-screen WKWebView that
/// never painted); a real spread → the capture has actual content.
func clipImageStats(_ cg: CGImage) -> String {
    let n = 8, bpr = n * 4
    var buf = [UInt8](repeating: 0, count: bpr * n)
    guard let ctx = CGContext(data: &buf, width: n, height: n, bitsPerComponent: 8,
                              bytesPerRow: bpr, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return "stats?" }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
    var mn = 255, mx = 0, sum = 0
    for i in stride(from: 0, to: buf.count, by: 4) {
        let l = (Int(buf[i]) + Int(buf[i + 1]) + Int(buf[i + 2])) / 3
        mn = min(mn, l); mx = max(mx, l); sum += l
    }
    let blank = (mx - mn) < 6
    return "lum min=\(mn) max=\(mx) avg=\(sum / (n * n)) \(blank ? "→ BLANK" : "→ has-content")"
}

struct RevealingCard<Content: View>: View {
    let shouldReveal: Bool
    let onConsumed: () -> Void
    let captureWidth: CGFloat
    let captureHeight: CGFloat?     // nil = auto (tweet → sized to media aspect)
    let content: Content
    var debugKind: String = "?"
    // Web cards (WKWebView) need time to LOAD their embed before we takeSnapshot
    // it for the reveal — 650 ms snapshotted a half-loaded (often black) tweet.
    var settleNanos: UInt64 = 1_400_000_000
    var duration: CFTimeInterval = 1.5

    @State private var phase: Phase = .idle
    @State private var renderer: RevealRenderer? = nil
    private enum Phase { case idle, preparing, revealing, done }

    init(shouldReveal: Bool, onConsumed: @escaping () -> Void,
         captureWidth: CGFloat, captureHeight: CGFloat?, debugKind: String = "?",
         @ViewBuilder content: () -> Content) {
        self.shouldReveal = shouldReveal
        self.onConsumed = onConsumed
        self.captureWidth = captureWidth
        self.captureHeight = captureHeight
        self.debugKind = debugKind
        self.content = content()
    }

    var body: some View {
        content
            // Hidden until it materialises through the wave (so it never
            // appears before the effect). It still renders/loads while hidden.
            .opacity(phase == .preparing || phase == .revealing ? 0 : 1)
            .overlay {
                if phase == .revealing, let renderer {
                    WavefrontRevealImageView(renderer: renderer, duration: duration) {
                        withAnimation(Motion.fade) { phase = .done }
                    }
                    .allowsHitTesting(false)
                }
            }
            .task(id: shouldReveal) { await maybeStart() }
    }

    @MainActor
    private func maybeStart() async {
        clipRevealLog("\(debugKind) appear shouldReveal=\(shouldReveal) phase=\(phase) avail=\(RevealEngine.isAvailable) reduceMotion=\(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) w=\(captureWidth) h=\(captureHeight.map { "\($0)" } ?? "nil")")
        guard phase == .idle, shouldReveal else { return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              RevealEngine.isAvailable, captureWidth >= 1
        else { clipRevealLog("\(debugKind) SKIP (reduceMotion or !available or width<1) → card just appears"); onConsumed(); return }
        phase = .preparing                      // hide the on-screen card now
        let cg = await renderOffscreen(content, width: captureWidth,
                                       fixedHeight: captureHeight, settleNanos: settleNanos)
        clipRevealLog("\(debugKind) captured \(cg.map { "\($0.width)x\($0.height) — " + clipImageStats($0) } ?? "nil")")
        guard phase == .preparing else { return }
        if let cg {
            renderer = RevealRenderer(cgImage: cg, style: .aurora)
            phase = .revealing
        } else {
            phase = .done
        }
        onConsumed()
    }
}

// MARK: - Convenience

extension View {
    /// Sweeps a luminous band across this card once, when its node was just
    /// added to the canvas (the node id is in `pendingRevealNodeIDs`).
    func revealOnAdd(state: CanvasState, node: CanvasNode) -> some View {
        let kind: String
        switch node.kind {
        case .tweet:     kind = "tweet"
        case .instagram: kind = "instagram"
        case .youtube:   kind = "youtube"
        case .webclip:   kind = "webclip"
        case .image:     kind = "image"
        case .video:     kind = "video"
        default:         kind = "other"
        }
        return RevealingCard(
            shouldReveal: state.pendingRevealNodeIDs.contains(node.id),
            onConsumed: { state.pendingRevealNodeIDs.remove(node.id) },
            // Tweets have nil height → the off-screen render sizes them to their
            // media aspect (matching the on-screen card); other cards use theirs.
            captureWidth: node.width,
            captureHeight: node.height,
            debugKind: kind
        ) { self }
    }
}
