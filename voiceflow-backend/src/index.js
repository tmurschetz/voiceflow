/**
 * Voiceflow Accounts — key-issuing service ("Variante B").
 *
 * Flow:
 *   1. App:    POST /register   { name, email, deviceToken }        → pending
 *   2. Thomas: /admin page      approve / deny / revoke / reissue
 *   3. App:    GET  /status?token=…                                 → on approval
 *              the per-user OpenAI project key is returned EXACTLY ONCE and
 *              immediately removed from storage.
 *
 * Security model:
 *   - OPENAI_ADMIN_KEY (can create keys / spend money) exists ONLY here as a
 *     Cloudflare secret. It never reaches the app, the repo, or any response.
 *   - Each approved user gets an OWN OpenAI project + service-account key →
 *     blast radius = that user's quota; revocable individually.
 *   - deviceToken is a 256-bit random value generated on the user's Mac; it is
 *     the only credential for /status. No user enumeration: /status without a
 *     valid token reveals nothing.
 *   - Admin endpoints require ADMIN_TOKEN (Bearer). The /admin page itself is
 *     static HTML; the token lives only in the admin's browser sessionStorage.
 *   - Issued keys are stored only until delivered, then deleted (a stolen KV
 *     dump after delivery contains no usable user keys). OpenAI-side IDs are
 *     kept for revocation.
 *   - /register is rate-limited per IP (KV counter) against spam.
 */

const MAX_REGISTRATIONS_PER_IP_PER_DAY = 5;
const TOKEN_RE = /^[0-9a-f]{64}$/;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    try {
      if (request.method === "POST" && url.pathname === "/register") return await register(request, env);
      if (request.method === "GET"  && url.pathname === "/status")   return await status(request, env, url);
      if (request.method === "GET"  && url.pathname === "/admin")    return adminPage();
      if (url.pathname.startsWith("/admin/"))                        return await admin(request, env, url);
      return json({ error: "not_found" }, 404);
    } catch (e) {
      console.error("unhandled", e.stack || String(e));
      return json({ error: "internal" }, 500);
    }
  },
};

// ─── Registration (app) ───────────────────────────────────────────────────────

async function register(request, env) {
  const ip = request.headers.get("cf-connecting-ip") || "unknown";
  const rlKey = `rl:${ip}:${new Date().toISOString().slice(0, 10)}`;
  const used = parseInt((await env.REGISTRY.get(rlKey)) || "0", 10);
  if (used >= MAX_REGISTRATIONS_PER_IP_PER_DAY) return json({ error: "rate_limited" }, 429);
  await env.REGISTRY.put(rlKey, String(used + 1), { expirationTtl: 86400 });

  let body;
  try { body = await request.json(); } catch { return json({ error: "bad_json" }, 400); }
  const name  = clean(body.name, 80);
  const email = clean(body.email, 120);
  const token = String(body.deviceToken || "");
  if (!name || !email || !email.includes("@") || !TOKEN_RE.test(token)) {
    return json({ error: "invalid_fields" }, 400);
  }

  // Idempotent: an existing record is never overwritten (a re-register cannot
  // hijack an approved account's identity).
  const existing = await env.REGISTRY.get(recKey(token), "json");
  if (existing) return json({ status: existing.status });

  await env.REGISTRY.put(recKey(token), JSON.stringify({
    name, email,
    status: "pending",
    createdAt: new Date().toISOString(),
  }));
  return json({ status: "pending" });
}

// ─── Status polling + one-time key delivery (app) ─────────────────────────────

async function status(request, env, url) {
  const token = url.searchParams.get("token") || "";
  if (!TOKEN_RE.test(token)) return json({ error: "invalid_token" }, 400);

  const rec = await env.REGISTRY.get(recKey(token), "json");
  if (!rec) return json({ status: "unknown" });

  if (rec.status === "approved" && rec.pendingKey) {
    const key = rec.pendingKey;
    delete rec.pendingKey;                       // deliver exactly once
    rec.deliveredAt = new Date().toISOString();
    await env.REGISTRY.put(recKey(token), JSON.stringify(rec));
    return json({ status: "approved", apiKey: key }, 200, { "Cache-Control": "no-store" });
  }
  return json({ status: rec.status }, 200, { "Cache-Control": "no-store" });
}

// ─── Admin API (Thomas only) ──────────────────────────────────────────────────

async function admin(request, env, url) {
  if (!isAdmin(request, env)) return json({ error: "unauthorized" }, 401);
  if (request.method !== "POST") return json({ error: "method" }, 405);

  const action = url.pathname.slice("/admin/".length);
  if (action === "list") return adminList(env);

  let body;
  try { body = await request.json(); } catch { return json({ error: "bad_json" }, 400); }
  const token = String(body.token || "");
  if (!TOKEN_RE.test(token)) return json({ error: "invalid_token" }, 400);
  const rec = await env.REGISTRY.get(recKey(token), "json");
  if (!rec) return json({ error: "not_found" }, 404);

  switch (action) {
    case "approve": {
      if (rec.status !== "pending") return json({ error: "not_pending" }, 409);
      const issued = await issueKey(env, rec.name, rec.email);
      Object.assign(rec, {
        status: "approved", approvedAt: new Date().toISOString(),
        projectId: issued.projectId, serviceAccountId: issued.serviceAccountId,
        pendingKey: issued.apiKey,
      });
      await env.REGISTRY.put(recKey(token), JSON.stringify(rec));
      return json({ ok: true });
    }
    case "deny": {
      rec.status = "denied"; rec.deniedAt = new Date().toISOString();
      delete rec.pendingKey;
      await env.REGISTRY.put(recKey(token), JSON.stringify(rec));
      return json({ ok: true });
    }
    case "revoke": {
      if (rec.projectId) await destroyKey(env, rec);
      rec.status = "revoked"; rec.revokedAt = new Date().toISOString();
      delete rec.pendingKey;
      await env.REGISTRY.put(recKey(token), JSON.stringify(rec));
      return json({ ok: true });
    }
    case "reissue": {
      // Reinstall / lost Mac: kill the old key, park a fresh one for pickup.
      if (rec.status !== "approved" && rec.status !== "revoked") return json({ error: "not_approved" }, 409);
      if (rec.serviceAccountId) await destroyKey(env, rec, /*keepProject*/ true);
      const issued = await issueKey(env, rec.name, rec.email, rec.projectId);
      Object.assign(rec, {
        status: "approved",
        projectId: issued.projectId, serviceAccountId: issued.serviceAccountId,
        pendingKey: issued.apiKey, reissuedAt: new Date().toISOString(),
      });
      await env.REGISTRY.put(recKey(token), JSON.stringify(rec));
      return json({ ok: true });
    }
    default:
      return json({ error: "unknown_action" }, 404);
  }
}

async function adminList(env) {
  const out = [];
  let cursor;
  do {
    const page = await env.REGISTRY.list({ prefix: "req:", cursor });
    for (const k of page.keys) {
      const rec = await env.REGISTRY.get(k.name, "json");
      if (!rec) continue;
      out.push({
        token: k.name.slice(4),
        name: rec.name, email: rec.email, status: rec.status,
        createdAt: rec.createdAt, approvedAt: rec.approvedAt || null,
        deliveredAt: rec.deliveredAt || null,
        awaitingPickup: Boolean(rec.pendingKey),   // never the key itself
        projectId: rec.projectId || null,
      });
    }
    cursor = page.list_complete ? null : page.cursor;
  } while (cursor);
  out.sort((a, b) => (b.createdAt || "").localeCompare(a.createdAt || ""));
  return json({ users: out });
}

// ─── OpenAI Admin API ─────────────────────────────────────────────────────────

async function issueKey(env, name, email, existingProjectId) {
  if (env.TEST_MODE === "true") {
    return {
      projectId: existingProjectId || `proj_test_${crypto.randomUUID().slice(0, 8)}`,
      serviceAccountId: `svc_test_${crypto.randomUUID().slice(0, 8)}`,
      apiKey: `sk-test-${crypto.randomUUID().replaceAll("-", "")}`,
    };
  }

  let projectId = existingProjectId;
  if (!projectId) {
    const project = await openai(env, "POST", "/projects", {
      name: `voiceflow-${slug(name)}`.slice(0, 60),
    });
    projectId = project.id;
  }
  const sa = await openai(env, "POST", `/projects/${projectId}/service_accounts`, {
    name: "voiceflow-app",
  });
  return { projectId, serviceAccountId: sa.id, apiKey: sa.api_key.value };
}

async function destroyKey(env, rec, keepProject = false) {
  if (env.TEST_MODE === "true") return;
  try {
    await openai(env, "DELETE", `/projects/${rec.projectId}/service_accounts/${rec.serviceAccountId}`);
  } catch (e) { console.error("service account delete failed", String(e)); }
  if (!keepProject) {
    try { await openai(env, "POST", `/projects/${rec.projectId}/archive`); }
    catch (e) { console.error("project archive failed", String(e)); }
  }
}

async function openai(env, method, path, body) {
  const resp = await fetch(`https://api.openai.com/v1/organization${path}`, {
    method,
    headers: {
      "Authorization": `Bearer ${env.OPENAI_ADMIN_KEY}`,
      "Content-Type": "application/json",
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (!resp.ok) {
    const text = await resp.text();
    throw new Error(`OpenAI admin ${method} ${path} → ${resp.status}: ${text.slice(0, 300)}`);
  }
  return resp.json();
}

// ─── Admin page (static; token stays in the browser) ──────────────────────────

function adminPage() {
  return new Response(ADMIN_HTML, {
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "no-store",
      "X-Frame-Options": "DENY",
      "Referrer-Policy": "no-referrer",
    },
  });
}

const ADMIN_HTML = `<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>Voiceflow — Freigaben</title>
<style>
  :root { color-scheme: light dark; font-family: -apple-system, system-ui, sans-serif; }
  body { max-width: 640px; margin: 2rem auto; padding: 0 1rem; }
  h1 { font-size: 1.3rem; } h2 { font-size: 1rem; margin-top: 1.6rem; }
  .card { border: 1px solid color-mix(in srgb, currentColor 18%, transparent);
          border-radius: 10px; padding: .7rem .9rem; margin: .5rem 0;
          display: flex; align-items: center; gap: .8rem; flex-wrap: wrap; }
  .grow { flex: 1; min-width: 10rem; }
  .muted { opacity: .6; font-size: .85em; }
  button { border: 0; border-radius: 7px; padding: .45rem .8rem; cursor: pointer; font-size: .9em; }
  .ok   { background: #2f9e44; color: #fff; }
  .no   { background: color-mix(in srgb, currentColor 12%, transparent); }
  .bad  { background: #d9480f; color: #fff; }
  input { width: 100%; padding: .5rem .6rem; border-radius: 7px;
          border: 1px solid color-mix(in srgb, currentColor 25%, transparent);
          font-size: 1em; box-sizing: border-box; }
  .tag { font-size: .75em; padding: .1rem .5rem; border-radius: 99px;
         background: color-mix(in srgb, currentColor 10%, transparent); }
</style>
<h1>🎙️ Voiceflow — Freigaben</h1>
<div id="login">
  <p class="muted">Admin-Token eingeben (bleibt nur in diesem Browser-Tab):</p>
  <input id="tok" type="password" placeholder="Admin-Token" autocomplete="off">
  <p><button class="ok" onclick="saveTok()">Anmelden</button></p>
</div>
<div id="app" hidden>
  <h2>Wartet auf Freigabe</h2><div id="pending"></div>
  <h2>Aktiv</h2><div id="active"></div>
  <h2>Übrige</h2><div id="rest"></div>
</div>
<script>
const $ = id => document.getElementById(id);
function tok() { return sessionStorage.getItem("vf_admin_token") || ""; }
function saveTok() { sessionStorage.setItem("vf_admin_token", $("tok").value.trim()); load(); }
async function api(path, body) {
  const r = await fetch(path, { method: "POST",
    headers: { "Authorization": "Bearer " + tok(), "Content-Type": "application/json" },
    body: JSON.stringify(body || {}) });
  if (r.status === 401) { sessionStorage.removeItem("vf_admin_token"); location.reload(); return null; }
  return r.json();
}
function esc(s) { const d = document.createElement("span"); d.textContent = s ?? ""; return d.innerHTML; }
function card(u, buttons) {
  return \`<div class="card"><div class="grow"><b>\${esc(u.name)}</b><br>
    <span class="muted">\${esc(u.email)} · \${esc((u.createdAt||"").slice(0,10))}</span></div>
    <span class="tag">\${esc(u.status)}\${u.awaitingPickup ? " · Key bereit" : ""}</span>\${buttons}</div>\`;
}
async function act(action, token) { await api("/admin/" + action, { token }); load(); }
async function load() {
  if (!tok()) return;
  const data = await api("/admin/list"); if (!data) return;
  $("login").hidden = true; $("app").hidden = false;
  const u = data.users || [];
  $("pending").innerHTML = u.filter(x => x.status === "pending").map(x =>
    card(x, \`<button class="ok" onclick="act('approve','\${x.token}')">Freigeben</button>
             <button class="no" onclick="act('deny','\${x.token}')">Ablehnen</button>\`)).join("") || "<p class=muted>—</p>";
  $("active").innerHTML = u.filter(x => x.status === "approved").map(x =>
    card(x, \`<button class="no" onclick="act('reissue','\${x.token}')">Key neu ausstellen</button>
             <button class="bad" onclick="act('revoke','\${x.token}')">Widerrufen</button>\`)).join("") || "<p class=muted>—</p>";
  $("rest").innerHTML = u.filter(x => x.status !== "pending" && x.status !== "approved").map(x =>
    card(x, x.status === "denied" ? \`<button class="ok" onclick="act('approve','\${x.token}')">Doch freigeben</button>\` : "")).join("") || "<p class=muted>—</p>";
}
load();
</script>`;

// ─── Helpers ──────────────────────────────────────────────────────────────────

function recKey(token) { return `req:${token}`; }
function clean(v, max) { return String(v ?? "").trim().slice(0, max); }
function slug(s) { return s.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "") || "user"; }

function isAdmin(request, env) {
  const got = (request.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  const want = env.ADMIN_TOKEN || "";
  if (!want || got.length !== want.length) return false;
  // Constant-time compare
  let diff = 0;
  for (let i = 0; i < want.length; i++) diff |= got.charCodeAt(i) ^ want.charCodeAt(i);
  return diff === 0;
}

function json(obj, status = 200, extra = {}) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "Content-Type": "application/json", ...extra },
  });
}
