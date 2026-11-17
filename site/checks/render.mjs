// Renders SVG files to PNG with the Playwright these checks already pin (issue #373): the blog's chart images,
// for the places that do not show inline SVG (dev.to, Medium, LinkedIn), and the kit's images.
//
//   node site/checks/render.mjs <width>x<height> <in.svg> <out.png> [<in.svg> <out.png> ...]
//
// Each SVG is drawn alone on a page of exactly that size, with JavaScript off and every request refused, so
// an image can neither run code nor fetch anything: what is drawn is what the file holds. Run by
// `mix malachi.release.post --images`; locally only, never in CI.
import { readFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";

export function parseArgs(argv) {
  const [size, ...files] = argv;
  const match = /^(\d{2,5})x(\d{2,5})$/.exec(size ?? "");
  if (!match || files.length === 0 || files.length % 2 !== 0) {
    throw new Error("usage: node site/checks/render.mjs <width>x<height> <in.svg> <out.png> [...]");
  }
  const pairs = [];
  for (let i = 0; i < files.length; i += 2) {
    if (!files[i].endsWith(".svg") || !files[i + 1].endsWith(".png")) {
      throw new Error(`expected an .svg then a .png, got ${files[i]} ${files[i + 1]}`);
    }
    pairs.push({ svg: files[i], png: files[i + 1] });
  }
  return { width: Number(match[1]), height: Number(match[2]), pairs };
}

// The page around one SVG: nothing but the image, at the page's own size, on no margin.
export function page(svg) {
  return `<!doctype html><html><head><meta charset="utf-8"><style>html,body{margin:0;padding:0}svg{display:block}</style></head><body>${svg}</body></html>`;
}

async function main() {
  const { width, height, pairs } = parseArgs(process.argv.slice(2));
  // Loaded here, not at the top, so the functions above can be tested without the browser installed.
  const { chromium } = await import("playwright");
  const browser = await chromium.launch();
  try {
    const context = await browser.newContext({ viewport: { width, height }, javaScriptEnabled: false });
    await context.route("**/*", (route) => route.abort());
    const tab = await context.newPage();
    for (const { svg, png } of pairs) {
      await tab.setContent(page(await readFile(svg, "utf8")), { waitUntil: "load" });
      await tab.screenshot({ path: png, clip: { x: 0, y: 0, width, height } });
      console.log(`rendered ${png}`);
    }
  } finally {
    await browser.close();
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    console.error(error.message);
    process.exit(1);
  });
}
