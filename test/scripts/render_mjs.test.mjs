// Unit tests for site/checks/render.mjs (#373), run by test/scripts/render_mjs_test.exs with `node --test`.
// Only its pure functions: drawing needs the browser, which these tests do not install.
import test from "node:test";
import assert from "node:assert/strict";
import { parseArgs, page } from "../../site/checks/render.mjs";

test("reads the size and the svg and png pairs", () => {
  assert.deepEqual(parseArgs(["1200x630", "a.svg", "a.png", "b.svg", "b.png"]), {
    width: 1200,
    height: 630,
    pairs: [
      { svg: "a.svg", png: "a.png" },
      { svg: "b.svg", png: "b.png" },
    ],
  });
});

test("refuses a missing or malformed size, an odd file list, and a pair in the wrong order", () => {
  for (const argv of [[], ["1200x630"], ["big", "a.svg", "a.png"], ["1200x630", "a.svg"], ["1200x630", "a.png", "a.svg"], ["1x1", "a.svg", "a.png"]]) {
    assert.throws(() => parseArgs(argv), /usage|expected an \.svg/, JSON.stringify(argv));
  }
});

test("the page holds the image alone, with no margin", () => {
  const html = page("<svg></svg>");
  assert.match(html, /^<!doctype html>/);
  assert.match(html, /margin:0/);
  assert.match(html, /<body><svg><\/svg><\/body>/);
});
