// Build the seamless alphabet-coin marquee, and reveal sections on scroll.
(function () {
  const letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ".split("");
  const track = document.getElementById("marqueeTrack");
  if (track) {
    const make = () => letters.map(L => {
      const img = document.createElement("img");
      img.src = `assets/letters/${L}.svg`;
      img.alt = "";
      img.loading = "lazy";
      return img;
    });
    // Two copies back-to-back so the CSS translate(-50%) loops seamlessly.
    make().forEach(n => track.appendChild(n));
    make().forEach(n => track.appendChild(n));
  }

  // Scroll-reveal: fade/rise sections as they enter the viewport.
  const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const targets = document.querySelectorAll(
    ".features .feature-row, .usecases, .iphone, .formats, .closer, .section-title, .feature-copy, .feature-visual"
  );
  if (reduce || !("IntersectionObserver" in window)) {
    targets.forEach(t => t.classList.add("in"));
    return;
  }
  const io = new IntersectionObserver((entries) => {
    entries.forEach(e => {
      if (e.isIntersecting) { e.target.classList.add("in"); io.unobserve(e.target); }
    });
  }, { threshold: 0.12, rootMargin: "0px 0px -8% 0px" });
  targets.forEach(t => { t.classList.add("rise"); io.observe(t); });
})();
