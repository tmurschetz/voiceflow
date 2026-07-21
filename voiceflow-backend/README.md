# Voiceflow Accounts — key-issuing service

Small Cloudflare Worker so friends can use Voiceflow **without creating an
OpenAI account**: they register inside the app, Thomas approves on the admin
page, and a **per-user, budget-capped OpenAI project key** is provisioned and
delivered once into the app's Keychain.

**Dictation never flows through this service** — after setup the app talks to
OpenAI directly, exactly like bring-your-own-key mode.

## Security model (read before changing anything)

| Secret | Where it lives | Never |
|---|---|---|
| `OPENAI_ADMIN_KEY` (creates keys, spends money) | Cloudflare secret only | in repo, app, chat, logs, responses |
| `ADMIN_TOKEN` (approve/revoke rights) | Thomas's password manager + browser sessionStorage | in repo, app |
| Per-user project key | OpenAI + user's macOS Keychain; in KV **only until first pickup**, then deleted | shown in any UI, contained in `/admin/list` |
| `deviceToken` (256-bit, generated on the user's Mac) | user's Keychain + KV record key | logged |

Endpoints: `POST /register` (rate-limited 5/day/IP, idempotent, cannot overwrite
an existing record) · `GET /status?token=` (one-time key delivery, no
enumeration) · `/admin` page + `POST /admin/{list,approve,deny,revoke,reissue}`
(Bearer `ADMIN_TOKEN`, constant-time compare).

Per-user keys are **project service-account keys**: revoking deletes the
service account (key dies immediately) and archives the project.

## Deploy (one-time)

```sh
cd voiceflow-backend
npx wrangler login                          # browser opens — Thomas logs in
npx wrangler kv namespace create REGISTRY   # paste the id into wrangler.toml
npx wrangler secret put ADMIN_TOKEN         # long random string (password manager!)
npx wrangler secret put OPENAI_ADMIN_KEY    # Thomas pastes the org admin key himself
npx wrangler deploy
```

The OpenAI admin key is created at platform.openai.com → **Settings →
Organization → Admin keys**. After deploy, set the worker URL in the app
(`Config.accountServiceURL`) and set a **monthly budget** per project (OpenAI
dashboard → project → Limits) — recommended ~10 CHF.

## Local development / tests

```sh
npx wrangler dev --env dev    # TEST_MODE=true → fake keys, no OpenAI calls
```

Smoke test: register → approve (via /admin with any token set through
`--var ADMIN_TOKEN:test`) → status delivers `sk-test-…` exactly once.

## Runbook

- **Approve/deny/revoke:** open `https://<worker-url>/admin`, enter admin token.
- **Friend reinstalled / new Mac:** "Key neu ausstellen" → app picks it up on
  next status poll (the old key is invalidated first).
- **Kill switch:** "Widerrufen" — key dies at OpenAI within seconds; the app
  clears itself on next poll.
- **Costs:** each user's usage is visible per project in the OpenAI dashboard.
