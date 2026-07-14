# sttapp Hosted Backend Product Plan

Status: implementation plan  
Last updated: 2026-07-14

## 1. Summary

sttapp will gain an optional hosted transcription service while preserving the current bring-your-own-provider workflow.

In hosted mode, a user signs in with Clerk, starts a paid Dodo Payments subscription, and sends the same OpenAI-compatible multipart transcription request the app already knows how to send. The Deno backend authenticates the user, checks billing status and safety limits, proxies an allowlisted model to Groq, records billable audio usage, and sends idempotent usage events to Dodo. Dodo remains the source of truth for payment collection, subscription state, included credits, overage invoices, and the hosted customer usage/billing portal.

A native first-run setup flow lets the user choose **sttapp Hosted** or **Manual provider**. It opens automatically for new/incomplete installations and can be launched again from Settings. Hosted browser authentication is backed by Clerk, but the access token used by the native app is issued by the sttapp backend and refreshed through the backend. Manual setup retains the existing user-supplied API key, base URL, and model workflow.

The initial commercial offer is:

- USD 1.00 charged each month.
- USD 0.50 is the platform fee.
- USD 0.50 is included transcription usage credit for that billing cycle.
- Usage beyond the included credit is billed at the current Groq model rate plus a 20% markup.
- Unused included usage expires at the end of the billing cycle unless product review explicitly approves rollover.

The backend is a Groq proxy with an OpenAI-compatible surface; it does not use an OpenAI API key or route traffic to OpenAI in the first release. "OpenAI Transcription API" in this plan means compatibility with the request and response shape already consumed by the app.

## 2. Product goals

- Let a new user transcribe without obtaining or managing a Groq/OpenAI API key.
- Keep the existing manual-provider API key, base URL, and model path fully usable without an sttapp account or subscription.
- Make hosted billing predictable at low usage and proportional at high usage.
- Keep Groq and Dodo secrets entirely on the server.
- Give users a hosted Dodo portal for credit balance, usage history, invoices, payment methods, and cancellation.
- Keep the public transcription interface close enough to the current OpenAI-compatible client that migration is small and testable.
- Make every successful hosted transcription traceable from an authenticated request to an internal usage record and a Dodo usage event.
- Make provider price changes controlled, auditable, and effective only at a documented boundary.

## 3. Non-goals for the first release

- Replacing or disabling bring-your-own-provider mode.
- Proxying arbitrary Groq models or arbitrary OpenAI-compatible endpoints.
- Supporting organizations, teams, seat billing, shared credit pools, or delegated billing.
- Building a custom usage dashboard in Flutter; the app opens Dodo's hosted customer portal.
- Storing audio or transcript text after the request completes.
- Real-time/streaming transcription, translations, batch transcription, or files supplied by URL.
- Supporting an OpenAI upstream provider. This can be added later behind the same provider abstraction.
- Advertising the USD 0.50 platform component as net revenue; taxes, refunds, chargebacks, and Dodo/payment-processing fees affect the amount actually retained.

## 4. Current application baseline

The current Flutter app:

- Stores an API key, OpenAI-compatible base URL, and model in native secure storage.
- Sends FLAC as multipart form data to `{baseUrl}/audio/transcriptions` with `Authorization: Bearer ...`.
- Reads transcription text from either `text` or `transcript` in a JSON response.
- Loads models from `{baseUrl}/models` and expects an OpenAI-style `{ "data": [{ "id": ... }] }` response.
- Can operate against Groq or another compatible backend today.

The current `backend/` directory is only a minimal Deno HTTP handler with `/api` and no authentication, persistence, billing, or provider integration.

This existing protocol is an advantage: hosted mode can use a backend base URL ending in `/v1`, while custom mode can retain the current configuration and request path.

## 5. User modes and experience

### 5.1 Hosted mode

1. The user chooses **sttapp Hosted** in Settings.
2. The app creates a backend desktop-login transaction with a PKCE challenge and launches an allowlisted sttapp HTTPS authorization page in the system browser.
3. The backend page uses Clerk to authenticate the user and binds the verified Clerk subject to that transaction.
4. The browser returns only a short-lived one-time code and state to a loopback redirect on `127.0.0.1` (preferred) or a registered app link.
5. The app exchanges the code and PKCE verifier with the backend. The backend atomically consumes the code and issues a short-lived sttapp access token plus a rotating refresh token.
6. The app stores those backend credentials in the existing native secret-storage package and keeps them out of ordinary settings and logs.
7. The app calls the backend account endpoint.
8. If there is no active subscription, the app offers **Subscribe for $1/month** and opens a Dodo checkout URL created by the backend.
9. After successful checkout, the app polls/refreshes account state until a verified Dodo webhook or reconciliation confirms access.
10. Model selection is populated from the backend `/v1/models` allowlist.
11. Transcriptions use the sttapp access token as the bearer credential and refresh it through the backend when needed.
12. **Usage & billing** opens a short-lived Dodo customer portal session created by the backend.

### 5.2 Manual provider mode

- The current API key, base URL, model discovery, test connection, and transcription behavior remain available.
- No Clerk session or Dodo subscription is required.
- The manual-provider API key stays in native secure storage and is sent only to the configured endpoint.
- Switching modes does not delete either mode's credentials. The app must clearly show which provider will receive audio.
- Hosted access/billing failures must never silently fall back to a manual provider because that could send audio somewhere the user did not choose.

### 5.3 Account and billing states

The app and backend use a small normalized state model rather than exposing provider-specific names everywhere:

| State | Hosted transcription | User action |
| --- | --- | --- |
| `signed_out` | Denied | Sign in or use manual mode |
| `no_subscription` | Denied | Start checkout |
| `checkout_pending` | Denied until confirmed | Refresh status |
| `active` | Allowed within safety limits | Transcribe / open portal |
| `canceling` | Allowed through paid period | Resume or wait for period end |
| `past_due` / `on_hold` | Denied after any explicitly configured grace period | Update payment method in portal |
| `canceled` / `expired` | Denied | Resubscribe or use manual mode |
| `billing_unknown` | Fail closed for new hosted requests | Retry; backend reconciles with Dodo |

Webhook state is authoritative in normal operation. A reconciliation job repairs missed or delayed events. The client never grants itself access based only on a checkout success redirect.

### 5.4 Native first-run setup

The existing Settings window has a dedicated setup mode rather than introducing another window. A new installation starts with a provider chooser, then shows either the hosted account/subscription/model flow or the existing manual API key/base URL/model flow. Both paths continue through permissions and shortcut readiness before setup is marked complete.

Existing installations with a valid custom configuration migrate to `manual` mode without being interrupted. Settings shows the active transcription provider and a **Run setup again** action. Rerunning setup preserves both modes' credentials until the user explicitly signs out or clears them, and changing the active audio destination always requires an explicit selection and confirmation.

The detailed screen, state, recovery, accessibility, migration, and token-handoff design is in [`Setup_UI_Plan.md`](./Setup_UI_Plan.md).

## 6. Pricing and metering model

### 6.1 Commercial formula

For model `m`:

```text
retail_rate_per_hour(m) = groq_rate_per_hour(m) * 1.20
billable_seconds(request) = max(actual_audio_seconds, Groq minimum billed seconds)
retail_usage(request) = billable_seconds(request) / 3600 * retail_rate_per_hour(m)
```

"Plus 20%" is treated as a 20% markup on Groq cost, not a 20% gross-margin target. Money and rated usage must use integer fixed-point units or decimal arithmetic; binary floating point must not be used for persisted or invoiced amounts.

Groq currently documents a 10-second minimum billed duration for speech-to-text requests. That minimum is applied per request before usage is sent to Dodo. The pricing catalog stores this rule so it can be versioned if Groq changes it.

### 6.2 Planning snapshot, not hardcoded pricing

As of 2026-07-14, Groq documents these synchronous transcription rates:

| Model | Groq rate | Customer rate at 1.20x | Approximate audio covered by USD 0.50 |
| --- | ---: | ---: | ---: |
| `whisper-large-v3-turbo` | $0.0400/hour | $0.0480/hour | 10h 25m |
| `whisper-large-v3` | $0.1110/hour | $0.1332/hour | 3h 45m |

The included-time examples ignore per-request 10-second minimums, taxes, refunds, and payment-provider fees. Public product copy should say "USD 0.50 of transcription usage" rather than promise a fixed number of hours.

Rates must live in a server-side, effective-dated catalog. A catalog entry includes provider, upstream model, public model ID, upstream rate, markup basis points, retail rate, currency, minimum billable duration, effective timestamp, and Dodo meter/product identifiers. A transcription snapshots the applicable catalog version so later price changes do not rewrite historical usage.

Default price-change policy:

- Review provider pricing on a scheduled basis and on provider change notifications.
- Apply a new retail rate at the next customer billing-cycle boundary, not in the middle of a cycle.
- Update Dodo configuration and the server catalog together through a controlled release.
- Notify affected customers when required by law, Dodo policy, or product terms.
- Never fetch a provider pricing web page dynamically in the request path.

### 6.3 Dodo product shape

The intended Dodo configuration is a monthly usage-based subscription with:

- Base recurring price: USD 1.00.
- Included credit entitlement: USD 0.50-equivalent of hosted transcription usage per cycle.
- Credit rollover: off initially.
- Overage: enabled and billed at cycle end or according to Dodo's supported invoice thresholds.
- One shared credit type across the two speech models if Dodo's precision and multi-meter rules can express the exact retail formula.
- One meter per billable model, aggregating server-rated billable seconds or fixed-point usage units.

Dodo's documented credit processing is asynchronous, so its portal balance cannot be the only real-time authorization control. The backend keeps a near-real-time local usage ledger and per-account safety cap; Dodo remains invoice and payment source of truth.

Before production configuration, a billing proof of concept must verify:

- Dodo permits a USD 1.00 recurring product in every launch market/payment method.
- Meter and credit precision can represent these sub-cent per-second rates without systematic overcharging.
- Multiple model meters can consume the intended shared included credit.
- The desired split between the USD 0.50 platform component and USD 0.50 usage entitlement is represented correctly in invoices and portal copy.
- Overage timing, minimum invoice amounts, taxes, fees, refunds, disputes, credits, and negative adjustments behave acceptably.
- Existing subscriptions can receive future rate changes at the chosen cycle boundary.

If Dodo cannot represent exact dollar-equivalent credits, the fallback is an internal microcredit unit with transparent conversion and Dodo meters configured to the same fixed-point schedule. If Dodo cannot safely invoice such small usage, launch pricing must be revised rather than implementing hidden rounding.

### 6.4 Usage consistency rules

- Bill only a successful transcription response delivered by Groq.
- Do not bill a user for backend validation failures, authentication failures, rejected limits, or upstream failures/timeouts.
- Use a unique internal request ID and a deterministic Dodo `event_id` for every finalized usage record.
- Store no transcript or audio in usage-event metadata.
- Record the actual duration, billable duration, model, catalog version, retail units, upstream status, and Dodo delivery status.
- Retry Dodo event delivery through an outbox. Duplicate retries must be harmless.
- Reconcile the internal ledger, Dodo events/credits, and Groq organization usage regularly; alert on unexplained variance.
- Refunds or support credits create append-only adjustment records rather than editing historical usage rows.

## 7. System architecture

```text
Flutter desktop app
  |-- system browser --> sttapp authorization page --> Clerk
  |-- sttapp Bearer token --> Deno API
                         |-- access-token verification --> sttapp auth/session store
                         |-- account + usage ledger --> PostgreSQL
                         |-- multipart audio --> Groq transcription API
                         |-- usage outbox --> Dodo usage events
                         |-- checkout/portal sessions --> Dodo API

Dodo signed webhooks ----> Deno webhook endpoint ----> PostgreSQL entitlement cache
Clerk signed webhooks ---> Deno webhook endpoint ----> PostgreSQL user lifecycle
Scheduled workers -------> outbox delivery + Dodo reconciliation + price/usage audits
```

### 7.1 Runtime and modules

Keep the backend in Deno and split the current single handler into explicit modules:

- `config`: validated environment configuration and secret references.
- `http`: routing, request IDs, CORS, errors, body limits, and security headers.
- `auth`: Clerk-backed desktop login handoff, backend token issuance/refresh/revocation, and authenticated principal creation.
- `accounts`: local user and provider-ID mapping.
- `billing`: Dodo checkout, portal, subscription normalization, and reconciliation.
- `webhooks`: raw-body signature verification, idempotency, and handlers.
- `pricing`: effective-dated rate catalog and fixed-point rating.
- `transcriptions`: multipart validation, model allowlist, Groq proxy, and response normalization.
- `usage`: reservations, finalized ledger entries, adjustments, safety limits, and Dodo outbox.
- `db`: migrations, repositories, and transactions.
- `jobs`: outbox retry, reconciliation, cleanup, and alerts.
- `observability`: structured logs, metrics, tracing, and redaction.

Use PostgreSQL for durable relational state. Dodo owns invoices and payment methods; PostgreSQL owns the stable Clerk-to-Dodo mapping, entitlement cache, request/usage audit trail, idempotency records, and delivery state.

### 7.2 Minimum data model

| Entity | Purpose and important fields |
| --- | --- |
| `accounts` | Internal ID, Clerk subject, primary email snapshot, status, timestamps, deletion/anonymization state |
| `auth_transactions` | Short-lived PKCE challenge, state hash, redirect binding, Clerk subject after browser authentication, one-time exchange-code hash, expiry, and consumed time |
| `auth_sessions` | Account/session ID, refresh-token family/hash, rotation/reuse state, expiry/inactivity bounds, device label, revocation reason, and timestamps |
| `billing_customers` | Account ID, Dodo customer ID, environment, timestamps; unique on both IDs |
| `subscriptions` | Dodo subscription ID, normalized/raw status, product ID, period bounds, cancel-at-period-end, last webhook version/time |
| `price_catalog` | Public/upstream model IDs, rates, markup basis points, fixed-point scale, minimum seconds, effective range, Dodo meter ID |
| `transcription_requests` | Request ID, account, model/catalog version, actual/billable duration, state, provider status/error class, timestamps; no content |
| `usage_ledger` | Append-only debit/credit adjustments in fixed-point units, source request, cycle, reason, timestamps |
| `usage_outbox` | Deterministic event ID, usage row, payload, attempt count, next attempt, delivered timestamp, last safe error |
| `webhook_events` | Provider, provider event ID, type, signature-verified receipt time, processing status, payload retention pointer/hash |
| `reconciliation_runs` | Scope, cursor/window, totals, variance, status, timestamps |

Raw access tokens, raw refresh tokens, PKCE verifiers, secrets, audio, and transcripts do not belong in these tables. Store only one-way hashes and non-secret session metadata needed for validation, rotation, revocation, and audit.

## 8. HTTP API contract

All JSON errors use an OpenAI-compatible envelope where practical:

```json
{
  "error": {
    "message": "Human-readable message",
    "type": "invalid_request_error",
    "code": "subscription_required",
    "request_id": "req_..."
  }
}
```

### Desktop authentication endpoints

- `POST /v1/auth/desktop/start` creates a short-lived PKCE-bound login transaction and returns an allowlisted sttapp HTTPS authorization URL.
- The browser authorization route uses Clerk to authenticate the user and redirects only a one-time code plus state to the registered loopback/app callback.
- `POST /v1/auth/desktop/exchange` atomically consumes that code and verifier and returns a short-lived sttapp access token plus rotating refresh token.
- `POST /v1/auth/refresh` rotates the refresh token and issues a new access token. Reuse of an already-rotated token revokes the token family.
- `POST /v1/auth/logout` revokes the backend session. Logout is idempotent.
- Start/exchange/refresh endpoints have strict rate limits, expirations, replay protection, redacted errors, and no open redirect behavior.

### `GET /healthz`

- Unauthenticated liveness check with no provider or database details.
- A separate protected readiness/diagnostics path may check dependencies.

### `GET /v1/models`

- Requires a valid sttapp access bearer token and hosted entitlement.
- Returns an OpenAI-style list object.
- Includes only enabled speech-to-text models from the effective server catalog.
- Does not proxy Groq's entire model list.
- Model metadata may include a display name and relative price in a namespaced field, but the client must not calculate invoices from it.

### `POST /v1/audio/transcriptions`

- Requires a valid sttapp access bearer token and hosted entitlement.
- Accepts multipart `file` and `model` fields compatible with the current app.
- Initial file types are restricted to the app's FLAC output, with a documented size and duration limit. Broader Groq-supported formats can be enabled deliberately later.
- Rejects unknown fields only when they are unsafe; supported optional OpenAI/Groq fields must be allowlisted and validated before forwarding.
- Ignores client-supplied provider URLs, prices, customer IDs, event IDs, or entitlement data.
- Forces an internal response format sufficient to obtain trustworthy duration/usage metadata, then returns the JSON `text` shape the current app expects.
- Streams the incoming file to Groq where the chosen Deno multipart/runtime implementation permits it; otherwise enforces a strict in-memory limit.
- Maps upstream errors to stable client error codes without leaking Groq keys or raw internal responses.

### `GET /v1/account`

- Returns the normalized account/subscription state, current period, hosted availability, non-authoritative usage summary, portal availability, and reason/action codes.
- Does not return Dodo or Clerk secrets.

### `POST /v1/billing/checkout`

- Requires authentication.
- Creates/reuses exactly one Dodo customer mapping and creates a checkout session for the configured product.
- Uses an idempotency key and prevents accidental duplicate active subscriptions.
- Returns a short-lived HTTPS checkout URL for the system browser.

### `POST /v1/billing/portal`

- Requires authentication and an existing Dodo customer.
- Creates a short-lived Dodo customer portal session and returns its HTTPS URL.

### `POST /webhooks/dodo`

- Reads the raw body, verifies Dodo's current webhook signature scheme, enforces timestamp/replay rules, and only then parses/handles it.
- Is idempotent by provider event ID.
- Updates customer/subscription/payment state and schedules reconciliation for ambiguous/out-of-order events.
- Returns quickly; slow side effects run asynchronously.

### `POST /webhooks/clerk`

- Verifies the Clerk/Svix webhook signature against the raw request body.
- Synchronizes relevant user creation/update/deletion changes.
- User deletion revokes hosted access immediately and starts a documented anonymization/deletion workflow; financial records are retained only as legally required.

## 9. Authentication design

- Use the system browser rather than an embedded webview. A backend-hosted authorization page uses Clerk for user sign-in; the native app does not store a Clerk session/token.
- Bind every desktop login transaction to a high-entropy state value, PKCE S256 challenge, exact registered callback class, short expiry, and one-time exchange code. Return no bearer or refresh credential in a browser URL.
- Prefer loopback redirect URIs for desktop. Verify exact behavior on Linux, macOS, and Windows during the auth spike; use a claimed HTTPS/app link only if loopback cannot meet the requirement.
- The backend validates the Clerk browser session using current Clerk server helpers before binding its subject to the transaction.
- The backend issues a short-lived signed access token containing only required claims such as issuer, audience, subject/account, session ID, token ID, issued/expiry time, and signing-key ID. Protected `/v1/*` routes accept only this sttapp token type.
- Store a rotating refresh token only in the existing native platform secret store. Store only its one-way hash and token-family/session metadata on the backend.
- Refresh before access expiry, serialize concurrent refreshes, rotate on every success, detect reuse, and revoke the family on theft/replay. Wipe native credentials on sign-out or a permanent revoked/expired response; retain them across temporary network failures.
- Define and test signing-key rotation, clock skew, absolute session lifetime, inactivity timeout, refresh reuse behavior, revocation latency, and logout-all-sessions behavior before beta.
- Never identify a billing customer by mutable email alone. The stable mapping is internal account ID -> Clerk subject -> Dodo customer ID.

There is no official Clerk Flutter SDK listed in Clerk's current SDK catalog. Keeping Clerk in the backend browser flow and issuing first-party sttapp credentials avoids embedding Clerk-specific session logic in the native app, but the end-to-end handoff remains an explicit proof-of-concept milestone.

## 10. Transcription and usage flow

1. Assign a request ID and apply global abuse controls before reading a large body.
2. Verify the sttapp access bearer token/session and load the internal account.
3. Require an active/canceling entitlement and check account/provider safety caps.
4. Validate multipart content type, file type, byte limit, selected model, and optional fields.
5. Determine a bounded audio-duration estimate from FLAC metadata and create a short-lived usage reservation. This prevents uncontrolled concurrent overage; it is not final billing.
6. Forward the request to Groq with the server API key and a server-selected upstream model.
7. On a successful Groq response, derive/verify actual duration, apply the provider minimum, and rate it using the snapshotted catalog entry.
8. In one database transaction, finalize the request, append the usage debit, and create the Dodo outbox record.
9. Return the normalized transcription response without waiting for Dodo event ingestion.
10. A worker delivers the event to Dodo with deterministic idempotency, retry/backoff, and dead-letter alerting.
11. On validation/upstream failure, release the reservation and record only redacted operational metadata.
12. If finalization fails after a provider success, retain/recover the reservation and alert; never discard the only evidence of billable provider usage.

## 11. Limits and abuse controls

Low per-unit cost does not remove abuse risk because the Groq key and Dodo merchant account are shared infrastructure.

- Per-account and per-IP request-rate limits.
- Per-account concurrent transcription limit.
- Maximum upload bytes and maximum audio duration.
- Global Groq concurrency and rate-limit protection.
- A configurable per-cycle customer spend ceiling above included credit, initially conservative.
- A platform-wide daily/provider spend circuit breaker.
- Deny hosted use for `on_hold`, fraudulent, disputed, deleted, or manually suspended accounts.
- Treat Dodo portal balances as eventually consistent and enforce safety limits from the local ledger.
- Return stable retry guidance for throttles and provider outages.
- Provide an operator-only audited path to suspend an account or create a usage adjustment.

## 12. Privacy, security, and compliance

- Display clear disclosure that hosted audio is sent through sttapp's backend to Groq; custom mode sends audio to the endpoint the user selected.
- Do not persist audio or transcript content. Avoid request-body logging, exception dumps containing multipart bytes, and provider responses containing text.
- Keep only the minimum metadata needed for billing, abuse control, support, and reconciliation.
- Define and enforce retention windows for request metadata, raw webhook payloads, idempotency keys, and audit logs.
- Encrypt transport everywhere and encrypt database/backups at rest.
- Store `GROQ_API_KEY`, `DODO_PAYMENTS_API_KEY`, Dodo webhook secret, Clerk secret/JWT material, and database credentials only in the deployment secret manager.
- Separate Dodo test/live configuration and databases or strongly partition all provider IDs by environment.
- Apply strict CORS even though the desktop app is not browser-CORS constrained; webhook endpoints do not use CORS as authentication.
- Pin/validate outbound provider hostnames and never allow a client-controlled upstream URL in hosted mode.
- Verify dependency provenance, lock versions, and run vulnerability/license checks.
- Publish Terms, Privacy Policy, refund/cancellation policy, usage-pricing explanation, subprocessor disclosure, and support contact before taking live payments.
- Confirm Merchant of Record responsibilities, tax display, consumer cancellation rules, and data deletion/financial retention obligations with qualified counsel and Dodo before launch.

## 13. Reliability and observability

### Service objectives

- Target 99.9% monthly availability for authenticated backend endpoints, excluding documented provider outages.
- Track transcription success and latency separately from Dodo event-delivery latency.
- Do not block a successful transcription response on Dodo's asynchronous ingestion when the durable local outbox is committed.

### Required telemetry

- Structured request logs with request ID, internal account ID (pseudonymous), model, sizes/durations, state, latency, and redacted error class.
- Metrics for authentication failures, entitlement denials, requests, audio seconds, retail/upstream rated units, Groq status/latency, reservation leaks, outbox backlog/age, webhook failures, reconciliation variance, and subscription states.
- Alerts for elevated Groq failures, provider throttling, Dodo/Clerk webhook signature failures, dead-letter usage events, billing variance, database errors, and spend circuit breakers.
- Trace propagation across request handling, Groq, database, and outbox delivery without transcript/audio content.

### Recovery

- Automated database backups with a tested restore procedure.
- Idempotent migrations and documented rollback/forward-fix strategy.
- Replay tooling for verified webhook events and usage outbox records.
- Scheduled reconciliation that pages on financial variance rather than silently changing invoices.

## 14. Testing strategy

- Unit tests for fixed-point rating, minimum duration, price effective dates, state normalization, error mapping, and redaction.
- Contract tests for `/v1/models`, multipart transcription, account, checkout, portal, and both webhook endpoints.
- Auth tests for desktop transaction state/PKCE/expiry/replay, Clerk browser-session binding, backend token issuer/audience/signature/expiry, refresh rotation/reuse, revoked sessions, wrong token types, and key rotation.
- Billing tests for new subscription, renewal, cancellation, cancel-at-period-end, failed payment/on-hold, recovery, refund, dispute, duplicate/out-of-order webhook, included credit, and overage.
- Usage tests for success, upstream failure, request retry, duplicate event, outbox retry, reservation timeout, concurrent requests, price change, and reconciliation.
- Flutter tests for hosted/custom mode isolation, secure credential storage, login callback, token refresh, checkout polling, portal launch, model selection, and no silent fallback.
- Provider sandbox tests against Clerk development, Dodo test mode, and a controlled Groq account.
- End-to-end desktop tests on Linux, macOS, and Windows for browser login callback and hosted transcription.
- Load tests using synthetic audio to establish memory, upload, concurrency, database, and provider limits before widening caps.

## 15. Rollout plan

### Phase 0: feasibility and commercial validation

- Prove Clerk public-client PKCE on all desktop targets.
- Prove the exact Dodo USD 1 + included credit + metered overage configuration in test mode.
- Validate Dodo precision/minimum-charge economics and legal/product copy.
- Confirm Groq resale/proxy use and rate limits are appropriate for this product.

Exit criterion: no unresolved blocker can cause unauthenticated access, systematic billing error, or a loss-making/minimum-charge product.

### Phase 1: backend foundation

- Build authenticated account, model-list, transcription, ledger/outbox, checkout, portal, and webhook paths.
- Run entirely in provider test modes with internal users.

Exit criterion: a successful request is traceable end-to-end and reconciliation reports zero unexplained variance.

### Phase 2: native integration and staff alpha

- Add the first-run/Settings setup UI, hosted/manual mode, backend-issued token lifecycle, desktop browser login, account state, checkout, portal, and hosted errors to Flutter.
- Test signed builds on all desktop platforms.

Exit criterion: staff can subscribe, consume included credit, incur test overage, view it in Dodo, cancel, and continue using custom mode.

### Phase 3: limited paid beta

- Enable live Dodo/Groq for a capped cohort with conservative per-user/platform limits.
- Manually review daily Groq vs internal vs Dodo totals and support cases.

Exit criterion: at least one complete billing cycle, including renewals and failures, closes without material variance.

### Phase 4: general availability

- Expand enrollment gradually, tune limits from observed workloads, automate price/provider change reviews, and publish operational status/support procedures.

## 16. Launch decisions and gates

These items must be resolved and recorded before enabling live checkout:

1. Confirm that "Groq rates + 20%" means a 1.20x markup. This plan assumes it does.
2. Confirm no OpenAI upstream is required in v1. This plan treats the API only as OpenAI-compatible.
3. Approve no-rollover behavior for the included USD 0.50 usage credit.
4. Approve the per-cycle overage safety cap and how users request a higher cap.
5. Select the production Deno host, PostgreSQL service, job runner, secret manager, and observability stack.
6. Validate Dodo's exact small-dollar, credit precision, invoice, fee, refund, and rate-change behavior in the launch countries.
7. Decide retention periods and complete legal review of resale/proxy terms, privacy, subprocessors, pricing copy, taxes, cancellation, and refunds.
8. Decide whether catalog price changes apply to every customer's next renewal or require a new product/version in Dodo.
9. Approve backend access/refresh token format, lifetimes, signing-key storage/rotation, refresh-family inactivity/absolute lifetime, reuse detection, and logout/revocation policy.

## 17. Documentation sources and assumptions

Provider behavior is version-sensitive. Recheck these sources during implementation and before launch:

- [OpenAI speech-to-text compatibility/model documentation](https://developers.openai.com/api/docs/models/gpt-4o-transcribe)
- [Groq speech-to-text endpoints, models, prices, formats, and minimum billed duration](https://console.groq.com/docs/speech-to-text)
- [Groq rate-limit dimensions](https://console.groq.com/docs/rate-limits)
- [Clerk backend request authentication](https://clerk.com/docs/reference/backend/authenticate-request)
- [Clerk session tokens and server-side validation](https://clerk.com/docs/guides/sessions/session-tokens)
- [Clerk SDK catalog](https://clerk.com/docs/reference/overview)
- [Dodo usage-based billing](https://docs.dodopayments.com/features/usage-based-billing/introduction)
- [Dodo credit-based billing](https://docs.dodopayments.com/features/credit-based-billing)
- [Dodo customer portal](https://docs.dodopayments.com/features/customer-portal)

The pricing table is a dated planning snapshot. The effective server/Dodo catalog, not this document, will be authoritative for live billing.
