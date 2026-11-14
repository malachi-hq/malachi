// Browser check for the dashboard under its Content-Security-Policy (#38): the policy forbids inline script and
// style, so a handler or a style left inline would stop working without an error anywhere but the browser. This
// drives the real pages against a running node and fails on any CSP violation the browser reports, on any
// uncaught page error, and on any step that does not do what it should.
//
//   DASHBOARD_PASS=... [DASHBOARD_USER=admin] node dashboard.mjs <dashboard url> <topic>
//
// The password comes from the environment, never from argv, where every local process can read it (#180). The
// topic must exist on the node: the drill-down needs one to expand. Each check prints one line; any failure exits
// 1, so the CI step fails. Runs on Linux only, like every Malachi measurement.
import { chromium } from "playwright";

const [base, topic] = process.argv.slice(2);
const user = process.env.DASHBOARD_USER || "admin";
const pass = process.env.DASHBOARD_PASS;

if (!base || !topic || !pass) {
  console.error("usage: DASHBOARD_PASS=... [DASHBOARD_USER=admin] node dashboard.mjs <dashboard url> <topic>");
  process.exit(2);
}

const STEP_TIMEOUT_MS = 15_000;
const failures = [];
const violations = [];
const pageErrors = [];

function report(name, ok, detail = "") {
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${detail ? `: ${detail}` : ""}`);
  if (!ok) failures.push(name);
}

// Runs one step; a step that throws (a timeout, a missing element) is a failure with its message, and the
// remaining steps still run so one run reports every broken behavior.
async function step(name, fn) {
  try {
    const detail = await fn();
    report(name, true, detail || "");
  } catch (error) {
    report(name, false, error.message.split("\n")[0]);
  }
}

const browser = await chromium.launch();

try {
  const context = await browser.newContext();
  // Every document reports its violations here, the login page and the dashboard alike.
  await context.exposeFunction("__reportCspViolation", (v) => violations.push(v));
  await context.addInitScript(() => {
    document.addEventListener("securitypolicyviolation", (e) => {
      window.__reportCspViolation(`${e.violatedDirective} blocked ${e.blockedURI || "inline"} (${e.sourceFile || "page"}:${e.lineNumber})`);
    });
  });

  const page = await context.newPage();
  page.setDefaultTimeout(STEP_TIMEOUT_MS);
  page.on("pageerror", (error) => pageErrors.push(error.message));
  // Chromium also logs a refused resource to the console; a violation reported only there still counts.
  page.on("console", (msg) => {
    if (msg.type() === "error" && /Content Security Policy|Refused to/i.test(msg.text())) violations.push(msg.text());
  });

  await step("an anonymous visit is sent to the login page", async () => {
    await page.goto(`${base}/`);
    await page.waitForURL(`${base}/login`);
  });

  await step("the login page is styled by app.css", async () => {
    const display = await page.evaluate(() => getComputedStyle(document.body).display);
    if (display !== "flex") throw new Error(`body display is ${display}, expected flex`);
    const logo = await page.locator("img.brand-logo").evaluate((el) => getComputedStyle(el).height);
    if (logo !== "48px") throw new Error(`login logo height is ${logo}, expected 48px`);
  });

  await step("a wrong password shows the error from login.js", async () => {
    await page.fill("#username", user);
    await page.fill("#password", `${pass}-wrong`);
    await page.click("#loginBtn");
    await page.locator("#error.show").waitFor();
    const text = await page.locator("#error").textContent();
    if (text !== "Invalid username or password") throw new Error(`error reads ${JSON.stringify(text)}`);
    if (await page.locator("#loginBtn").isDisabled()) throw new Error("the button stayed disabled");
  });

  await step("the right password logs in and lands on the dashboard", async () => {
    await page.fill("#password", pass);
    await page.click("#loginBtn");
    await page.waitForURL(`${base}/`);
  });

  await step("the dashboard is styled by app.css", async () => {
    const logo = await page.locator("img.brand-logo").evaluate((el) => getComputedStyle(el).height);
    if (logo !== "42px") throw new Error(`dashboard logo height is ${logo}, expected 42px`);
    const cards = await page.locator(".card").first().evaluate((el) => getComputedStyle(el).borderRadius);
    if (cards !== "8px") throw new Error(`card border radius is ${cards}, expected 8px`);
  });

  await step("the live stream fills the system status", async () => {
    await page.waitForFunction(() => document.getElementById("processes").textContent !== "-");
    const memory = await page.locator("#memory").textContent();
    if (!/ MB$/.test(memory)) throw new Error(`memory reads ${JSON.stringify(memory)}`);
    return `processes ${await page.locator("#processes").textContent()}, memory ${memory}`;
  });

  const header = page.locator(".topic-header", { hasText: topic });

  await step("a click on the topic expands its ranges", async () => {
    await header.waitFor();
    await header.click();
    await page.locator(".topic-card", { hasText: topic }).locator(".range-block").first().waitFor();
    // The stream re-renders every second; the expansion has to survive it.
    await page.waitForTimeout(1_500);
    await page.locator(".topic-card", { hasText: topic }).locator(".range-block").first().waitFor();
  });

  await step("a click on the expanded topic collapses it", async () => {
    await header.click();
    await page.locator(".topic-card", { hasText: topic }).locator(".topic-detail").waitFor({ state: "detached" });
  });

  await step("logout returns to the login page", async () => {
    await page.click(".logout-btn");
    await page.waitForURL(`${base}/login`);
  });

  report("no Content-Security-Policy violation", violations.length === 0, violations.join(" | "));
  report("no uncaught page error", pageErrors.length === 0, pageErrors.join(" | "));
} finally {
  await browser.close();
}

if (failures.length > 0) {
  console.error(`${failures.length} dashboard check(s) failed: ${failures.join(", ")}`);
  process.exit(1);
}
