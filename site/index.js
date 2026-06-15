/* ==========================================================
   CLIP homepage — Motion-driven interactions (vanilla ESM)
   Library: https://motion.dev  (no build step, loaded from CDN)
   Principles: animations.dev / Emil Kowalski
     · enter/exit → ease-out · keep it fast (<300ms hovers)
     · origin-aware modal · blur bridges states · springs for feel
   ========================================================== */

import { revealImage } from './reveal-gl.js';

const REDUCE = matchMedia('(prefers-reduced-motion: reduce)').matches;
const EASE_OUT = [0.22, 1, 0.36, 1];   // energetic expo-out
const EASE_IN  = [0.4, 0, 1, 1];

const SPRING_HOVER = { type: 'spring', stiffness: 400, damping: 28 };
const SPRING_PRESS = { type: 'spring', stiffness: 620, damping: 30 };
const SPRING_BACK  = { type: 'spring', stiffness: 500, damping: 24 };
const MODAL_IN     = { type: 'spring', visualDuration: 0.5, bounce: 0.18 };
const MODAL_OUT    = { duration: 0.3, ease: EASE_IN };

let M = null;
const html = document.documentElement;

init();

async function init() {
  // Safety: never leave entrance UI hidden if Motion is slow to arrive
  const reveal = setTimeout(() => html.classList.remove('js'), 700);
  try {
    M = await import('https://cdn.jsdelivr.net/npm/motion@12.40.0/+esm');
  } catch (err) {
    // CDN blocked → reveal everything, keep the modal usable without motion
    clearTimeout(reveal);
    html.classList.remove('js');
    wireModalFallback();
    return;
  }
  clearTimeout(reveal);
  entrance();
  gestures();
  wireModal();
}

/* ── Page entrance: staggered blur-rise of the overlay UI ── */
function entrance() {
  // If the safety timeout already revealed the UI, don't re-hide/blink it
  if (REDUCE || !html.classList.contains('js')) {
    html.classList.remove('js');
    return;
  }
  const { animate } = M;
  document.querySelectorAll('.enter').forEach((el, i) => {
    animate(
      el,
      { opacity: [0, 1], y: [12, 0], filter: ['blur(8px)', 'blur(0px)'] },
      { duration: 0.6, ease: EASE_OUT, delay: 0.05 + i * 0.08 }
    );
  });
}

/* ── Hover / press gestures ── */
function gestures() {
  if (REDUCE) return;
  const { animate, hover, press } = M;

  // Download pill — lift + warm fill on hover, tactile press, icon lean-in
  const pill = document.getElementById('downloadBtn');
  const icon = pill.querySelector('.ui-pill-icon img');
  // Only animate the lift + icon — CSS owns the gradient/gloss/glow/edge finish
  hover(pill, () => {
    animate(pill, { y: -2 }, SPRING_HOVER);
    animate(icon, { scale: 1.08 }, SPRING_HOVER);
    return () => {
      animate(pill, { y: 0 }, SPRING_HOVER);
      animate(icon, { scale: 1 }, SPRING_HOVER);
    };
  });
  press(pill, () => {
    animate(pill, { scale: 0.97 }, SPRING_PRESS);
    return () => animate(pill, { scale: 1 }, SPRING_BACK);
  });

  // Close button — rotates in on hover
  const closeBtn = document.getElementById('modalClose');
  hover(closeBtn, () => {
    animate(closeBtn, { rotate: 90, backgroundColor: 'rgba(0,0,0,0.06)', color: '#000' }, SPRING_HOVER);
    return () => animate(closeBtn, { rotate: 0, backgroundColor: 'rgba(0,0,0,0)', color: 'rgba(0,0,0,0.45)' }, SPRING_HOVER);
  });
  press(closeBtn, () => {
    animate(closeBtn, { scale: 0.9 }, SPRING_PRESS);
    return () => animate(closeBtn, { scale: 1 }, SPRING_BACK);
  });

  // Brand — draw-in underline (animates a CSS variable the ::after reads)
  const brand = document.querySelector('.ui-brand');
  hover(brand, () => {
    animate(brand, { '--bul': 1 }, { duration: 0.25, ease: EASE_OUT });
    return () => animate(brand, { '--bul': 0 }, { duration: 0.2, ease: EASE_OUT });
  });

  // Underlined links — offset + color deepen on hover
  document.querySelectorAll('.ui-git, .modal-link').forEach((link) => {
    hover(link, () => {
      animate(link, { textUnderlineOffset: '0.28em', textDecorationColor: 'rgba(0,0,0,1)' }, { duration: 0.2, ease: EASE_OUT });
      return () => animate(link, { textUnderlineOffset: '0.15em', textDecorationColor: 'rgba(0,0,0,0.2)' }, { duration: 0.2, ease: EASE_OUT });
    });
    press(link, () => {
      animate(link, { scale: 0.98 }, SPRING_PRESS);
      return () => animate(link, { scale: 1 }, SPRING_BACK);
    });
  });
}

/* ── Download modal — spring slide from the top-right trigger ── */
function wireModal() {
  const { animate } = M;
  const trigger  = document.getElementById('downloadBtn');
  const modal    = document.getElementById('downloadModal');
  const backdrop = document.getElementById('modalBackdrop');
  const closeBtn = document.getElementById('modalClose');
  const reveals  = modal.querySelectorAll('.m-reveal');
  let isOpen = false;
  let lastFocus = null;

  function open(e) {
    if (e) e.preventDefault();
    if (isOpen) return;
    isOpen = true;
    lastFocus = document.activeElement;
    modal.hidden = false;
    backdrop.hidden = false;
    trigger.setAttribute('aria-expanded', 'true');

    if (REDUCE) {
      backdrop.style.opacity = 1;
      modal.style.transform = 'none';
      modal.style.opacity = 1;
    } else {
      animate(backdrop, { opacity: [0, 1] }, { duration: 0.35, ease: EASE_OUT });
      animate(modal, { x: ['110%', '0%'], scale: [0.98, 1], opacity: [0, 1] }, MODAL_IN);
      reveals.forEach((el, i) =>
        animate(
          el,
          { opacity: [0, 1], y: [12, 0], filter: ['blur(6px)', 'blur(0px)'] },
          { duration: 0.5, ease: EASE_OUT, delay: 0.14 + i * 0.06 }
        )
      );
      // QR materialises with DopeDrop's wavefront reveal (style 0 = AURORA)
      const qr = document.getElementById('qrImage');
      if (qr) revealImage(qr, { duration: 1500 });
    }
    document.addEventListener('keydown', onKey);
    closeBtn.focus({ preventScroll: true });
  }

  function close() {
    if (!isOpen) return;
    isOpen = false;
    trigger.setAttribute('aria-expanded', 'false');
    document.removeEventListener('keydown', onKey);

    const finish = () => {
      if (isOpen) return;            // a re-open raced us — don't hide
      modal.hidden = true;
      backdrop.hidden = true;
    };

    if (REDUCE) {
      finish();
    } else {
      animate(backdrop, { opacity: 0 }, { duration: 0.28, ease: EASE_IN });
      const a = animate(modal, { x: '110%', scale: 0.98, opacity: 0 }, MODAL_OUT);
      Promise.resolve(a.finished || a).then(finish).catch(() => {});
    }
    if (lastFocus && lastFocus.focus) lastFocus.focus({ preventScroll: true });
  }

  function onKey(e) {
    if (e.key === 'Escape') { close(); return; }
    if (e.key === 'Tab') {           // contain focus between the two focusables
      const first = closeBtn;
      const last = modal.querySelector('.modal-link');
      if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
      else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
    }
  }

  trigger.addEventListener('click', open);
  closeBtn.addEventListener('click', close);
  backdrop.addEventListener('click', close);
}

/* ── No-Motion fallback (CDN unreachable): plain show/hide ── */
function wireModalFallback() {
  const trigger  = document.getElementById('downloadBtn');
  const modal    = document.getElementById('downloadModal');
  const backdrop = document.getElementById('modalBackdrop');
  const closeBtn = document.getElementById('modalClose');

  const show = (e) => {
    if (e) e.preventDefault();
    modal.hidden = false; backdrop.hidden = false;
    modal.style.transform = 'none'; modal.style.opacity = '1';
    backdrop.style.opacity = '1';
    trigger.setAttribute('aria-expanded', 'true');
    const qr = document.getElementById('qrImage');
    if (qr) revealImage(qr, { duration: 1500 });
  };
  const hide = () => {
    modal.hidden = true; backdrop.hidden = true;
    trigger.setAttribute('aria-expanded', 'false');
  };
  trigger.addEventListener('click', show);
  closeBtn.addEventListener('click', hide);
  backdrop.addEventListener('click', hide);
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape') hide(); });
}
