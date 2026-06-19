// KaTeX stylesheet, imported as a text string by esbuild (loader:.css=text) with
// the woff2/woff/ttf fonts inlined as data URLs (loader:.woff2=dataurl …). We
// inject it into a <style> at runtime so KaTeX renders fully offline inside the
// WKWebView — no font files need to ship alongside the bundle.
import css from "katex/dist/katex.min.css";

export function injectKatexCSS() {
  if (document.getElementById("scribe-katex-css")) return;
  const style = document.createElement("style");
  style.id = "scribe-katex-css";
  style.textContent = css;
  document.head.appendChild(style);
}
