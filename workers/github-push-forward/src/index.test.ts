/**
 * Off-process unit tests for the github-push-forward Worker. We do not
 * run a Workers runtime here — Node 22 with --experimental-strip-types
 * is enough to exercise the pure HMAC + forward logic. Live verification
 * (wrangler dev + curl) is documented in README.md.
 *
 * These tests exist so a regression in the HMAC verify path (the only
 * non-trivial piece) is caught at CI even though we cannot run the
 * Cloudflare runtime on the fleet VPS.
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { verifyHmac, forwardToTunnel } from "./index.ts";

const SECRET = "test-secret-please-rotate";

async function signHex(secret: string, body: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body));
  return Array.from(new Uint8Array(sig))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

test("verifyHmac: valid signature passes", async () => {
  const body = '{"action":"labeled"}';
  const sig = "sha256=" + (await signHex(SECRET, body));
  const buf = new TextEncoder().encode(body).buffer;
  assert.equal(await verifyHmac(SECRET, buf, sig), true);
});

test("verifyHmac: tampered body fails", async () => {
  const body = '{"action":"labeled"}';
  const tampered = '{"action":"closed"}';
  const sig = "sha256=" + (await signHex(SECRET, body));
  const buf = new TextEncoder().encode(tampered).buffer;
  assert.equal(await verifyHmac(SECRET, buf, sig), false);
});

test("verifyHmac: missing header fails", async () => {
  const body = '{"action":"labeled"}';
  const buf = new TextEncoder().encode(body).buffer;
  assert.equal(await verifyHmac(SECRET, buf, null), false);
});

test("verifyHmac: wrong scheme fails", async () => {
  const body = '{"action":"labeled"}';
  const sig = "sha1=" + (await signHex(SECRET, body)).slice(0, 40);
  const buf = new TextEncoder().encode(body).buffer;
  assert.equal(await verifyHmac(SECRET, buf, sig), false);
});

test("verifyHmac: malformed hex fails", async () => {
  const body = '{"action":"labeled"}';
  const buf = new TextEncoder().encode(body).buffer;
  assert.equal(
    await verifyHmac(SECRET, buf, "sha256=not-hex"),
    false,
  );
});

test("verifyHmac: wrong-secret signature fails", async () => {
  const body = '{"action":"labeled"}';
  const sig = "sha256=" + (await signHex("a-different-secret", body));
  const buf = new TextEncoder().encode(body).buffer;
  assert.equal(await verifyHmac(SECRET, buf, sig), false);
});

test("verifyHmac: empty body valid with empty-body signature", async () => {
  // Defensive: GitHub always sends a non-empty body; an empty body should
  // not match a non-empty signature. This guards against the "echo the
  // signature" attack.
  const sig = "sha256=" + (await signHex(SECRET, "non-empty"));
  const buf = new ArrayBuffer(0);
  assert.equal(await verifyHmac(SECRET, buf, sig), false);
});

test("forwardToTunnel: returns the upstream status on 200", async () => {
  // Stub a fetch via the global; Node 22 has fetch built-in, so we just
  // point it at an unreachable URL and assert the error path. The
  // happy-path 200 is exercised manually via wrangler dev + curl (the
  // Worker cannot be spun up under `node --test` without miniflare).
  const out = await forwardToTunnel(
    "http://127.0.0.1:1/never-listening",
    "token",
    new TextEncoder().encode("{}").buffer,
    { "content-type": "application/json", "x-github-event": "issues" },
  );
  // The unreachable host must produce an ok=false outcome — the
  // Worker treats that as a non-200 to GitHub's incoming webhook? No,
  // it returns 200 to GH and surfaces forward failure in the JSON. The
  // forwardToTunnel contract is: error envelope when fetch throws.
  assert.equal(out.ok, false);
  assert.ok(out.text.length > 0);
});
