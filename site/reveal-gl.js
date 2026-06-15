/* ==========================================================
   Wavefront reveal — WebGL2 port of DopeDrop's Metal reveal shader.
   A luminous band sweeps across an image and the picture materialises
   behind it (style 0 = AURORA, the iridescent energy band). The 19
   styles from the original are all preserved; pick via opts.style.

   revealImage(img, opts) → Promise. Overlays a <canvas> on `img`,
   plays the reveal, then fades to the crisp <img> beneath and cleans up.
   Falls back to simply showing the image when WebGL2 is unavailable or
   the user prefers reduced motion.
   ========================================================== */

const REDUCE = matchMedia('(prefers-reduced-motion: reduce)').matches;

const VERT = `#version 300 es
precision highp float;
const vec2 verts[6] = vec2[6](
  vec2(-1.0,-1.0), vec2(1.0,-1.0), vec2(-1.0,1.0),
  vec2(-1.0, 1.0), vec2(1.0,-1.0), vec2( 1.0,1.0));
out vec2 vUv;
void main() {
  vec2 p = verts[gl_VertexID];
  gl_Position = vec4(p, 0.0, 1.0);
  vUv = vec2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);  // top-down, matches Metal vmain
}`;

const FRAG = `#version 300 es
precision highp float;
precision highp sampler2D;

in vec2 vUv;
out vec4 fragColor;

uniform sampler2D uTex;

struct U {
  float progress; float time; float dir; float padding; float bandWidth;
  float organicAmp; float organicFreq; float organicSpeed; float elevation;
  float swellAmount; float refractStrength; float curl; float highlights;
  float brightness; float hueCenter; float hueSpread; float tintStrength;
  float bloomStrength; float dimAmount; float blurBase; float blurPeak;
  float attack; float release; float overshoot; float style;
  float kbZoom; float kbPanX; float kbPanY;
};
uniform U u;

vec3 hsv2rgb(vec3 c) {
  vec4 K = vec4(1.0, 2.0/3.0, 1.0/3.0, 3.0);
  vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
  return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}
float hash21(vec2 p) {
  p = fract(p * vec2(123.34, 456.21));
  p += dot(p, p + 45.32);
  return fract(p.x * p.y);
}
float noise2(vec2 p) {
  vec2 i = floor(p), f = fract(p);
  float a = hash21(i);
  float b = hash21(i + vec2(1.0, 0.0));
  float c = hash21(i + vec2(0.0, 1.0));
  float d = hash21(i + vec2(1.0, 1.0));
  vec2 u = f * f * (3.0 - 2.0 * f);
  return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}
vec2 hash22(vec2 p) {
  p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
  return fract(sin(p) * 43758.5453);
}
float fbm(vec2 p) {
  float v = 0.0, a = 0.5;
  for (int i = 0; i < 5; i++) { v += a * noise2(p); p *= 2.02; a *= 0.5; }
  return v;
}
// FLIR-style thermal ramp: indigo (cold) -> blue -> magenta -> red -> orange -> white (hot)
vec3 heatRamp(float t) {
  t = clamp(t, 0.0, 1.0);
  vec3 c0 = vec3(0.02, 0.01, 0.18);
  vec3 c1 = vec3(0.10, 0.12, 0.85);
  vec3 c2 = vec3(0.62, 0.05, 0.78);
  vec3 c3 = vec3(1.00, 0.18, 0.12);
  vec3 c4 = vec3(1.00, 0.70, 0.05);
  vec3 c5 = vec3(1.00, 1.00, 0.88);
  float x = t * 5.0;
  int i = int(floor(x));
  float f = smoothstep(0.0, 1.0, fract(x));
  if (i <= 0) return mix(c0, c1, f);
  if (i == 1) return mix(c1, c2, f);
  if (i == 2) return mix(c2, c3, f);
  if (i == 3) return mix(c3, c4, f);
  return mix(c4, c5, f);
}
vec3 blurSample(vec2 uv, float radius) {
  if (radius < 0.0008) return texture(uTex, uv).rgb;
  vec3 acc = vec3(0.0);
  float wsum = 0.0;
  for (int j = -2; j <= 2; j++) {
    for (int i = -2; i <= 2; i++) {
      vec2 o = vec2(float(i), float(j)) * radius * 0.5;
      float w = exp(-dot(o, o) / max(radius * radius * 0.5, 1e-5));
      vec2 ss = clamp(uv + o, 0.0, 1.0);
      acc += texture(uTex, ss).rgb * w;
      wsum += w;
    }
  }
  return acc / max(wsum, 1e-4);
}

void main() {
  // Work in a transposed space so the band sweeps along the screen's Y axis
  // (top -> bottom). The texture is sampled back in normal orientation, so
  // the image stays upright; only the sweep direction rotates 90 degrees.
  vec2 uv = vec2(vUv.y, vUv.x);

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
               + (noise2(vec2(uv.y * 6.0, u.time * 0.6)) - 0.5) * 0.80;
  wobble *= u.organicAmp;
  float dx_eff = dx - wobble;

  float e1 = dx_eff / max(u.bandWidth, 0.01);
  float energy = exp(-e1 * e1);

  float topPadNoise = (noise2(vec2(uv.x * 5.0,  u.time * 0.4)) - 0.5) * 0.012;
  float botPadNoise = (noise2(vec2(uv.x * 5.0, -u.time * 0.4 + 13.7)) - 0.5) * 0.012;
  float topEdge = u.padding + topPadNoise;
  float botEdge = (1.0 - u.padding) + botPadNoise;
  float maskY = smoothstep(topEdge, topEdge + 0.025, uv.y)
              * (1.0 - smoothstep(botEdge - 0.025, botEdge, uv.y));
  energy *= maskY;

  float r = max(u.bandWidth, 0.01);
  float e2 = dx / r;
  float bulge = exp(-e2 * e2) * maskY;
  float dz_dx = u.elevation * bulge * (-2.0 * dx / (r * r));
  vec3 N = normalize(vec3(-dz_dx, 0.0, 1.0));

  float magnify = 1.0 + bulge * 0.35 * u.swellAmount;
  float magX = bandX + (uv.x - bandX) / magnify;
  vec2 anchor = vec2(bandX, 0.5);
  vec2 toAnchor = anchor - vec2(magX, uv.y);
  vec2 curled = vec2(magX, uv.y) + toAnchor * bulge * u.curl * 0.35;
  vec2 sampleUV = clamp(vec2(curled.x + N.x * u.refractStrength * bulge, curled.y),
                          vec2(0.0), vec2(1.0));

  float attackEnv  = smoothstep(0.0, max(u.attack, 0.001), u.progress);
  float releaseEnv = 1.0 - smoothstep(1.0 - max(u.release, 0.001), 1.0, u.progress);
  float envelope = attackEnv * releaseEnv;

  float bt = clamp(u.progress / max(u.attack, 0.001), 0.0, 1.0);
  float blurAttackEnv = bt * bt * bt * (bt * (bt * 6.0 - 15.0) + 10.0);
  float blurEnvelope = blurAttackEnv * releaseEnv;
  float blurAmt = mix(u.blurBase, u.blurPeak, energy) * blurEnvelope;

  // Transpose the sample coordinate back to image space (keeps image upright).
  vec2 kbPan = vec2(u.kbPanX, u.kbPanY);
  vec2 texUV = clamp((vec2(sampleUV.y, sampleUV.x) - 0.5) / u.kbZoom + 0.5 + kbPan, 0.0, 1.0);   // Ken-Burns zoom/pan (identity by default)
  vec3 toRGB = blurSample(texUV, blurAmt);
  float toA = texture(uTex, texUV).a;

  float wipeCross = u.bandWidth * 0.4;
  float wipeT = smoothstep(-wipeCross, wipeCross, dx_eff);
  float pageMix = u.dir > 0.0 ? (1.0 - wipeT) : wipeT;
  vec3 page = toRGB * pageMix;
  float pageA = toA * pageMix;

  // Shared reveal helpers for the post-aurora styles. These styles reveal EXACTLY
  // like 0–3: \`revealA\` gates alpha so everything AHEAD of the wavefront is fully
  // transparent (the image doesn't exist yet — the wave paints it in). The effect
  // is a TRAIL that rides just behind the front and resolves to the clean photo,
  // so it ends on the real preview. \`behindDist\` = how far a revealed pixel sits
  // behind the front; \`iuv\` is the upright (untransposed) image uv.
  float sd = dx_eff * u.dir;            // < 0 on the already-revealed side
  float behindDist = max(0.0, -sd);     // distance behind the wavefront
  float revealA = pageMix * toA;        // master visibility — transparent ahead
  vec2 iuv = clamp((vUv - 0.5) / u.kbZoom + 0.5 + kbPan, 0.0, 1.0);   // Ken-Burns zoom/pan

  // Shared surface lighting (used by every style).
  vec3 surfPos = vec3((uv.x - 0.5) * 2.0, (0.5 - uv.y) * 2.0, u.elevation * bulge);
  vec3 L = normalize(vec3(-0.5, 0.7, 1.6) - surfPos);
  vec3 V = normalize(-surfPos);
  vec3 H = normalize(L + V);
  float NdotV = clamp(dot(N, V), 0.0, 1.0);
  float fresnel = pow(1.0 - NdotV, 3.0) * bulge;
  float spec = pow(clamp(dot(N, H), 0.0, 1.0), 96.0) * bulge;

  vec3 col;
  float alpha;

  if (u.style < 0.5) {
    // ── 0 · AURORA — the original iridescent energy band. ──────────────
    float luma = dot(page, vec3(0.299, 0.587, 0.114));
    vec3 dimmed = mix(page, vec3(luma) * 0.45, energy * u.dimAmount);
    dimmed *= mix(1.0, 1.0 - u.dimAmount * 0.4, energy);
    float hueDrift = (noise2(vec2(uv.y * 1.4, u.time * 0.22)) - 0.5) * 0.05;
    float hue = u.hueCenter + (uv.y - 0.5) * u.hueSpread * 0.55 + hueDrift;
    float sat = 0.80 + sin(uv.y * 2.6 + u.time * 0.4) * 0.05;
    float val = 0.97 + sin(uv.y * 4.1 - u.time * 0.3) * 0.03;
    vec3 iri = hsv2rgb(vec3(fract(hue), sat, val)) * u.brightness;
    vec3 tinted = mix(dimmed, dimmed * iri * 1.25, energy * u.tintStrength);
    vec3 bloom = iri * energy * u.bloomStrength;
    vec3 highlights = (iri * fresnel * 0.55 + vec3(spec) * 1.6) * u.highlights;
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
    vec3 lit  = page * (1.0 + pop * 0.22);
    vec3 cool = vec3(0.6, 0.78, 1.0);
    col = lit + (cool * halo * 0.45 + vec3(1.0) * core * 0.9
              + vec3(spec) * 0.8) * envelope;
    alpha = clamp(pageA + (halo * 0.45 + core) * envelope * 0.7, 0.0, 1.0);

  } else if (u.style < 2.5) {
    // ── 2 · DISSOLVE — the photo materialises through a ragged, multi-scale ──
    //   front. fbm warps the erosion threshold (organic edge, not regular
    //   noise); soft ROUND sparks with a fade-in/out lifetime scatter at the
    //   rim, and the rim itself carries a faint energising glow.
    float grain = (fbm(uv * 9.0 + vec2(u.time * 0.25, 0.0)) - 0.5)
                + (noise2(uv * 30.0) - 0.5) * 0.35;
    float wt = smoothstep(-wipeCross * 2.4, wipeCross * 2.4, dx_eff + grain * u.bandWidth * 1.8);
    float pm = u.dir > 0.0 ? (1.0 - wt) : wt;
    float near = pow(max(0.0, 1.0 - abs(dx_eff) / max(u.bandWidth, 0.01)), 2.2);
    // round soft sparkles: jitter a point inside each cell, gaussian falloff, twinkle.
    vec2 sg  = uv * 90.0;
    vec2 sid = floor(sg);
    vec2 spt = hash22(sid);
    float life = 0.5 + 0.5 * sin(u.time * 7.0 + hash21(sid) * 6.2831);
    float sd2  = length(fract(sg) - spt);
    float spark = exp(-sd2 * sd2 * 50.0) * step(0.55, hash21(sid + 3.1))
                * near * life * life;
    vec3 sparkCol = mix(vec3(1.0, 0.95, 0.85), vec3(0.8, 0.9, 1.0), hash21(sid));
    col = toRGB * pm + sparkCol * spark * envelope * 1.1
        + vec3(0.55, 0.7, 1.0) * near * pm * envelope * 0.12;
    alpha = clamp(toA * pm + spark * envelope, 0.0, 1.0);

  } else if (u.style < 3.5) {
    // ── 3 · LIQUID GLASS — a clear lens sweeps THROUGH the image. Chromatic ──
    //   dispersion splits R/B along the refraction normal (prismatic edge — the
    //   single biggest "this is real glass" tell), a caustic band focuses light
    //   just behind the lens, and the leading edge darkens slightly so the lens
    //   body reads with genuine volume against the bright crest.
    float disp = N.x * u.refractStrength * bulge * 1.4;
    float rC = texture(uTex, clamp(vec2(texUV.x, texUV.y + disp), 0.0, 1.0)).r;
    float bC = texture(uTex, clamp(vec2(texUV.x, texUV.y - disp), 0.0, 1.0)).b;
    vec3 glass = vec3(rC, toRGB.g, bC) * pageMix;
    float caustic = pow(max(0.0, 1.0 - abs(dx_eff + u.bandWidth * 0.35 * u.dir)
                                  / max(u.bandWidth, 0.01)), 3.0);
    float edgeShadow = pow(energy, 1.2) * 0.10 * envelope;
    float crest = energy * envelope;
    col = glass * (1.0 - edgeShadow)
        + (vec3(spec) * 2.2 + vec3(0.8, 0.9, 1.0) * fresnel * 0.6) * envelope
        + vec3(0.85, 0.92, 1.0) * caustic * envelope * 0.35
        + vec3(0.7, 0.85, 1.0) * crest * 0.10;
    alpha = clamp(pageA + crest * 0.5, 0.0, 1.0);

  } else if (u.style < 4.5) {
    // ── 4 · HEATMAP — the image materialises THROUGH a thermal front and
    //        cools into the true photo behind it (FLIR seam). Hidden ahead.
    float trail = 1.0 - smoothstep(0.0, 0.55, behindDist);
    float luma = dot(toRGB, vec3(0.299, 0.587, 0.114));
    vec3 thermal = heatRamp(pow(luma, 0.85));
    float crest = pow(energy, 1.4) * envelope;
    col = mix(toRGB, thermal, trail) + vec3(1.0, 0.92, 0.78) * crest * 0.40;
    alpha = clamp(revealA + crest * 0.40, 0.0, 1.0);

  } else if (u.style < 5.5) {
    // ── 5 · HALFTONE — a rotated print screen: colour dots arrive at the front
    //   and GROW + merge into the full photo behind it. The grid is rotated to a
    //   classic ~22° screen angle (so it reads as ink dots, never a pixel grid),
    //   and the inter-dot field is light paper, not black tiles.
    float trail = 1.0 - smoothstep(0.0, 0.42, behindDist);
    float cells = 84.0;
    float ca = 0.924, sa = 0.383;                 // cos/sin(22.5°)
    vec2 ruv = vec2(iuv.x * ca - iuv.y * sa, iuv.x * sa + iuv.y * ca);
    vec2 gv = ruv * cells;
    vec2 cell = floor(gv) + 0.5;
    // rotate the cell centre back into image space to fetch its colour.
    vec2 cuv = vec2(cell.x * ca + cell.y * sa, -cell.x * sa + cell.y * ca) / cells;
    vec3 cc = texture(uTex, clamp(cuv, 0.0, 1.0)).rgb;
    float ink = clamp(dot(cc, vec3(0.299, 0.587, 0.114)), 0.0, 1.0);
    vec2 off = fract(gv) - 0.5;
    float d = length(off);
    // dots grow from ink-sized toward fully merged (≈0.95 fills the cell) as the trail passes.
    float dr = mix(sqrt(ink) * 0.72, 0.95, trail * 0.6);
    float aa = max(fwidth(d), 0.0015);
    float cov = smoothstep(dr, dr - aa, d);
    vec3 paper = mix(vec3(0.92, 0.93, 0.96), toRGB, 0.35);
    vec3 ht = mix(paper, cc * 1.1, cov);
    float crest = pow(energy, 1.5) * envelope;
    col = mix(toRGB, ht, trail) + vec3(0.55, 0.7, 1.0) * crest * 0.22;
    alpha = clamp(revealA + crest * 0.25, 0.0, 1.0);

  } else if (u.style < 6.5) {
    // ── 6 · MOTION BLUR — the photo rushes in along the sweep axis and sharpens
    //   as it settles. A longer, weighted tap-tail keeps the streak smooth (no
    //   banding), the blur eases in (trail²) so it SNAPS to crisp, and a bright
    //   light-streak stretches the highlights along the motion axis for energy.
    float trail = 1.0 - smoothstep(0.0, 0.34, behindDist);
    float amt = trail * trail * 0.11;
    vec3 acc = vec3(0.0); float wsum = 0.0;
    for (int i = 0; i < 13; i++) {
      float t = float(i) / 12.0;
      vec2 o = vec2(0.0, t * amt * u.dir);
      float w = 1.0 - t * 0.7;
      acc += texture(uTex, clamp(iuv - o, 0.0, 1.0)).rgb * w;
      wsum += w;
    }
    vec3 smeared = acc / max(wsum, 1e-3);
    float br = max(0.0, dot(smeared, vec3(0.299, 0.587, 0.114)) - 0.55);
    float crest = pow(energy, 1.5) * envelope;
    col = mix(toRGB, smeared, trail)
        + vec3(0.7, 0.82, 1.0) * (crest * 0.30 + br * trail * 0.5)
        + vec3(spec) * 0.5 * envelope;
    alpha = clamp(revealA + crest * 0.35, 0.0, 1.0);

  } else if (u.style < 7.5) {
    // ── 7 · PIXEL MOSAIC — coarse blocks at the front snap down to full
    //        res behind it; tile gaps glow at the wave. Hidden ahead.
    float trail = 1.0 - smoothstep(0.0, 0.40, behindDist);
    float blocks = max(mix(150.0, 12.0, trail), 4.0);
    vec2 quv = (floor(iuv * blocks) + 0.5) / blocks;
    vec3 px = texture(uTex, clamp(quv, 0.0, 1.0)).rgb;
    vec2 g = fract(iuv * blocks);
    float gap = min(min(g.x, g.y), min(1.0 - g.x, 1.0 - g.y));
    float grid = (1.0 - smoothstep(0.0, 0.06, gap)) * energy * envelope;
    float crest = pow(energy, 1.4) * envelope;
    col = mix(toRGB, px, trail)
        + vec3(0.4, 0.6, 1.0) * grid * 0.4 + vec3(0.8, 0.9, 1.0) * crest * 0.2;
    alpha = clamp(revealA + crest * 0.25, 0.0, 1.0);

  } else if (u.style < 8.5) {
    // ── 8 · CHROMATIC GLITCH — RGB channel split + scanline jitter at the
    //        front, converging to a clean frame behind it. Hidden ahead.
    float trail = 1.0 - smoothstep(0.0, 0.32, behindDist);
    float sep = trail * 0.02;
    float jitter = (noise2(vec2(iuv.y * 90.0, u.time * 3.5)) - 0.5) * trail * 0.03;
    vec2 j = vec2(jitter, 0.0);
    float rC = texture(uTex, clamp(iuv + vec2(sep, 0.0) + j, 0.0, 1.0)).r;
    float gC = texture(uTex, clamp(iuv + j, 0.0, 1.0)).g;
    float bC = texture(uTex, clamp(iuv - vec2(sep, 0.0) + j, 0.0, 1.0)).b;
    float scan = 1.0 - trail * 0.18 * step(0.5, fract(iuv.y * 180.0));
    vec3 eff = vec3(rC, gC, bC) * scan;
    vec3 fringe = vec3(0.0, 1.0, 1.0) * step(0.0, dx_eff)
                  + vec3(1.0, 0.1, 0.5) * step(dx_eff, 0.0);
    col = mix(toRGB, eff, trail) + fringe * energy * envelope * 0.3;
    alpha = clamp(revealA + energy * envelope * 0.25, 0.0, 1.0);

  } else if (u.style < 9.5) {
    // ── 9 · RIPPLE — concentric water ripples trail the front, refracting the
    //        image; caustic glints ride the crests, then settle to the photo.
    float trail = 1.0 - smoothstep(0.0, 0.6, behindDist);
    float wavePhase = behindDist * 90.0 - u.time * 6.0;
    float ripple = sin(wavePhase) * trail * 0.012;
    vec3 water = texture(uTex, clamp(iuv + vec2(ripple * 0.5, ripple), 0.0, 1.0)).rgb;
    float caustic = pow(max(0.0, sin(wavePhase)), 8.0) * trail;
    float crest = pow(energy, 1.4) * envelope;
    col = mix(toRGB, water, trail)
        + vec3(0.6, 0.85, 1.0) * caustic * 0.25 + vec3(spec) * 0.6 * envelope;
    alpha = clamp(revealA + crest * 0.3, 0.0, 1.0);

  } else if (u.style < 10.5) {
    // ── 10 · INK BLEED — the photo seeps in through a ragged, noise-warped
    //         front like watercolour on paper, pigment pooling at the wet rim.
    float grain = fbm(uv * 7.0) - 0.5;
    float wt = smoothstep(-wipeCross * 2.5, wipeCross * 2.5, dx_eff + grain * u.bandWidth * 2.2);
    float pm = u.dir > 0.0 ? (1.0 - wt) : wt;
    float trail = 1.0 - smoothstep(0.0, 0.5, behindDist);
    vec2 warp = (vec2(fbm(iuv * 9.0), fbm(iuv * 9.0 + 7.3)) - 0.5) * trail * 0.018;
    vec3 ink = texture(uTex, clamp(iuv + warp, 0.0, 1.0)).rgb;
    float lum = dot(ink, vec3(0.299, 0.587, 0.114));
    ink = mix(ink, mix(ink, vec3(lum), 0.35), trail * 0.5);
    float rim = pow(max(0.0, 1.0 - abs(dx_eff) / max(u.bandWidth, 0.01)), 2.0);
    col = mix(toRGB, ink, trail) - vec3(0.06, 0.05, 0.04) * rim * envelope;
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
    vec3 mask = vec3(smoothstep(0.66, 0.5, abs(stripe - 0.17)),
                         smoothstep(0.66, 0.5, abs(stripe - 0.50)),
                         smoothstep(0.66, 0.5, abs(stripe - 0.83)));
    mask = mix(vec3(1.0), mask * 1.6, trail);
    float scan = 1.0 - 0.22 * trail * (0.5 + 0.5 * sin(iuv.y * scanFreq * 6.2831));
    vec3 crt = toRGB * mask * scan;
    float beam  = pow(energy, 2.0) * envelope;
    float flash = pow(energy, 6.0) * envelope;       // hot power-on snap
    vec2 vc = iuv - 0.5;
    float vig = 1.0 - dot(vc, vc) * 0.6 * trail;      // tube curvature falloff
    col = mix(toRGB, crt, trail) * vig
        + vec3(0.7, 1.0, 0.9) * beam * 0.35
        + vec3(1.0) * flash * 0.6;
    alpha = clamp(revealA + (beam + flash) * 0.4, 0.0, 1.0);

  } else if (u.style < 12.5) {
    // ── 12 · CRYSTALLIZE — the image forms as Voronoi facets (large at the
    //         front, refining behind), glowing along the cell seams.
    float trail = 1.0 - smoothstep(0.0, 0.5, behindDist);
    float cells = mix(120.0, 26.0, trail);
    vec2 g = iuv * cells;
    vec2 ip = floor(g), fp = fract(g);
    float md = 8.0; vec2 mc = vec2(0.0);
    for (int y = -1; y <= 1; y++) {
      for (int x = -1; x <= 1; x++) {
        vec2 o = vec2(float(x), float(y));
        vec2 r = o + hash22(ip + o) - fp;
        float d = dot(r, r);
        if (d < md) { md = d; mc = ip + o + hash22(ip + o); }
      }
    }
    vec3 cellCol = texture(uTex, clamp(mc / cells, 0.0, 1.0)).rgb;
    float edge = smoothstep(0.0, 0.05, sqrt(md));
    vec3 crys = mix(vec3(0.8, 0.9, 1.0), cellCol, edge);
    float crest = pow(energy, 1.4) * envelope;
    col = mix(toRGB, crys, trail)
        + vec3(0.5, 0.7, 1.0) * (1.0 - edge) * trail * 0.3 + vec3(spec) * 0.5 * envelope;
    alpha = clamp(revealA + crest * 0.3, 0.0, 1.0);

  } else if (u.style < 13.5) {
    // ── 13 · LIGHT SWEEP — a bright anamorphic flare with horizontal streaks
    //         rides the wavefront over the revealed photo (lens-flare bloom).
    float crest = pow(energy, 2.0) * envelope;
    vec3 streak = vec3(0.0); float ws = 0.0;
    for (int i = -6; i <= 6; i++) {
      vec2 o = vec2(float(i) * 0.012, 0.0);
      vec3 s = texture(uTex, clamp(iuv + o, 0.0, 1.0)).rgb;
      float br = max(0.0, dot(s, vec3(0.299, 0.587, 0.114)) - 0.6);
      float w = 1.0 - abs(float(i)) / 7.0;
      streak += s * br * w; ws += w;
    }
    streak /= max(ws, 1e-3);
    vec3 flare = vec3(0.6, 0.8, 1.0) + streak * 3.0;
    col = toRGB + flare * crest * 0.7 + vec3(1.0) * crest * 0.3;
    alpha = clamp(revealA + crest * 0.5, 0.0, 1.0);

  } else if (u.style < 14.5) {
    // ── 14 · HOLOGRAPHIC — thin-film iridescence (driven by view angle,
    //         surface normal + position) sheens over the image as it lands.
    float trail = 1.0 - smoothstep(0.0, 0.5, behindDist);
    float band = fresnel * 2.0 + N.x * 3.0 + behindDist * 6.0 + iuv.x * 2.0;
    vec3 holo = 0.5 + 0.5 * cos(6.2831 * (band + vec3(0.0, 0.33, 0.67)));
    vec3 sheen = mix(toRGB, toRGB * 0.6 + holo * 0.7, trail * 0.6);
    float crest = pow(energy, 1.4) * envelope;
    col = mix(toRGB, sheen, trail) + holo * crest * 0.4 + vec3(spec) * 0.8 * envelope;
    alpha = clamp(revealA + crest * 0.35, 0.0, 1.0);

  } else if (u.style < 15.5) {
    // ── 15 · TOPOGRAPHIC — the image first reads as glowing luminance contour
    //         lines over a dark map, then fills to the full photo behind.
    float trail = 1.0 - smoothstep(0.0, 0.5, behindDist);
    float luma = dot(toRGB, vec3(0.299, 0.587, 0.114));
    float lv = luma * 14.0;
    float fline = abs(fract(lv) - 0.5);
    float aa = max(fwidth(lv), 0.001);
    float contour = 1.0 - smoothstep(0.0, aa * 1.5, fline);
    vec3 base = mix(vec3(0.02, 0.04, 0.06), toRGB, 0.2);
    vec3 topo = base + vec3(0.3, 0.9, 0.6) * contour;
    float crest = pow(energy, 1.5) * envelope;
    col = mix(toRGB, topo, trail) + vec3(0.3, 0.9, 0.6) * contour * trail * 0.4;
    alpha = clamp(revealA + crest * 0.3, 0.0, 1.0);

  } else if (u.style < 16.5) {
    // ── 16 · PLASMA — a turbulent electric field (multi-octave noise) burns
    //         the image in and cools into the photo behind the front.
    float trail = 1.0 - smoothstep(0.0, 0.55, behindDist);
    float pl = fbm(iuv * 6.0 + vec2(u.time * 0.6, u.time * 0.4))
             + 0.5 * fbm(iuv * 12.0 - u.time * 0.3);
    vec3 plasma = vec3(0.4 + 0.6 * sin(pl * 6.0),
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
    vec3 slatCol = mix(vec3(0.05, 0.06, 0.08), toRGB, louver);
    float edgeGlow = (1.0 - smoothstep(0.0, 0.08, abs(strip - openAmt))) * energy * envelope;
    col = mix(toRGB, slatCol, trail) + vec3(0.6, 0.8, 1.0) * edgeGlow * 0.3;
    alpha = clamp(revealA + energy * envelope * 0.2, 0.0, 1.0);

  } else {
    // ── 18 · FROST THAW — a frosty crystalline blur thaws to a clear photo;
    //         facets sparkle in the cold front, then melt away.
    float trail = 1.0 - smoothstep(0.0, 0.55, behindDist);
    float n = noise2(iuv * 40.0);
    float radius = trail * 0.02 * (0.6 + 0.8 * n);
    vec3 frosted = blurSample(iuv, radius);
    float facet = step(0.92, hash21(floor(iuv * 120.0))) * trail;
    vec3 ice = frosted * mix(vec3(1.0), vec3(0.85, 0.93, 1.0), trail)
               + vec3(0.9, 0.95, 1.0) * facet * 0.5;
    float crest = pow(energy, 1.5) * envelope;
    col = mix(toRGB, ice, trail)
        + vec3(0.7, 0.85, 1.0) * crest * 0.25 + vec3(spec) * 0.5 * envelope;
    alpha = clamp(revealA + crest * 0.3, 0.0, 1.0);
  }

  // Confine every reveal effect to the object's own silhouette: gate the final
  // alpha by the texture's coverage at THIS output pixel (vUv, unrefracted),
  // not the refracted sample — refraction near the edge can pull alpha from
  // inside the shape and leave faint strokes just outside it (very visible on a
  // white background). Sampling the true coverage clips bands, glows, sparkles
  // and crests exactly to the silhouette. Full-bleed photos (coverage == 1
  // everywhere) are unaffected.
  float coverageA = texture(uTex, iuv).a;
  alpha *= smoothstep(0.0, 0.08, coverageA);

  // premultiplied alpha for CALayer compositing over the transparent window
  fragColor = vec4(col * alpha, alpha);
}
`;

// AURORA preset (style 0). Hue leans green→cyan to sit on the CLIP palette.
const PRESET = {
  style: 0,
  dir: 1.0,
  padding: 0.0,
  bandWidth: 0.16,
  organicAmp: 0.04,
  organicFreq: 7.0,
  organicSpeed: 1.3,
  elevation: 0.16,
  swellAmount: 1.0,
  refractStrength: 0.06,
  curl: 0.5,
  highlights: 1.0,
  brightness: 1.06,
  hueCenter: 0.40,
  hueSpread: 0.55,
  tintStrength: 0.7,
  bloomStrength: 0.55,
  dimAmount: 0.55,
  blurBase: 0.0,
  blurPeak: 0.018,
  attack: 0.18,
  release: 0.18,
  overshoot: 0.12,
  kbZoom: 1.0,
  kbPanX: 0.0,
  kbPanY: 0.0,
};
const FIELDS = Object.keys(PRESET).concat(['progress', 'time']);

function easeInOutCubic(t) { return t < 0.5 ? 4*t*t*t : 1 - Math.pow(-2*t + 2, 3) / 2; }

function compile(gl, type, src) {
  const sh = gl.createShader(type);
  gl.shaderSource(sh, src);
  gl.compileShader(sh);
  if (!gl.getShaderParameter(sh, gl.COMPILE_STATUS)) {
    console.warn('[reveal] shader compile failed:', gl.getShaderInfoLog(sh));
    gl.deleteShader(sh);
    return null;
  }
  return sh;
}

// Rasterise any <img> (incl. SVG) into a texture-ready canvas, capped for speed.
function rasterise(img) {
  const max = 1024;
  const iw = img.naturalWidth || img.width || max;
  const ih = img.naturalHeight || img.height || max;
  const s = Math.min(1, max / Math.max(iw, ih));
  const c = document.createElement('canvas');
  c.width = Math.max(1, Math.round(iw * s));
  c.height = Math.max(1, Math.round(ih * s));
  c.getContext('2d').drawImage(img, 0, 0, c.width, c.height);
  return c;
}

export function revealImage(img, opts = {}) {
  return new Promise((resolve) => {
    if (REDUCE || !img) { resolve(); return; }

    const start = () => {
      const o = Object.assign({ duration: 1500 }, PRESET, opts);

      const host = img.parentElement || img;
      const canvas = document.createElement('canvas');
      canvas.className = 'reveal-gl';
      const dpr = Math.min(window.devicePixelRatio || 1, 2);
      const rect = img.getBoundingClientRect();
      const cssW = Math.max(1, Math.round(rect.width));
      const cssH = Math.max(1, Math.round(rect.height));
      canvas.width = Math.round(cssW * dpr);
      canvas.height = Math.round(cssH * dpr);
      canvas.style.width = cssW + 'px';
      canvas.style.height = cssH + 'px';

      const gl = canvas.getContext('webgl2', {
        premultipliedAlpha: true, alpha: true, antialias: true,
        preserveDrawingBuffer: false,
      });
      if (!gl) { resolve(); return; }   // no WebGL2 → leave the plain image

      const vs = compile(gl, gl.VERTEX_SHADER, VERT);
      const fs = compile(gl, gl.FRAGMENT_SHADER, FRAG);
      if (!vs || !fs) { resolve(); return; }
      const prog = gl.createProgram();
      gl.attachShader(prog, vs); gl.attachShader(prog, fs); gl.linkProgram(prog);
      if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) {
        console.warn('[reveal] link failed:', gl.getProgramInfoLog(prog));
        resolve(); return;
      }

      // Texture from the rasterised image (v=0 at top → matches the shader uv).
      const tex = gl.createTexture();
      gl.bindTexture(gl.TEXTURE_2D, tex);
      gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, false);
      gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, false);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, rasterise(img));
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);

      const vao = gl.createVertexArray();   // WebGL2 needs a bound VAO to draw
      gl.bindVertexArray(vao);

      gl.useProgram(prog);
      const loc = {};
      for (const f of FIELDS) loc[f] = gl.getUniformLocation(prog, 'u.' + f);
      gl.uniform1i(gl.getUniformLocation(prog, 'uTex'), 0);
      gl.activeTexture(gl.TEXTURE0);
      gl.bindTexture(gl.TEXTURE_2D, tex);
      gl.viewport(0, 0, canvas.width, canvas.height);
      gl.disable(gl.BLEND);   // single opaque-to-the-canvas pass, premultiplied out
      for (const f of Object.keys(PRESET)) if (loc[f]) gl.uniform1f(loc[f], o[f]);

      // Mount over the image; hide the real image until the reveal lands on it.
      if (host !== img) {
        const cs = getComputedStyle(host);
        if (cs.position === 'static') host.style.position = 'relative';
      }
      host.appendChild(canvas);
      const prevVis = img.style.visibility;
      img.style.visibility = 'hidden';

      const durSec = o.duration / 1000;
      const t0 = performance.now();
      function frame(now) {
        const elapsed = (now - t0) / 1000;
        const p = Math.min(elapsed / durSec, 1);
        gl.uniform1f(loc.progress, easeInOutCubic(p));
        gl.uniform1f(loc.time, elapsed);
        gl.drawArrays(gl.TRIANGLES, 0, 6);
        if (p < 1) { requestAnimationFrame(frame); return; }
        // Land on the crisp image, then fade the canvas out and clean up.
        img.style.visibility = prevVis;
        canvas.style.transition = 'opacity 160ms ease';
        canvas.style.opacity = '0';
        const done = () => {
          canvas.remove();
          gl.deleteTexture(tex); gl.deleteProgram(prog);
          gl.deleteShader(vs); gl.deleteShader(fs); gl.deleteVertexArray(vao);
          const lose = gl.getExtension('WEBGL_lose_context'); if (lose) lose.loseContext();
          resolve();
        };
        canvas.addEventListener('transitionend', done, { once: true });
        setTimeout(done, 320);   // safety in case transitionend doesn't fire
      }
      requestAnimationFrame(frame);
    };

    if (img.complete && img.naturalWidth) start();
    else img.addEventListener('load', start, { once: true });
  });
}
