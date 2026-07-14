# Hosted Backend Implementation Tasks

Status: backlog  
Last updated: 2026-07-14  
Plans: [`Product_Plan.md`](./Product_Plan.md), [`Setup_UI_Plan.md`](./Setup_UI_Plan.md)

## How to use this backlog

- Tasks are ordered roughly by dependency. IDs are stable references, not estimates.
- A task is complete only when its acceptance criteria and tests are complete.
- Provider configuration must be managed as code or documented/exported reproducibly; a dashboard click alone is not sufficient evidence.
- Use Dodo test mode, Clerk development, and a capped Groq development account until the live-launch gate.
- Do not put live credentials, webhook secrets, backend refresh tokens, audio, or transcripts in fixtures, logs, screenshots, or source control.

## Critical path

`DISC-*` feasibility gates -> `BE-*` foundation -> `DATA-*` -> `AUTH-*` + `DODO-*` -> `RATE-*` + `USAGE-*` -> `STT-*` -> `APP-*` -> `TEST-*` -> `OPS-*` -> `LAUNCH-*`.

## 0. Feasibility, product, and compliance gates

- [ ] **DISC-001 — Approve the pricing interpretation and customer copy**
  - Record that "Groq rates + 20%" means `Groq cost × 1.20`, not a 20% target gross margin.
  - Confirm USD 1.00/month, USD 0.50 platform component, USD 0.50 included usage, no initial rollover, and metered overage.
  - Define how taxes, Dodo/payment fees, refunds, and chargebacks affect internal revenue reporting without changing the promised usage credit.
  - Acceptance: a dated pricing decision record and approved checkout/Settings/portal wording exist.

- [ ] **DISC-002 — Build a Dodo billing proof of concept**
  - In test mode, configure a USD 1.00 monthly usage-based subscription, a USD 0.50-equivalent recurring credit entitlement, no rollover, overage, and meters for both planned Groq models.
  - Verify whether both meters can consume one shared credit, the number/precision of meter units, per-unit price precision, event timestamp restrictions, event idempotency, invoice thresholds, and portal display.
  - Exercise new purchase, renewal, included usage, overage, cancel-at-period-end, failed payment/on-hold, recovery, refund, dispute, and credit adjustment.
  - Acceptance: the exact configuration is reproducibly documented, all scenarios have expected test invoices/portal entries, and every limitation has an approved design response.

- [ ] **DISC-003 — Validate small-dollar economics**
  - Calculate Dodo fees, payment-method minimums, taxes, refund/chargeback exposure, Groq spend, infrastructure, and support cost for low-, typical-, and high-usage customers.
  - Confirm Dodo permits a USD 1 recurring charge in all launch markets and currencies or narrow the launch market/currency.
  - Acceptance: finance/product signs off that the offer is viable or updates `Product_Plan.md` before implementation is locked.

- [ ] **DISC-004 — Prove Clerk desktop authentication**
  - Prototype a backend-hosted desktop authorization page that authenticates the browser user with Clerk and binds that Clerk subject to a PKCE-protected native login transaction.
  - Prove system-browser login, loopback redirect with one-time code/state, backend code exchange, backend-issued access/refresh credentials, refresh rotation/reuse detection, logout/revocation, and second sign-in on Linux, macOS, and Windows.
  - Confirm redirect URI/port rules, firewall prompts, concurrent login handling, cancellation, and stale callback behavior.
  - Acceptance: a non-production Flutter spike obtains a backend-issued bearer token that the Deno backend can validate on all three platforms; no Clerk token, backend secret, or refresh token appears in a browser URL or app binary.

- [ ] **DISC-005 — Confirm provider and legal permissions**
  - Confirm Groq terms/account tier allow the planned hosted proxy/resale workload and expected concurrency.
  - Confirm Dodo Merchant of Record scope, supported products, tax handling, refund/cancellation requirements, and prohibited-business rules.
  - Draft/review Terms, Privacy Policy, pricing disclosure, acceptable-use policy, refund/cancellation policy, subprocessors, data deletion, and financial-record retention.
  - Acceptance: qualified owners approve launch or document required changes; no unresolved provider-term blocker remains.

- [ ] **DISC-006 — Decide production infrastructure**
  - Select the Deno hosting platform, region(s), PostgreSQL provider, migration runner, background job mechanism, secret manager, monitoring/error tracking, and backup storage.
  - Confirm upload/body/streaming limits and long-request timeouts on the selected host.
  - Acceptance: an architecture decision record includes environments, ownership, cost envelope, recovery objectives, and deployment topology.

- [ ] **DISC-007 — Approve operating policies**
  - Set initial file-size, audio-duration, concurrency, request-rate, per-cycle overage, platform-spend, grace-period, and data-retention limits.
  - Decide how price changes apply to existing subscriptions and how much notice is required.
  - Acceptance: all limits have owners, server configuration keys, user-facing behavior, and review dates.

## 1. Backend foundation

- [ ] **BE-001 — Replace the demo handler with a modular application entry point**
  - Add routing and dependency injection suitable for Deno `Request`/`Response` APIs.
  - Split configuration, HTTP, auth, accounts, billing, webhooks, pricing, transcription, usage, database, jobs, and observability into modules.
  - Keep a small exported handler that is easy to unit/contract test.
  - Acceptance: `/api` and demo HTML are removed; a test can construct the app with fake dependencies and no network calls.

- [ ] **BE-002 — Establish Deno project tasks and dependency policy**
  - Pin dependency versions/imports and add tasks for dev, format check/write, lint, type-check, unit/integration tests, migrations, and jobs.
  - Document how the lockfile is generated and reviewed.
  - Acceptance: a clean checkout has one documented command for each operation and CI uses the same commands.

- [ ] **BE-003 — Implement validated environment configuration**
  - Define typed config for environment, public base URL, database, Clerk issuer/client/JWKS or secret, Dodo environment/API/webhook/product/meter IDs, Groq key/base URL, limits, price catalog, job settings, and telemetry.
  - Reject missing, malformed, contradictory, or test/live-mixed configuration at startup.
  - Acceptance: startup errors name the missing setting without exposing values; tests cover test/live cross-wiring.

- [ ] **BE-004 — Add HTTP middleware and error contracts**
  - Add request IDs, structured access logs, safe exception handling, security headers, content-type/body limits, timeout/cancellation propagation, and narrow CORS.
  - Implement the OpenAI-style error envelope and stable internal error codes.
  - Acceptance: every response includes a request ID; sensitive headers and bodies are redacted in error-path tests.

- [ ] **BE-005 — Add health and readiness endpoints**
  - Implement unauthenticated `/healthz` liveness with no dependency details.
  - Implement a protected/internal readiness check for database and required configuration.
  - Acceptance: deployment probes can distinguish process liveness from dependency readiness without leaking provider details.

- [ ] **BE-006 — Add local development infrastructure**
  - Provide a reproducible local PostgreSQL setup, test database isolation, migration workflow, and fake/stub provider configuration.
  - Add a safe example environment file containing names/placeholders only.
  - Acceptance: a contributor can start backend + database and run the full non-provider test suite from documented commands.

- [ ] **BE-007 — Add backend CI**
  - Run format check, lint, type-check, unit tests, integration tests, migration up/down/forward checks, dependency audit, and secret scanning.
  - Acceptance: CI blocks merges on all failures and never requires live provider credentials for the default suite.

## 2. Persistence and domain model

- [ ] **DATA-001 — Add PostgreSQL access and migration tooling**
  - Choose a Deno-compatible, maintained driver/query layer after checking current docs and runtime support.
  - Configure bounded pooling, TLS, statement/query timeouts, transactions, and test isolation.
  - Acceptance: connectivity, transaction rollback, pool exhaustion, and timeout behavior are integration-tested.

- [ ] **DATA-002 — Create account and billing-customer schemas**
  - Add `accounts` and `billing_customers` with stable internal IDs, unique Clerk subject and Dodo customer constraints, environment partitioning, lifecycle timestamps, and deletion/anonymization state.
  - Do not use email as the unique provider mapping.
  - Acceptance: concurrent first requests cannot create duplicate account/customer mappings.

- [ ] **DATA-003 — Create subscription schema and normalized state model**
  - Store Dodo IDs, product/environment, normalized and raw state, billing period, cancellation flags, provider update version/time, and reconciliation timestamps.
  - Encode allowed transitions and out-of-order update protection in the domain layer.
  - Acceptance: fixtures cover every state in the product plan plus unknown future provider states.

- [ ] **DATA-004 — Create effective-dated price catalog schema**
  - Store public/upstream model IDs, upstream and retail fixed-point rates, markup basis points, currency, minimum billed duration, effective range, enabled flag, and Dodo product/meter mapping.
  - Prevent overlapping effective ranges for one model/currency/environment.
  - Acceptance: historical requests retain their original catalog version after a new rate is activated.

- [ ] **DATA-005 — Create request, reservation, and usage-ledger schemas**
  - Add transcription request state, reservation expiry, account/model/catalog references, actual/billable duration, fixed-point rated units, upstream result class, and timestamps.
  - Make the usage ledger append-only and support debit, refund, promotional/support credit, and reconciliation adjustment types.
  - Acceptance: database permissions/triggers or repository rules prevent mutation/deletion of finalized financial rows outside audited retention tooling.

- [ ] **DATA-006 — Create usage outbox schema**
  - Store deterministic Dodo event ID, usage reference, safe payload, delivery state, attempts, backoff time, lease/lock, provider response class, and delivered time.
  - Acceptance: multiple workers can process the queue without duplicate logical delivery; crashed leases are recoverable.

- [ ] **DATA-007 — Create webhook inbox schema**
  - Store provider, provider event ID, type, verified receipt time, processing status, retry count, safe payload/hash, and last error class.
  - Add uniqueness on provider + environment + event ID.
  - Acceptance: duplicate delivery is acknowledged without repeating a state transition.

- [ ] **DATA-008 — Create reconciliation and audit schemas**
  - Store run windows/cursors, totals by model/account/provider, variances, resolution, operator actions, and immutable audit metadata.
  - Acceptance: reconciliation can be resumed after failure and every manual adjustment has actor, reason, and related records.

- [ ] **DATA-009 — Define retention and anonymization jobs**
  - Implement configured retention for request metadata, webhook payloads, operational logs, expired reservations, and OAuth-related temporary state.
  - Preserve financial records only as required and anonymize deleted users where deletion is legally allowed.
  - Acceptance: retention tests demonstrate content is removed on schedule without breaking financial referential integrity.

- [ ] **DATA-010 — Create desktop auth transaction and session schemas**
  - Add short-lived login transactions with state/challenge/code hashes, exact callback binding, Clerk subject after browser authentication, expiry, and one-time consumption state.
  - Add backend sessions with account/session IDs, refresh-token family/hash, rotation generation, reuse/revocation state, device label, inactivity/absolute expiry, and audit timestamps.
  - Acceptance: raw codes/verifiers/access/refresh tokens are never stored; constraints and concurrent tests prevent code reuse, refresh double-spend, and multiple active generations in one token family.

## 3. Clerk authentication and user lifecycle

- [ ] **AUTH-001 — Configure Clerk environments**
  - Create separate development/test and production configuration.
  - Configure the backend browser authorization page, allowed origins/redirects, minimum identity/profile data, server credentials/JWT verification material, and webhook endpoint.
  - Acceptance: configuration is exported/documented reproducibly and no production Clerk secret or session token appears in client artifacts.

- [ ] **AUTH-002 — Implement desktop login transaction start**
  - Add `POST /v1/auth/desktop/start` to validate a PKCE S256 challenge and allowlisted loopback/app callback, create high-entropy state, persist only safe hashes/metadata, and return an allowlisted sttapp HTTPS authorization URL.
  - Apply strict IP/device rate limits and a short transaction expiry.
  - Acceptance: arbitrary redirects, weak/invalid challenges, duplicate state, expired transactions, and open-redirect/SSRF payloads fail closed.

- [ ] **AUTH-003 — Implement Clerk-backed browser authorization completion**
  - Authenticate the browser user with current Clerk server helpers, bind the verified Clerk subject to exactly one login transaction, create a high-entropy one-time exchange code, and redirect only code + state to the bound callback.
  - Provide safe cancel/expired/error pages and never place an access/refresh/Clerk token in the URL.
  - Acceptance: cross-user transaction fixation, callback substitution, replay, missing/pending Clerk session, and expired/canceled flows are covered.

- [ ] **AUTH-004 — Implement desktop code exchange and account provisioning**
  - Add `POST /v1/auth/desktop/exchange` to verify state, code hash, PKCE verifier, transaction/callback binding, and expiry, then atomically consume the code.
  - Idempotently create/load the local account from the stable Clerk subject and create one backend auth session.
  - Acceptance: concurrent exchange attempts yield one success; no authorization decision depends on mutable email; failure returns no partial credentials.

- [ ] **AUTH-005 — Implement sttapp access-token issuance and verification**
  - Define the signed access-token contract and required issuer, audience, account subject, session ID, token ID, issued/not-before/expiry times, and signing-key ID.
  - Validate signature/algorithm/issuer/audience/time/session/account state and support overlapping signing keys during rotation.
  - Acceptance: tests reject wrong issuer/audience/type, expired/not-yet-valid/malformed tokens, `alg` confusion, missing claims, revoked/deleted sessions/accounts, and stale keys; valid rotated keys succeed.

- [ ] **AUTH-006 — Implement rotating refresh tokens and reuse detection**
  - Return a high-entropy refresh token once, persist only a keyed/slow hash as appropriate, rotate it atomically on `POST /v1/auth/refresh`, and revoke the family on reuse.
  - Enforce inactivity and absolute lifetimes, rate limits, device/session binding, and safe handling of concurrent native refresh calls.
  - Acceptance: refresh double-spend produces at most one new generation, replay revokes the family, temporary provider/database errors do not silently invalidate a valid token, and raw refresh values never enter logs/database.

- [ ] **AUTH-007 — Add authenticated principal middleware**
  - Convert a verified sttapp access token/session into a minimal principal and attach it to protected routes.
  - Never accept a Clerk browser token or trust customer/subscription/account IDs supplied by the client on hosted API routes.
  - Acceptance: every protected `/v1/*` route shares one tested enforcement path and returns stable 401 vs 403/re-authentication errors.

- [ ] **AUTH-008 — Implement logout and revocation**
  - Add idempotent `POST /v1/auth/logout`, optional all-sessions revocation, signing-key rotation procedure, and an operator/user-deletion revocation path.
  - Acceptance: a revoked refresh token cannot rotate and short-lived access expires within the approved revocation window.

- [ ] **AUTH-009 — Implement and verify Clerk webhooks**
  - Preserve raw request bytes, verify current Clerk/Svix signature/timestamp rules, store an idempotent inbox event, and process asynchronously.
  - Handle user updates and deletion; reject unverified/replayed events.
  - Acceptance: signed fixtures, invalid signatures, stale timestamps, duplicates, reordered updates, and deletion are covered.

- [ ] **AUTH-010 — Implement user deletion response**
  - Immediately suspend hosted access, revoke all backend sessions, mark account deletion, cancel or flag billing per approved policy, and queue anonymization.
  - Acceptance: a deleted Clerk user cannot refresh or transcribe even if an old local subscription row says active.

## 4. Dodo Payments integration

- [ ] **DODO-001 — Encode test and live product configuration**
  - Record product, credit, meter, event-name, portal/checkout return URL, currency, and environment identifiers in validated deployment configuration.
  - Add a verification command that reads Dodo configuration and compares it with the server catalog before deploy.
  - Acceptance: deploy fails closed on missing/mismatched IDs or test/live mixing.

- [ ] **DODO-002 — Build a typed Dodo client boundary**
  - Wrap the current supported SDK or REST API for customers, checkout, portal sessions, subscriptions, usage events, and reconciliation reads.
  - Add timeouts, bounded retries only where safe, idempotency keys, response validation, and redacted errors.
  - Acceptance: all provider calls are mockable and retry tests prove non-idempotent operations are not duplicated.

- [ ] **DODO-003 — Implement get-or-create customer mapping**
  - Create one Dodo customer for one internal account/environment and persist the mapping transactionally.
  - Handle provider success followed by local failure using lookup/reconciliation rather than creating duplicates.
  - Acceptance: concurrent checkout requests and injected failures still converge on one Dodo customer.

- [ ] **DODO-004 — Implement `POST /v1/billing/checkout`**
  - Require authentication, validate return URLs server-side, prevent a second active subscription, reuse the Dodo customer, and create an idempotent checkout session for the configured product only.
  - Acceptance: returns only a short-lived HTTPS Dodo URL; duplicate requests do not create duplicate subscriptions; client-supplied product/customer/price values are ignored/rejected.

- [ ] **DODO-005 — Implement `POST /v1/billing/portal`**
  - Require authentication and create a time-limited portal session for the caller's mapped Dodo customer.
  - Acceptance: cross-account access is impossible and the returned domain/environment is allowlisted.

- [ ] **DODO-006 — Implement Dodo webhook verification and inbox**
  - Read raw bytes, verify the current signature and replay/timestamp requirements, persist by provider event ID, acknowledge duplicates, and queue processing.
  - Return promptly and avoid provider API calls inside the receipt transaction.
  - Acceptance: official/test CLI fixtures plus tampered, stale, duplicate, and reordered events are covered.

- [ ] **DODO-007 — Normalize subscription/payment webhook events**
  - Handle purchase/subscription creation, activation, renewal, cancel-at-period-end, cancellation, expiration, failed payment/on-hold, recovery, refund, dispute/chargeback, and future unknown types.
  - Protect against older events overwriting newer period/status data.
  - Acceptance: a transition test matrix proves hosted access for each state and ambiguous cases schedule reconciliation.

- [ ] **DODO-008 — Implement account billing-state endpoint data**
  - Derive normalized state, paid-through period, cancellation, actionable reason codes, portal/checkout availability, and local usage summary for `GET /v1/account`.
  - Acceptance: provider IDs and sensitive details are absent; Flutter can render every state without parsing Dodo-specific strings.

- [ ] **DODO-009 — Implement Dodo subscription reconciliation**
  - Periodically compare local customers/subscriptions with Dodo, repair missed webhook state, and record/audit changes.
  - Add an operator-triggered per-account reconciliation path with authorization and rate limits.
  - Acceptance: deleting/delaying a webhook in test mode is repaired automatically and produces an alert/audit record.

- [ ] **DODO-010 — Implement refund, dispute, and support-adjustment policy**
  - Translate approved financial actions into append-only local adjustments and Dodo operations where applicable.
  - Suspend disputed/fraudulent accounts according to policy.
  - Acceptance: no workflow edits historical usage; support actions are authenticated, authorized, reasoned, and auditable.

## 5. Pricing, reservations, usage, and credit delivery

- [ ] **RATE-001 — Implement fixed-point rating primitives**
  - Represent provider rate, markup basis points, retail rate, duration, credit units, and rounding with integers/decimal arithmetic.
  - Document rounding direction and the point at which rounding occurs.
  - Acceptance: golden tests cover both launch models, 0/short/10-second/long clips, cycle totals, and values around each precision boundary.

- [ ] **RATE-002 — Implement effective catalog lookup**
  - Select one enabled catalog entry by public model, environment, currency, and request/cycle effective time.
  - Snapshot the catalog ID onto each request/reservation.
  - Acceptance: overlapping/missing catalog entries fail closed and price changes do not alter in-flight/historical rating.

- [ ] **RATE-003 — Add a catalog management/release workflow**
  - Add reviewed migrations/config for new rates, an effective-at boundary, Dodo meter verification, customer-notice checklist, and rollback/disable controls.
  - Acceptance: a staged price change is rehearsed in test mode and activates at the intended cycle boundary.

- [ ] **USAGE-001 — Implement safe FLAC metadata duration parsing**
  - Parse only the metadata needed to calculate a bounded duration estimate; reject malformed, truncated, impossible, or decompression-bomb-like input.
  - Do not trust a client duration field.
  - Acceptance: corpus/fuzz tests cover valid app FLAC, malformed headers, huge values, and edge sample rates without crashes or excessive allocation.

- [ ] **USAGE-002 — Implement usage reservations**
  - Before Groq, atomically reserve estimated billable units against account concurrency/spend limits with a short expiry.
  - Make retry behavior explicit: a client request/idempotency key may resume or report the existing result but cannot create two charges.
  - Acceptance: concurrent tests cannot exceed configured limits and abandoned reservations expire safely.

- [ ] **USAGE-003 — Implement finalization transaction**
  - On Groq success, finalize actual/billable seconds, fixed-point price, request state, append-only ledger debit, and Dodo outbox row in one transaction.
  - On upstream/validation failure, release the reservation without a debit.
  - Acceptance: fault-injection at every step cannot produce a delivered transcript with no recoverable usage evidence or a charged failed request.

- [ ] **USAGE-004 — Implement local limits and circuit breakers**
  - Enforce account request/concurrency limits, per-cycle overage ceiling, manual suspension, global daily/provider spend limit, and Groq organization concurrency.
  - Acceptance: limits use the local ledger + live reservations, not Dodo's delayed portal balance, and return stable actionable errors.

- [ ] **USAGE-005 — Implement Dodo usage-event payloads**
  - Define deterministic event IDs and metadata with account/customer mapping, event name, model/meter, fixed-point quantity, timestamp, request ID, and catalog version as supported.
  - Exclude audio, transcript, email, token, and secret data.
  - Acceptance: payload schema is contract-tested against Dodo test mode and duplicate event IDs do not create double usage.

- [ ] **USAGE-006 — Implement outbox delivery worker**
  - Lease batches, send idempotent events, classify retryable/permanent failures, use exponential backoff+jitter, dead-letter after policy limits, and emit backlog/age metrics.
  - Respect Dodo timestamp-age constraints by delivering promptly and escalating stale events for reconciliation/manual resolution.
  - Acceptance: crash/restart, timeout, rate-limit, partial batch, duplicate, malformed payload, and stale-event scenarios are tested.

- [ ] **USAGE-007 — Implement reservation recovery worker**
  - Find expired/incomplete reservations, distinguish known upstream failure from uncertain provider success, and finalize/release/escalate without guessing silently.
  - Acceptance: every reservation reaches a terminal state or an alerted manual-review state.

- [ ] **USAGE-008 — Implement three-way usage reconciliation**
  - Compare internal billable seconds/cost by model with Dodo ingested usage/credits and Groq organization usage for a defined UTC window.
  - Account for provider reporting delays and approved adjustments.
  - Acceptance: synthetic missing/duplicate/mispriced events create a variance report and alert; the job never changes customer billing without an audited resolution.

- [ ] **USAGE-009 — Implement usage-summary reads**
  - Return local current-period usage/included/overage estimates with `as_of` and non-authoritative labeling for the account endpoint.
  - Direct users to Dodo portal for invoices and authoritative payment/credit display.
  - Acceptance: summary math uses the same rating library as finalization and handles provider lag explicitly.

## 6. Groq proxy and OpenAI-compatible API

- [ ] **STT-001 — Build the Groq transcription client boundary**
  - Call the fixed Groq HTTPS host with the server key, strict timeouts, cancellation, response-size limits, and redacted errors.
  - Request the response format needed to verify duration while preserving transcript output for the client.
  - Acceptance: the Groq key and raw transcript never appear in logs/errors; timeout, disconnect, 4xx, 429, and 5xx are classified.

- [ ] **STT-002 — Implement the public model allowlist**
  - Map public model IDs to current effective upstream catalog entries and enabled Dodo meters.
  - Disable a model when any required price/meter/provider configuration is absent.
  - Acceptance: arbitrary Groq model IDs and path injection cannot pass lookup.

- [ ] **STT-003 — Implement `GET /v1/models`**
  - Require authentication and active/canceling entitlement.
  - Return OpenAI-compatible `{object: "list", data: [...]}` with stable IDs and optional namespaced display metadata.
  - Acceptance: it works with the current `TranscriptionService.listModels` parser and denies signed-out/unsubscribed users.

- [ ] **STT-004 — Implement multipart validation for `POST /v1/audio/transcriptions`**
  - Require one `file`, one allowlisted `model`, FLAC MIME/content validation, configured byte/duration limits, and an allowlist for optional fields.
  - Reject client-controlled URL/provider/customer/price/event/entitlement inputs.
  - Acceptance: malformed multipart, duplicate fields/files, MIME spoofing, oversized bodies, unknown models, unsupported options, and slow uploads are covered.

- [ ] **STT-005 — Implement end-to-end transcription handler**
  - Compose auth, entitlement, validation, catalog lookup, reservation, Groq call, usage finalization, response normalization, and cancellation cleanup.
  - Return at least `{ "text": "..." }` on success for the existing client.
  - Acceptance: one successful test-mode request creates exactly one request row, ledger debit, outbox event, and Dodo usage event.

- [ ] **STT-006 — Implement stable error mapping**
  - Map auth, subscription, limits, malformed audio, unsupported model, Groq throttle/outage, timeout, billing uncertainty, and internal errors to stable status/code/retry guidance.
  - Acceptance: no upstream secret/body is leaked and Flutter can distinguish user action from retryable failure.

- [ ] **STT-007 — Add provider resilience controls**
  - Honor Groq retry/rate-limit headers, cap global concurrency, add a circuit breaker, and avoid automatic request replay when it could duplicate provider billing.
  - Acceptance: load/fault tests show bounded memory/queues and a recoverable usage record for uncertain outcomes.

- [ ] **STT-008 — Verify OpenAI compatibility required by sttapp**
  - Freeze request/response contracts used by the Flutter client and add compatibility fixtures.
  - Clearly document unsupported OpenAI fields/response formats.
  - Acceptance: existing custom-provider tests remain unchanged and hosted contract tests use the same client parser.

## 7. Flutter desktop application integration

- [ ] **APP-001 — Introduce explicit transcription provider modes**
  - Replace the single implicit config with `hosted` and `manual` modes.
  - Preserve/migrate existing API key/base URL/model into manual mode and default valid existing installations to manual so behavior does not change unexpectedly.
  - Acceptance: upgrade tests prove no existing secret/config is lost and no audio changes destination without user selection.

- [ ] **APP-002 — Separate hosted auth from custom API-key config**
  - Keep custom API key/base URL/model storage as-is.
  - Store sttapp backend access/refresh credentials in distinct secret keys and never display them as an API key; do not store a Clerk browser session/token in the app.
  - Acceptance: switching modes uses the correct credential and endpoint; logs/UI never reveal hosted tokens.

- [ ] **APP-003 — Implement backend desktop login handoff**
  - Generate verifier/challenge/state, call the backend start endpoint, allowlist/open the returned sttapp authorization URL, host a temporary loopback callback, validate state, exchange the one-time code + verifier with the backend, and clean up listener/state.
  - Handle cancel, timeout, mismatched state, duplicate callback, occupied port, no browser, and app shutdown.
  - Acceptance: platform tests pass on Linux, macOS, and Windows; no access/refresh token is accepted from a URL; no static client/backend secret or Clerk token exists in the app bundle.

- [ ] **APP-004 — Implement token lifecycle**
  - Load backend-issued credentials from secure storage, refresh/rotate before expiry, serialize concurrent refreshes, retry one request after a valid refresh, revoke/sign out, and wipe permanently invalid credentials while retaining them across temporary network failures.
  - Acceptance: tests cover cold start, expiry during transcription, refresh rotation, network failure, revoked refresh token, and sign-out.

- [ ] **APP-005 — Add hosted backend client**
  - Add auth start/exchange/refresh/logout, account, models, checkout, portal, and transcription calls with dynamic sttapp bearer tokens, request IDs, timeouts, and stable error parsing.
  - Do not persist the hosted base URL as an arbitrary editable URL in normal hosted mode; use a build/environment value.
  - Acceptance: production builds cannot be redirected to an attacker endpoint through ordinary settings.

- [ ] **APP-006 — Refactor Settings into reusable sections**
  - Separate transcription provider, hosted account/billing, manual connection, permissions, shortcut, and update/version sections so setup and ordinary Settings can reuse the same controls.
  - Keep existing recorder, permission, shortcut, and update behavior intact while preventing hosted and manual credential controls from appearing together.
  - Acceptance: component/widget tests cover each section independently and the full Settings page retains accessible loading/error/empty states.

- [ ] **APP-007 — Implement checkout and activation flow**
  - Request checkout URL from backend, validate/allowlist it, launch externally, then refresh/poll account state with timeout and manual retry.
  - Never grant access from redirect parameters alone.
  - Acceptance: canceled checkout, delayed webhook, duplicate click, already-active subscription, and failed payment are handled.

- [ ] **APP-008 — Implement Dodo portal launch**
  - Request a fresh portal session from the backend, validate its HTTPS Dodo domain, and launch externally.
  - Acceptance: signed-out/no-customer/expired-session errors have actionable UI and no reusable portal URL is persisted.

- [ ] **APP-009 — Add hosted transcription state/error UX**
  - Surface subscription required/on hold, spend cap, rate limit, invalid model, provider outage, auth expiry, and generic request IDs.
  - Preserve transcript copy/paste behavior on success and never silently fall back providers.
  - Acceptance: widget/service tests cover every stable backend code.

- [ ] **APP-010 — Add account/usage refresh behavior**
  - Refresh account state at startup, after login/checkout/portal return, periodically while Settings is open, and after relevant failures.
  - Label local usage as an estimate and link to Dodo portal for authoritative billing details.
  - Acceptance: polling is bounded/cancelable and does not create a background request storm.

- [ ] **APP-011 — Add platform packaging/network requirements**
  - Document/implement any loopback callback, URL-launcher, firewall, entitlements, or release-signing changes for Windows, macOS, and Linux.
  - Acceptance: signed release artifacts complete login, checkout, portal, and transcription on all supported platforms.

- [ ] **APP-012 — Update client tests and migration fixtures**
  - Add repository, auth, backend client, provider-mode, settings, recorder, and upgrade migration tests while retaining manual-provider coverage.
  - Acceptance: all existing Flutter tests still pass and new tests run without live providers.

- [ ] **APP-013 — Add versioned first-run setup state**
  - Persist provider mode, setup version/step draft, hosted model, and completion separately from the existing manual `TranscriptionConfig`.
  - Migrate a valid existing configuration to completed manual mode without showing onboarding; incomplete/new installations enter setup before input services/hotkeys are enabled.
  - Acceptance: fresh install, valid upgrade, incomplete legacy config, interrupted setup, and future setup-version migration fixtures are covered.

- [ ] **APP-014 — Build the reusable setup shell**
  - Reuse the current Settings window in a dedicated setup mode with title, step label, Back, scrollable content, one primary action, responsive padding, close/quit rules, and focus restoration.
  - Hide unrelated update/version content from the blocking setup flow while retaining it in ordinary Settings.
  - Acceptance: shell works at 420×480, 520×720, 900×900, keyboard-only, and 200% text scale without clipped actions.

- [ ] **APP-015 — Build the hosted/manual provider chooser**
  - Add two accessible full-row radio options explaining audio destination, billing responsibility, hosted price/included usage, and manual-provider responsibility.
  - Preselect the active mode only when rerunning setup; never activate a new mode until that path validates and the user completes it.
  - Acceptance: no selection is the fresh-install default, Continue is gated, and changing modes can never silently reroute audio.

- [ ] **APP-016 — Build the hosted setup page and states**
  - Implement signed-out, browser-waiting, signed-in/no-subscription, checkout-waiting, active/model-selection, on-hold, canceled, refresh-required, and safe error states.
  - Keep tokens invisible; show only non-sensitive account/subscription details and secondary portal/sign-out/manual-mode actions.
  - Acceptance: one reviewed primary action exists per state and widget tests cover cancellation, delayed webhook, retry, token expiry/revocation, model removal, and subscription recovery.

- [ ] **APP-017 — Build the focused manual setup page**
  - Reuse API key show/hide, editable base URL, connection test, model discovery/dropdown, and manual-model controls without hosted account/billing/token UI.
  - Save to the current secure manual configuration only after validation.
  - Acceptance: manual setup requires no backend/Clerk/Dodo request, preserves failed field values, and remains compatible with endpoints that do not implement `/models` through manual model entry.

- [ ] **APP-018 — Integrate permissions, shortcut, and completion pages**
  - Reuse current macOS permission and shortcut registration components after either provider path; persist provider progress while the user visits OS settings.
  - Add a readiness summary and finish action that writes setup completion, initializes input services, refreshes tray state, and hides Settings.
  - Acceptance: setup cannot finish with invalid provider/required permissions/failed shortcut registration, and recovery resumes at the correct step.

- [ ] **APP-019 — Add setup re-entry and provider summary to Settings**
  - Put Transcription provider first in Settings with active-mode/account-or-endpoint/model summary and **Run setup again**.
  - Render hosted account/billing controls or manual connection controls, never both simultaneously, while preserving both modes' stored credentials.
  - Acceptance: rerunning/canceling setup does not destroy the active configuration and explicit confirmation is required before activating a different audio destination.

- [ ] **APP-020 — Complete setup accessibility and semantics**
  - Add radio/button/progress/status/field/select semantics, keyboard focus order, heading focus on step changes, live announcements, non-color state indicators, reduced-motion behavior, and scalable layouts.
  - Acceptance: automated semantic tests plus keyboard/screen-reader smoke tests pass on all supported platforms.

## 8. Security, privacy, and abuse prevention

- [ ] **SEC-001 — Perform a threat model**
  - Cover the Clerk-backed desktop login handoff, PKCE/state/code interception, backend access/refresh token theft or replay, callback interception, customer-ID substitution, webhook forgery/replay, duplicate billing, arbitrary proxying, upload abuse, denial of service, provider-key theft, insider adjustments, and privacy leakage.
  - Acceptance: mitigations map to tasks/tests and all high-risk findings are closed or explicitly accepted before beta.

- [ ] **SEC-002 — Implement secret management and rotation**
  - Load production secrets only from the selected manager, grant least privilege, separate environments, and document rotation for Clerk, Dodo, Groq, database, and webhook secrets.
  - Acceptance: a rotation rehearsal succeeds without embedding secrets in images, source, logs, or client releases.

- [ ] **SEC-003 — Enforce outbound and redirect allowlists**
  - Fix/allowlist Groq, Clerk, Dodo checkout/portal, and application return hosts; prevent SSRF and open redirects.
  - Acceptance: malicious host, scheme, userinfo, encoded-host, DNS, and redirect test cases fail closed.

- [ ] **SEC-004 — Add layered rate limits and account suspension**
  - Enforce per-IP pre-auth limits and authenticated per-account/concurrency/spend limits with operator suspension.
  - Acceptance: distributed/concurrent tests show limits cannot be bypassed by request retries or model switching.

- [ ] **SEC-005 — Prove content redaction and no-retention behavior**
  - Audit logs, traces, error reporting, database rows, webhook metadata, provider errors, test artifacts, and backups for transcript/audio/token leakage.
  - Acceptance: automated redaction tests use canary secrets/transcripts and find none outside process memory/authorized response.

- [ ] **SEC-006 — Run dependency, SAST, and penetration review**
  - Audit Deno and Flutter dependencies/licenses, scan secrets, fuzz multipart/FLAC/webhook parsers, and test auth/authorization boundaries.
  - Acceptance: no unresolved critical/high issue at beta launch.

## 9. Observability, jobs, and operations

- [ ] **OPS-001 — Add structured logs and metrics**
  - Implement the request, auth, entitlement, model, duration, latency, Groq, ledger, outbox, webhook, subscription, and reconciliation telemetry listed in the product plan.
  - Use pseudonymous internal account IDs and redaction by default.
  - Acceptance: dashboards can trace a request ID to state transitions without showing content or credentials.

- [ ] **OPS-002 — Add distributed traces**
  - Trace HTTP, database, Groq, Dodo, and job spans with cancellation and request correlation.
  - Acceptance: sampling/export configuration excludes multipart bodies, transcript response text, and auth headers.

- [ ] **OPS-003 — Configure alerts and budgets**
  - Alert on auth anomalies, Groq errors/throttles, webhook signature failures, outbox backlog/dead letters, reservation leaks, reconciliation variance, database saturation, subscription-state anomalies, and spend circuit breakers.
  - Configure Groq and infrastructure budgets/spend alerts.
  - Acceptance: each alert is test-fired and routes to an owned response procedure.

- [ ] **OPS-004 — Deploy scheduled/background workers**
  - Run outbox delivery, reservation recovery, Clerk/Dodo webhook processing, subscription reconciliation, usage reconciliation, retention, and price-review reminders with single-run/lease protection.
  - Acceptance: jobs survive restart, are observable, and cannot overlap unsafely.

- [ ] **OPS-005 — Configure database backup and restore**
  - Set retention, encryption, access, point-in-time recovery where available, and a recurring restore test.
  - Acceptance: a documented restore drill meets approved recovery point/time objectives.

- [ ] **OPS-006 — Write operational runbooks**
  - Cover Groq outage/throttle, Dodo outage/webhook delay, Clerk outage/key rotation, database incident, outbox dead letter, reconciliation variance, leaked secret, disputed account, refund/adjustment, price change, and circuit-breaker activation.
  - Acceptance: an on-call owner can follow each runbook in a game day without undocumented dashboard knowledge.

- [ ] **OPS-007 — Build safe operator tools**
  - Provide least-privileged, audited commands/endpoints for account lookup by internal/provider ID, suspension, reconciliation, outbox replay, and approved ledger adjustment.
  - Acceptance: tools require strong operator authentication/authorization, support dry run, and cannot reveal transcript/audio.

- [ ] **OPS-008 — Create environment deployment pipeline**
  - Automate build, checks, migrations, deploy, smoke tests, rollback/forward-fix, and environment/provider-ID verification for staging and production.
  - Acceptance: staging deployment is repeatable and production requires explicit approval with test/live safeguards.

## 10. Verification and release testing

- [ ] **TEST-001 — Complete backend unit coverage**
  - Cover auth claims, state transitions, fixed-point rating, minimum duration, catalog boundaries, FLAC parsing, reservation/ledger rules, errors, redaction, and provider payload mapping.
  - Acceptance: critical financial/auth modules meet an agreed branch/behavior coverage threshold with mutation or fault tests where valuable.

- [ ] **TEST-002 — Complete database integration coverage**
  - Test constraints, concurrency, transactions, leases, idempotency, migrations, retention, and injected failures against real PostgreSQL.
  - Acceptance: tests prove duplicate customer/subscription/usage/webhook records cannot be created under races.

- [ ] **TEST-003 — Complete HTTP contract coverage**
  - Freeze success/error contracts for auth start/exchange/refresh/logout, health, account, models, transcriptions, checkout, portal, and webhooks.
  - Acceptance: Flutter client fixtures and backend contract fixtures are generated from or checked against the same documented contract.

- [ ] **TEST-004 — Complete provider sandbox suite**
  - Run opt-in Clerk, Dodo test-mode, and Groq tests for browser-session binding, backend token verification/rotation/revocation, checkout/portal, every billing lifecycle, usage credit/overage, event retries, model transcription, and provider limits.
  - Acceptance: results are stored as redacted CI artifacts and can be rerun before a release.

- [ ] **TEST-005 — Complete end-to-end desktop suite**
  - On Linux, macOS, and Windows, test fresh user, login, subscribe, model list, transcription, included usage, portal, overage display, cancel, payment hold/recovery, sign-out, restart, and manual mode.
  - Acceptance: signed release candidates pass using production-like staging configuration.

- [ ] **TEST-006 — Run billing invariants and reconciliation tests**
  - Inject duplicate/delayed/missing/out-of-order webhooks and usage events, price changes, time-zone/cycle boundaries, refunds, disputes, and database/provider failures.
  - Acceptance: no scenario double bills, bills a failed transcription, loses successful usage evidence, or grants unpaid access beyond policy.

- [ ] **TEST-007 — Run load, soak, and failure tests**
  - Measure multipart memory, concurrent uploads, Groq limits, DB pool, worker throughput, rate limiting, timeouts, and circuit breakers with synthetic non-sensitive audio.
  - Acceptance: approved limits keep resource use bounded and error behavior stable at/above expected beta load.

- [ ] **TEST-008 — Perform security/privacy release review**
  - Re-run threat model, authorization matrix, parser fuzzing, dependency/security scans, secret scan, and content-retention canaries.
  - Acceptance: security owner approves beta/GA and evidence is linked from the release checklist.

## 11. Documentation and launch

- [ ] **DOC-001 — Publish backend developer documentation**
  - Document architecture, local setup, environment schema, migrations, jobs, API/error contracts, provider test setup, price catalog, and troubleshooting.
  - Acceptance: a new contributor can run and test the backend without private verbal instructions.

- [ ] **DOC-002 — Publish user-facing hosted-mode documentation**
  - Explain hosted vs manual mode, where audio goes, sign-in, USD 1 plan, included usage, model-dependent rates/minimums, overage timing/cap, Dodo portal, cancellation, refunds, and support.
  - Acceptance: product/legal review approves wording and it matches live Dodo configuration exactly.

- [ ] **DOC-003 — Publish privacy and legal documents**
  - Make the approved Terms, Privacy Policy, acceptable use, refund/cancellation, subprocessors, and data-request instructions reachable before checkout.
  - Acceptance: URLs are configured in Clerk/Dodo/app and included in release artifacts/store pages where applicable.

- [ ] **LAUNCH-001 — Run internal alpha**
  - Use test payments and a capped Groq account; execute the complete lifecycle and daily reconciliation with staff.
  - Acceptance: no unexplained billing variance, critical defect, or privacy/security finding remains.

- [ ] **LAUNCH-002 — Enable limited live beta**
  - Gate enrollment, use conservative per-user/platform spend caps, monitor daily Groq/internal/Dodo totals, and staff support/refund paths.
  - Acceptance: explicit go/no-go approval records limits, cohort, rollback trigger, and on-call owners.

- [ ] **LAUNCH-003 — Close one complete live billing cycle**
  - Validate purchases, included usage, overages, renewals, cancellations, failed payments/recovery, fees/taxes, refunds if any, portal display, and reconciliation.
  - Acceptance: finance/engineering sign off on zero material unexplained variance before widening access.

- [ ] **LAUNCH-004 — General availability review**
  - Review SLOs, support load, unit economics, fraud/abuse, provider limits, legal requirements, rate catalog freshness, backup/restore, and incident readiness.
  - Acceptance: owners approve GA, staged expansion, and the recurring operating calendar.

- [ ] **LAUNCH-005 — Establish recurring operations**
  - Schedule provider pricing/terms reviews, Dodo catalog verification, reconciliation audits, secret rotation, restore tests, dependency updates, retention jobs, security review, and limit/unit-economics review.
  - Acceptance: every recurring control has an owner, cadence, alert/ticket automation, and evidence location.

## Definition of done for the hosted backend

The hosted backend is complete only when all of the following are true:

- Existing users can continue manual-provider mode without signing in or changing configuration.
- A hosted user can authenticate through the Clerk-backed browser flow on Linux, macOS, and Windows and receive only backend-issued native credentials without a client secret.
- Live access follows verified Dodo subscription state and cannot be granted by client input or redirect alone.
- The Dodo portal shows the configured subscription, credits/usage, payment history, and management actions.
- `/v1/models` exposes only enabled, correctly priced speech models.
- Every successful hosted transcription has exactly one recoverable internal usage record and one logical Dodo usage event.
- Failed/rejected transcriptions do not create customer usage debits.
- Groq/internal/Dodo reconciliation is automated and variance alerts are operational.
- Audio, transcript text, provider keys, and auth credentials are absent from persistent application data and telemetry.
- Rate limits, spend caps, backups, restore, incident runbooks, refund/adjustment paths, and secret rotation have been tested.
- Pricing/legal/privacy copy matches actual live provider behavior and has the required approvals.
- At least one limited live billing cycle closes without material unexplained variance before general availability.
