// Copies non-TS assets into dist/ after tsc has emitted JS.
// MV3 loads everything from a single dir, so manifest, HTML, CSS, and
// the bundled fonts have to land alongside the compiled JS.
import { cpSync, existsSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const dist = resolve(root, "dist");
mkdirSync(dist, { recursive: true });

const assets = [
  ["manifest.json", "manifest.json"],
  ["src/sidepanel.html", "sidepanel.html"],
  ["src/style.css", "style.css"],
];

for (const [from, to] of assets) {
  cpSync(resolve(root, from), resolve(dist, to));
  console.log(`copied ${from} -> dist/${to}`);
}

// Bundle Berkeley Mono from the user's installed fonts. The font is
// paid/licensed; we don't check the .ttf files into git. The komarchy
// migration script (group 005, fnt-pkg.sh) installs them into
// ~/.local/share/fonts/ — we copy from there at build time so the
// extension is self-contained at load time without depending on
// chromium's host font enumeration (which caches on startup and
// doesn't notice newly installed fonts until restart).
const fontsSrc = resolve(homedir(), ".local/share/fonts");
const fontsDest = resolve(dist, "fonts");
mkdirSync(fontsDest, { recursive: true });

const fontFiles = [
  "BerkeleyMono-Regular.ttf",
  "BerkeleyMono-Bold.ttf",
  "BerkeleyMono-Oblique.ttf",
  "BerkeleyMono-Bold-Oblique.ttf",
];

let missing = 0;
for (const f of fontFiles) {
  const src = resolve(fontsSrc, f);
  if (!existsSync(src)) {
    console.warn(`font not found, skipping: ${src}`);
    missing++;
    continue;
  }
  cpSync(src, resolve(fontsDest, f));
  console.log(`copied font ${f} -> dist/fonts/${f}`);
}
if (missing === fontFiles.length) {
  console.warn(
    "no Berkeley Mono fonts found; extension will fall back to system monospace",
  );
}
