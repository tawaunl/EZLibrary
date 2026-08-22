/* Shared helpers for the roadmap's write functions.

   Design note — why the GitHub token never reaches the browser:

   The public site is static (GitHub Pages), so it can't hold the OAuth client
   secret and can't be trusted with a long-lived GitHub token. These functions
   do the OAuth code exchange server-side, then hand the browser an *encrypted*
   session blob (AES-GCM, keyed off SESSION_SECRET). The browser stores that
   opaque blob and sends it back on every write; only these functions can
   decrypt it to recover the GitHub token. A stolen blob is useless anywhere
   except against this deployment, and it can't be replayed to GitHub directly.

   No cookies are used on purpose: the site and these functions live on
   different origins, and Safari's third-party cookie blocking would break a
   cookie-based session. An Authorization header + CORS works everywhere. */

const encoder = new TextEncoder();
const decoder = new TextDecoder();

export function env(name, fallback) {
  const value = process.env[name];
  return value === undefined || value === "" ? fallback : value;
}

export const REPO = env("ROADMAP_REPO", "tawaunl/EZLibrary");

/* Comma-separated list of origins allowed to call these functions. */
function allowedOrigins() {
  return env("ALLOWED_ORIGIN", "https://tawaunl.github.io")
    .split(",")
    .map((origin) => origin.trim())
    .filter(Boolean);
}

function corsHeaders(requestOrigin) {
  const allowed = allowedOrigins();
  const origin =
    requestOrigin && allowed.indexOf(requestOrigin) !== -1
      ? requestOrigin
      : allowed[0] || "*";
  return {
    "Access-Control-Allow-Origin": origin,
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type, Authorization",
    "Access-Control-Max-Age": "86400",
    Vary: "Origin"
  };
}

export function json(body, status, requestOrigin) {
  return new Response(JSON.stringify(body), {
    status: status || 200,
    headers: {
      "Content-Type": "application/json",
      ...corsHeaders(requestOrigin)
    }
  });
}

export function preflight(request) {
  return new Response(null, {
    status: 204,
    headers: corsHeaders(request.headers.get("origin"))
  });
}

/* ------------------------------------------------------------ session seal */

async function sessionKey() {
  const secret = env("SESSION_SECRET");
  if (!secret) throw new Error("SESSION_SECRET is not configured");
  const digest = await crypto.subtle.digest("SHA-256", encoder.encode(secret));
  return crypto.subtle.importKey("raw", digest, { name: "AES-GCM" }, false, [
    "encrypt",
    "decrypt"
  ]);
}

function toBase64Url(bytes) {
  let binary = "";
  for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function fromBase64Url(text) {
  const padded = text.replace(/-/g, "+").replace(/_/g, "/");
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

export async function seal(payload) {
  const key = await sessionKey();
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const cipher = new Uint8Array(
    await crypto.subtle.encrypt(
      { name: "AES-GCM", iv },
      key,
      encoder.encode(JSON.stringify(payload))
    )
  );
  const out = new Uint8Array(iv.length + cipher.length);
  out.set(iv, 0);
  out.set(cipher, iv.length);
  return toBase64Url(out);
}

export async function unseal(token) {
  const key = await sessionKey();
  const raw = fromBase64Url(token);
  const plain = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: raw.slice(0, 12) },
    key,
    raw.slice(12)
  );
  return JSON.parse(decoder.decode(plain));
}

/* Pull and verify the session from the Authorization header. Returns the
   decrypted payload ({ token, login, at }) or null. */
export async function sessionFrom(request) {
  const header = request.headers.get("authorization") || "";
  const match = header.match(/^Bearer\s+(.+)$/i);
  if (!match) return null;
  try {
    const payload = await unseal(match[1]);
    if (!payload || !payload.token) return null;
    return payload;
  } catch (error) {
    return null;
  }
}

/* ------------------------------------------------------------- GitHub call */

export function gh(path, token, options) {
  const opts = options || {};
  return fetch("https://api.github.com" + path, {
    ...opts,
    headers: {
      Accept: "application/vnd.github+json",
      Authorization: "Bearer " + token,
      "User-Agent": "EZLibrary-Roadmap",
      "X-GitHub-Api-Version": "2022-11-28",
      ...(opts.headers || {})
    }
  });
}
