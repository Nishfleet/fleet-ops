#!/usr/bin/env node
// lib/scout-money-path-walk.mjs — nightly money-path walk (fleet-ops#3149)
//
// Drives https://0509.io through search -> result -> pricing -> signup start
// in FRESH sessions (new browser context, no stored auth) at MOBILE + DESKTOP
// viewports, using the Playwright package ALREADY installed in the 0509
// checkout (0509_DIR env var). No new browser harness.
//
// Output: a markdown findings block on stdout — per-viewport per-step status,
// console errors, dead-CTA probes, visible copy, and a findings list CAPPED at
// 4 entries, each carrying a `evidence: <screenshot path>` line the scout
// copies into filed candidates.
//
// Screenshots: written under OUTDIR (default ./scout-money-path/<ts>).
//
// Exit: 0 on completion (zero findings is a green walk), 1 only on
// infrastructure failure (0509 playwright/browser unavailable). Best-effort:
// a broken step is a FINDING, not a crash — the scout converts findings.

import { createRequire } from "module";
import { fileURLToPath } from "url";
import path from "path";
import fs from "fs";

const here = path.dirname(fileURLToPath(import.meta.url));
const baseUrl = process.env.WALK_BASE_URL || "https://0509.io";
const outdir = path.resolve(process.env.OUTDIR || path.join(here, "..", "scout-money-path"));

const require0517 = createRequire(
  path.join(process.env["0509_DIR"] || "/home/nish/workspaces/products/0509", "package.json")
);
let chromium;
try {
  ({ chromium } = require0517("playwright"));
} catch (err) {
  console.error(`scout-money-path-walk: cannot load playwright from 0509 checkout: ${err.message}`);
  process.exit(1);
}

const MAX_FINDINGS = 4;
const findings = [];

const viewports = [
  { name: "mobile", width: 390, height: 844, isMobile: true },
  { name: "desktop", width: 1280, height: 800, isMobile: false },
];

function addFinding(type, detail, evidence) {
  if (findings.length >= MAX_FINDINGS) return;
  findings.push({ type, detail, evidence });
}

async function probeHref(page, href) {
  // Same-origin dead-link probe: a link that answers >= 400 is a dead CTA.
  try {
    if (href === "" || href === "#" || /^javascript:/i.test(href)) return "dead-placeholder";
    const target = new URL(href, baseUrl);
    if (target.origin !== new URL(baseUrl).origin) return null; // external: out of walk scope
    const resp = await page.request.get(target.href, { timeout: 20000, maxRetries: 1 });
    const code = resp ? resp.status() : null;
    // 429 = rate-limited (resource exists), not a dead CTA; exclude it so the
    // walk's own probing cannot throttle the money path or raise false alarms.
    if (code === 429) return null;
    return code >= 400 && code < 600 ? `http-${code}` : null;
  } catch {
    return null;
  }
}

async function walkViewport(browser, vp, out) {
  const context = await browser.newContext({
    viewport: { width: vp.width, height: vp.height },
    isMobile: vp.isMobile,
    locale: "en-US",
  });
  const page = await context.newPage();
  const consoleErrors = [];
  const probeCount = { n: 0 };

  page.on("console", (msg) => {
    if (msg.type() === "error") consoleErrors.push(msg.text().slice(0, 300));
  });
  page.on("pageerror", (err) => consoleErrors.push(`pageerror: ${String(err).slice(0, 300)}`));

  async function step(name, url, opts = {}) {
    const finalUrl = url;
    let status = null;
    let navErr = null;
    try {
      const resp = await page.goto(finalUrl, {
        waitUntil: opts.waitUntil || "domcontentloaded",
        timeout: 45000,
      });
      status = resp ? resp.status() : null;
    } catch (err) {
      navErr = String(err).slice(0, 300);
    }
    const shot = path.join(out, `${vp.name}-${name}.png`);
    try {
      await page.screenshot({ path: shot, fullPage: false });
    } catch {
      /* screenshot may fail on a broken page; finding still recorded */
    }
    // dead-CTA probe on the money-path CTAs only (bounded)
    let dead = [];
    if (!navErr) {
      try {
        const links = await page.$$eval("a[href]", (as) =>
          as.slice(0, 25).map((a) => ({
            text: (a.textContent || "").trim().replace(/\s+/g, " ").slice(0, 60),
            href: a.getAttribute("href") || "",
          }))
        );
        for (const l of links) {
          if (probeCount.n >= 10) break;
          probeCount.n += 1;
          const res = await probeHref(page, l.href);
          if (res) dead.push(`${res}: "${l.text || l.href}"`);
        }
      } catch {
        /* page may not be fully interactive; skip probes */
      }
    }
    const h1 = navErr
      ? ""
      : await page.locator("h1").first().textContent().catch(() => "");
    const copy = (h1 || "").trim().replace(/\s+/g, " ").slice(0, 160);

    const lines = [
      `#### ${vp.name} ${name}`,
      `- status: ${status === null ? "NAV-FAIL" : status}, url: ${finalUrl}${navErr ? ` (${navErr})` : ""}`,
      `- console_errors: ${JSON.stringify(consoleErrors.slice())}`,
      `- dead_cta: ${dead.length ? dead.join(" | ") : "none"}`,
      `- copy: "${copy}"`,
      `- evidence: ${shot}`,
      "",
    ].join("\n");
    process.stdout.write(lines + "\n");

    if (navErr) addFinding(`broken-step:${name}`, `${vp.name} could not reach ${finalUrl}: ${navErr}`, shot);
    if (status !== null && status >= 400) addFinding(`broken-step:${name}`, `${vp.name} ${finalUrl} answered HTTP ${status}`, shot);
    consoleErrors.splice(0).forEach((c) => addFinding(`console-error:${name}`, `${vp.name}: ${c.slice(0, 200)}`, shot));
    dead.forEach((d) => addFinding(`dead-cta:${name}`, `${vp.name}: ${d}`, shot));
    consoleErrors.length = 0;
  }

  try {
    await step("search", `${baseUrl}/search?q=nike&country=all`);
    // result: follow the first search result link (money-path step 2) when
    // present. 0509 results are /search?mode=advertiser&...&selected=<id>#selected-proof
    let resultHref = null;
    try {
      resultHref = await page
        .locator('a[href*="mode=advertiser"][href*="selected="]')
        .first()
        .getAttribute("href")
        .catch(() => null);
    } catch {
      resultHref = null;
    }
    const notFoundShot = path.join(out, `${vp.name}-search.png`);
    if (resultHref) {
      const target = new URL(resultHref, baseUrl).href;
      await step("result", target);
    } else {
      addFinding(
        "dead-cta:search",
        `${vp.name}: no result link (mode=advertiser) on /search (result step unreachable)`,
        notFoundShot
      );
      await step("result-fallback", `${baseUrl}/search?mode=advertiser&query=nike&country=all&selected=example`).catch(() => {});
    }
    await step("pricing", `${baseUrl}/pricing`);
    await step("signup-start", `${baseUrl}/auth/signup`);
  } catch (err) {
    addFinding("walk-error", `${vp.name}: ${String(err).slice(0, 300)}`, path.join(out, `${vp.name}-search.png`));
  } finally {
    await context.close();
  }
}

try {
  fs.mkdirSync(outdir, { recursive: true });
  const browser = await chromium.launch({ headless: true });
  try {
    process.stdout.write(`### Money-path walk (fresh sessions: ${viewports.map((v) => v.name).join(", ")}) — ${baseUrl}\n\n`);
    for (const vp of viewports) {
      await walkViewport(browser, vp, outdir);
    }
    process.stdout.write(`## Money-path walk findings (max ${MAX_FINDINGS})\n\n`);
    if (findings.length === 0) {
      process.stdout.write("- none (all steps green)\n\n");
    } else {
      for (const f of findings) {
        process.stdout.write(`- [${f.type}] ${f.detail} — evidence: ${f.evidence}\n`);
      }
      process.stdout.write("\n");
    }
  } finally {
    await browser.close();
  }
} catch (err) {
  console.error(`scout-money-path-walk: infra failure: ${err.message}`);
  process.exit(1);
}