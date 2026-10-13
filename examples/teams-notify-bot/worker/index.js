// Cloudflare Worker: Teams bot receiver (bootstrap-only).
// On the user's first message to the bot, validate the Bot Framework
// signed JWT, extract the conversation reference, and store it in KV.
// The /conv-ref endpoint lets the local fetch-conv-ref.sh pull the
// cached reference for steady-state use.

const BF_OPENID_URL = "https://login.botframework.com/v1/.well-known/openidconfiguration";

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    if (request.method === "GET" && url.pathname === "/conv-ref") {
      return handleFetchConvRef(request, env);
    }
    if (request.method === "POST" && url.pathname === "/api/messages") {
      return handleBotMessage(request, env);
    }
    return new Response("Not found", { status: 404 });
  },
};

async function handleFetchConvRef(request, env) {
  const provided = request.headers.get("X-Setup-Secret") || "";
  if (provided !== env.SETUP_SECRET) {
    return new Response("Forbidden", { status: 403 });
  }
  const ref = await env.CONV_REF.get("conv-ref");
  if (!ref) {
    return new Response("No conversation reference cached yet", { status: 404 });
  }
  return new Response(ref, {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
}

async function handleBotMessage(request, env) {
  const auth = request.headers.get("Authorization") || "";
  if (!auth.startsWith("Bearer ")) {
    return new Response("Missing bearer", { status: 401 });
  }
  const token = auth.slice(7);

  // Read body first so we can bind token to activity.serviceUrl.
  const activity = await request.json();

  // Validate JWT: signature + iss + aud + exp + serviceUrl trust binding.
  const valid = await validateBotFrameworkToken(token, env, activity);
  if (!valid) {
    return new Response("Invalid token", { status: 401 });
  }
  // Only persist on the bootstrap "hi" — type=message OR type=conversationUpdate
  if (activity.type === "message" || activity.type === "conversationUpdate") {
    const ref = {
      conversationId: activity.conversation && activity.conversation.id,
      serviceUrl: activity.serviceUrl,
      tenantId: (activity.channelData && activity.channelData.tenant && activity.channelData.tenant.id) || null,
      user: activity.from ? {
        aadObjectId: activity.from.aadObjectId || null,
        name: activity.from.name || null,
        id: activity.from.id || null,
      } : null,
      capturedAt: new Date().toISOString(),
    };
    if (ref.conversationId && ref.serviceUrl) {
      await env.CONV_REF.put("conv-ref", JSON.stringify(ref, null, 2));
    }
  }

  // Outbound-only bot: respond 200 + empty body. No echo.
  return new Response("", { status: 200 });
}

// Allowlist of trusted Microsoft Bot Connector service URL hosts.
// Source: Microsoft Learn — "Authentication for bots" trusted service URLs.
// Public Microsoft cloud only. Sovereign clouds (US Gov, China) use different
// hosts (e.g. *.gov-trafficmanager.net) — adjust this list before deploy.
const TRUSTED_SERVICE_URL_HOSTS = [
  "smba.trafficmanager.net",       // Teams (all regions, public cloud)
  "webchat.botframework.com",      // Web Chat
  "directline.botframework.com",   // Direct Line
];

function isTrustedServiceUrl(url) {
  if (!url || typeof url !== "string") return false;
  let parsed;
  try { parsed = new URL(url); } catch (e) { return false; }
  if (parsed.protocol !== "https:") return false;
  return TRUSTED_SERVICE_URL_HOSTS.some(h => parsed.host === h || parsed.host.endsWith("." + h));
}

async function validateBotFrameworkToken(token, env, activity) {
  // Decode header to find kid.
  const parts = token.split(".");
  if (parts.length !== 3) return false;
  let header;
  try {
    header = JSON.parse(atob(parts[0].replace(/-/g, "+").replace(/_/g, "/")));
  } catch (e) {
    return false;
  }

  // Fetch + cache the OpenID config and JWKS.
  const oidc = await fetch(BF_OPENID_URL).then(r => r.json());
  const jwks = await fetch(oidc.jwks_uri).then(r => r.json());
  const jwk = jwks.keys.find(k => k.kid === header.kid);
  if (!jwk) return false;

  // Verify signature using Web Crypto API.
  const key = await crypto.subtle.importKey(
    "jwk",
    { kty: jwk.kty, n: jwk.n, e: jwk.e, alg: "RS256", ext: true },
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["verify"],
  );
  const sigBytes = base64UrlDecode(parts[2]);
  const data = new TextEncoder().encode(parts[0] + "." + parts[1]);
  const ok = await crypto.subtle.verify("RSASSA-PKCS1-v1_5", key, sigBytes, data);
  if (!ok) return false;

  // Check claims.
  const claims = JSON.parse(atob(parts[1].replace(/-/g, "+").replace(/_/g, "/")));
  if (claims.iss !== oidc.issuer) return false;
  if (claims.aud !== env.BOT_APP_ID) return false;
  if (claims.exp * 1000 < Date.now()) return false;

  // serviceUrl trust binding (Microsoft Learn:
  // https://learn.microsoft.com/azure/bot-service/rest-api/bot-framework-rest-connector-authentication
  // — "Step 4: Verify the serviceurl claim"). For tokens that carry a serviceurl
  // claim, the value must match activity.serviceUrl. The activity.serviceUrl
  // itself must always resolve to a trusted Microsoft Bot Connector host.
  if (!isTrustedServiceUrl(activity && activity.serviceUrl)) return false;
  if (claims.serviceurl && claims.serviceurl !== activity.serviceUrl) return false;

  return true;
}

function base64UrlDecode(s) {
  const pad = s.length % 4 === 0 ? "" : "=".repeat(4 - (s.length % 4));
  const b64 = (s + pad).replace(/-/g, "+").replace(/_/g, "/");
  const bin = atob(b64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes;
}
