// CLIP landing — alphabet marquee, scroll reveals (transitions.dev
// texts-reveal), and the use-case comb-hover (avatar group hover).
(function () {
  const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* ---- Alphabet-coin marquee (two copies for a seamless -50% loop) ---- */
  const track = document.getElementById("marqueeTrack");
  if (track) {
    const make = () => "ABCDEFGHIJKLMNOPQRSTUVWXYZ".split("").map(L => {
      const img = document.createElement("img");
      img.src = `assets/letters/${L}.svg`; img.alt = ""; img.loading = "lazy";
      return img;
    });
    make().forEach(n => track.appendChild(n));
    make().forEach(n => track.appendChild(n));
  }

  /* ---- Reveals: .t-stagger -> .is-shown, .rise -> .in ---- */
  const heroText = document.getElementById("heroText");
  const staggers = document.querySelectorAll(".t-stagger");
  const rises = document.querySelectorAll(
    ".features .feature-row, .usecases, .iphone, .formats, .closer, .section-title, .feature-copy, .feature-visual"
  );
  rises.forEach(t => t.classList.add("rise"));

  // Hero copy plays immediately (above the fold). Must add .is-shown even
  // under reduced motion, since the lines rest at opacity:0 until shown.
  if (heroText) requestAnimationFrame(() => heroText.classList.add("is-shown"));

  if (reduce || !("IntersectionObserver" in window)) {
    staggers.forEach(s => s.classList.add("is-shown"));
    rises.forEach(t => t.classList.add("in"));
  } else {
    const io = new IntersectionObserver((entries) => {
      entries.forEach(e => {
        if (!e.isIntersecting) return;
        e.target.classList.add(e.target.classList.contains("t-stagger") ? "is-shown" : "in");
        io.unobserve(e.target);
      });
    }, { threshold: 0.12, rootMargin: "0px 0px -8% 0px" });
    staggers.forEach(s => { if (s !== heroText) io.observe(s); });
    rises.forEach(t => io.observe(t));
  }

  /* ---- Use-case comb-hover (avatar group hover) ---- */
  const group = document.getElementById("usecaseGroup");
  if (group && !reduce) {
    const items = Array.from(group.querySelectorAll(".t-avatar"));
    const cs = getComputedStyle(document.documentElement);
    const num = (n, fb) => { const v = parseFloat(cs.getPropertyValue(n)); return Number.isFinite(v) ? v : fb; };
    const ease = (n, fb) => cs.getPropertyValue(n).trim() || fb;
    function setShifts(active, phase) {
      const lift = num("--avatar-lift", -6), falloff = num("--avatar-falloff", 0.5), scale = num("--avatar-scale", 1.06);
      const tf = phase === "out"
        ? ease("--avatar-ease-out", "cubic-bezier(0.34,3.85,0.64,1)")
        : ease("--avatar-ease-in",  "cubic-bezier(0.22,1,0.36,1)");
      items.forEach((el, i) => {
        el.style.transitionTimingFunction = tf;
        if (active == null) { el.style.setProperty("--shift", "0px"); el.style.setProperty("--scale-active", "1"); return; }
        const d = Math.abs(i - active);
        el.style.setProperty("--shift", (lift * Math.pow(falloff, d)).toFixed(3) + "px");
        el.style.setProperty("--scale-active", i === active ? String(scale) : "1");
      });
    }
    items.forEach((el, i) => el.addEventListener("mouseenter", () => setShifts(i, "in")));
    group.addEventListener("mouseleave", () => setShifts(null, "out"));
  }
})();
