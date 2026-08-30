/**
 * github-push-forward — Cloudflare Worker.
 *
 * fleet-ops#1464: GitHub org webhook → Worker → Cloudflare Tunnel →
 * VPS gh-webhook-receiver. The Worker is dumb transport: verify HMAC,
 * forward the original body to the tunnel URL, return 200. All routing
 * logic stays on the VPS.
 *
 * Endpoints:
 *   POST *                       Primary ingress. Verifies HMAC, forwards.
 *   GET  /healthz                Liveness probe. No auth.
 *
 * Secrets (set with `wrangler secret put`):
 *   GITHUB_WEBHOOK_SECRET        Shared HMAC secret with the VPS.
 *   TUNNEL_FORWARD_TOKEN         Shared bearer token with the VPS-side
 *                                receiver, so the tunnel hop is
 *                                independently authenticated even though
 *                                the GH HMAC was already verified.
 *
 * Vars (commit-safe):
 *   TUNNEL_FORWARD_URL           Public URL of the Cloudflare Tunnel
 *                                that terminates at gh-webhook-receiver:
 *                                8088 on this VPS.
 */

export interface Env {
  GITHUB_WEBHOOK_SECRET: string;
  TUNNEL_FORWARD_TOKEN: string;
  TUNNEL_FORWARD_URL: string;
}

const FORWARD_TIMEOUT_MS = 5_000;
const MAX_BODY_BYTES = 1 * 1024 * 1024; // 1 MiB

function hexToBytes(hex: string): Uint8Array | null {
  if (hex.length % 2 !== 0) return null;
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < hex.length; i += 2) {
    const byte = Number.parseInt(hex.slice(i, i + 2), 16);
    if (Number.isNaN(byte)) return null;
    out[i / 2] = byte;
  }
  return out;
}

function timingSafeEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.byteLength !== b.byteLength) return false;
  let acc = 0;
  for (let i = 0; i < a.byteLength; i += 1) {
    acc |= a[i] ^ b[i];
  }
  return acc === 0;
}

export async function verifyHmac(
  secret: string,
  body: ArrayBuffer,
  signatureHeader: string | null,
): Promise<boolean> {
  if (!signatureHeader || !signatureHeader.startsWith("sha256=")) return false;
  const given = hexToBytes(signatureHeader.slice("sha256=".length).trim());
  if (!given) return false;
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign", "verify"],
  );
  const expect = new Uint8Array(
    await crypto.subtle.sign("HMAC", key, body),
  );
  return timingSafeEqual(given, expect);
}

export async function forwardToTunnel(
  url: string,
  token: string,
  body: ArrayBuffer,
  headers: Record<string, string>,
): Promise<{ ok: boolean; status: number; text: string }> {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), FORWARD_TIMEOUT_MS);
  try {
    const resp = await fetch(url, {
      method: "POST",
      body,
      // Replay the original GitHub headers; add the tunnel-internal
      // bearer so the VPS receiver can authenticate the tunnel hop
      // separately from the GH HMAC.
      headers: {
        "Content-Type": headers["content-type"] ?? "application/json",
        "X-GitHub-Event": headers["x-github-event"] ?? "",
        "X-GitHub-Delivery": headers["x-github-delivery"] ?? "",
        "X-Hub-Signature-256": headers["x-hub-signature-256"] ?? "",
        "X-Tunnel-Forward-Token": token,
        "X-Forwarded-By": "github-push-forward",
      },
      signal: ctrl.signal,
    });
    const text = await resp.text();
    return { ok: resp.ok, status: resp.status, text };
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    return { ok: false, status: 0, text: `forward error: ${msg}` };
  } finally {
    clearTimeout(timer);
  }
}

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/healthz") {
      return jsonResponse(200, {
        status: "ok",
        worker: "github-push-forward",
        tunnel_configured: Boolean(env.TUNNEL_FORWARD_URL),
      });
    }

    if (request.method !== "POST") {
      return jsonResponse(405, { error: "method_not_allowed" });
    }

    // Pull the body once so we can both verify and forward.
    const buf = await request.arrayBuffer();
    if (buf.byteLength > MAX_BODY_BYTES) {
      return jsonResponse(413, { error: "body_too_large" });
    }
    if (buf.byteLength === 0) {
      return jsonResponse(400, { error: "empty_body" });
    }

    const sig = request.headers.get("X-Hub-Signature-256");
    const ok = await verifyHmac(env.GITHUB_WEBHOOK_SECRET, buf, sig);
    if (!ok) {
      return jsonResponse(401, { error: "invalid_signature" });
    }

    const headerMap: Record<string, string> = {};
    request.headers.forEach((value, key) => {
      headerMap[key.toLowerCase()] = value;
    });

    if (!env.TUNNEL_FORWARD_URL) {
      // Misconfiguration — refuse to silently drop. A 503 surfaces the
      // misconfig fast without bouncing GH (which would retry forever).
      return jsonResponse(503, { error: "tunnel_url_not_configured" });
    }

    const fwd = await forwardToTunnel(
      env.TUNNEL_FORWARD_URL,
      env.TUNNEL_FORWARD_TOKEN,
      buf,
      headerMap,
    );

    // The Worker MUST return 200 to GitHub even if the tunnel hop
    // failed — re-deliveries from GH would re-trigger downstream units
    // (and the dead-man canary on the VPS already catches a sustained
    // forward failure). Log the error via Workers Tail so it is visible.
    if (!fwd.ok) {
      console.error(
        `forward_failed status=${fwd.status} text=${fwd.text.slice(0, 200)}`,
      );
      return jsonResponse(200, {
        accepted: true,
        forward: "failed",
        forward_status: fwd.status,
        note: "tunnel hop failed; deadman will page",
      });
    }

    return jsonResponse(200, {
      accepted: true,
      forward: "ok",
      forward_status: fwd.status,
    });
  },
};
