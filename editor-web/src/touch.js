// Touch support for the editor's tappable widgets (iPhone / iPad host).
//
// The live-preview widgets (task checkboxes, [[wiki links]], embed titles,
// slash-menu items) act on `mousedown`, which is right for the Mac. On a
// touch screen WebKit only synthesizes that mousedown after the tap gesture
// resolves, and the same tap also moves the caret into the line (revealing
// the raw markdown and popping the keyboard) — so a tap on a checkbox could
// open the keyboard instead of ticking it.
//
// `addTouchTap(el)` makes a short, still tap on `el` behave exactly like a
// click on the Mac: it cancels the tap's default handling (caret move,
// keyboard, the compatibility mouse events) and re-dispatches a `mousedown`
// to the element, so the widget's existing handler runs unchanged. Drags /
// scrolls (movement past TAP_SLOP) and multi-touch are left alone. On the Mac
// no touch events fire, so behaviour there is untouched.

const TAP_SLOP = 10; // px a finger may wander and still count as a tap

export function addTouchTap(el) {
  let start = null;

  el.addEventListener(
    "touchstart",
    (e) => {
      if (e.touches.length !== 1) {
        start = null;
        return;
      }
      const t = e.touches[0];
      start = { id: t.identifier, x: t.clientX, y: t.clientY };
    },
    { passive: true }
  );

  el.addEventListener(
    "touchmove",
    (e) => {
      if (!start) return;
      for (const t of e.changedTouches) {
        if (t.identifier !== start.id) continue;
        if (Math.abs(t.clientX - start.x) > TAP_SLOP || Math.abs(t.clientY - start.y) > TAP_SLOP) {
          start = null;
        }
      }
    },
    { passive: true }
  );

  el.addEventListener("touchcancel", () => {
    start = null;
  });

  el.addEventListener(
    "touchend",
    (e) => {
      const began = start;
      start = null;
      if (!began || e.touches.length !== 0) return;
      const t = Array.from(e.changedTouches).find((c) => c.identifier === began.id);
      if (!t) return;
      if (Math.abs(t.clientX - began.x) > TAP_SLOP || Math.abs(t.clientY - began.y) > TAP_SLOP) return;
      e.preventDefault();
      el.dispatchEvent(
        new MouseEvent("mousedown", {
          bubbles: false,
          cancelable: true,
          clientX: t.clientX,
          clientY: t.clientY,
          button: 0,
        })
      );
    },
    { passive: false }
  );
}
