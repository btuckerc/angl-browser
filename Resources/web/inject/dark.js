// Appended after darkreader.js in angl's isolated world, main frame only.
// __ANGL_DARK_MODE__ is "force" (convert now) or "auto" (convert only light pages without a
// dark theme of their own). Dark Reader is MIT licensed (darkreader.LICENSE).
(() => {
  const mode = "__ANGL_DARK_MODE__";
  const theme = { brightness: 100, contrast: 95, sepia: 0 };
  if (mode === "force") {
    DarkReader.enable(theme);
    return;
  }
  const luminance = (color) => {
    const m = color.match(/rgba?\(([\d.]+),\s*([\d.]+),\s*([\d.]+)(?:,\s*([\d.]+))?/);
    if (!m) return null;
    if (m[4] !== undefined && Number(m[4]) < 0.1) return null; // transparent: look further
    const [r, g, b] = [m[1], m[2], m[3]].map((v) => Number(v) / 255);
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
  };
  const pageIsLight = () => {
    for (const el of [document.body, document.documentElement]) {
      if (!el) continue;
      const l = luminance(getComputedStyle(el).backgroundColor);
      if (l !== null) return l > 0.5;
    }
    // No background anywhere = the default canvas. In dark appearance WebKit paints it dark only
    // when the page opts into color-scheme dark.
    const scheme = getComputedStyle(document.documentElement).colorScheme || "";
    return !scheme.includes("dark");
  };
  const check = () => {
    if (pageIsLight()) DarkReader.enable(theme);
  };
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", check, { once: true });
  } else {
    check();
  }
})();
