# Hosted backend implementation status

Updated: 2026-07-18

This file distinguishes repository-local implementation from provider, legal,
infrastructure, and cross-platform evidence. It intentionally does not mark the
backlog checkboxes complete when their full acceptance criteria require external
proof.

## Implemented in the repository and unit verified

- Modular Deno handler, pinned tasks/lockfile, fail-closed configuration, safe
  HTTP middleware/errors, health/readiness, local Postgres Compose, and CI
  wiring for audit, secret scan, tests, and migration checks.
- PostgreSQL schema for accounts, billing mappings/subscriptions, effective
  price catalog, atomic auth transactions/sessions, durable reservations,
  requests, append-only ledger, usage outbox, webhook inbox,
  reconciliation/audit records, and job leases.
- PKCE S256 desktop start/browser completion/code exchange; sttapp EdDSA access
  tokens; refresh rotation/reuse-family revocation; shared principal middleware;
  logout and Clerk-deletion worker path.
- Typed Dodo/Groq fetch boundaries; checkout, portal, account, models and
  transcription routes; provider URL/model allowlists; bounded FLAC parsing and
  provider-duration checks; fixed-point minimum-duration rating; transactional
  spend/concurrency limits.
- Raw-byte webhook verification/inbox, outbox delivery with retry/backoff/dead
  letter state, webhook state normalization, retention cleanup and worker
  leases.
- Flutter provider/setup persistence migration, one-item atomic manual config,
  provider state, and hosted credentials; hosted HTTP client/error parsing,
  serialized refresh; PKCE loopback service, and a no-fallback transcription
  coordinator. The desktop Settings UI now defaults fresh installs to sttapp
  Hosted, preserves valid legacy manual setups, supports reversible
  hosted/manual switching without clearing inactive credentials, and exposes
  sign-in, cancellation, account, enabled-model, checkout, portal, refresh, and
  sign-out states. Recorder readiness, window closing, tray start state, and
  transcription routing now follow the active provider. Existing manual storage
  and service remain compatible.

## Partially implemented; acceptance evidence still required

- Postgres integration tests require a running database. CI is configured for
  migration up/down/up and the opt-in integration suite; this review environment
  had neither Docker nor PostgreSQL tooling, so those checks were not executed
  locally.
- Dodo REST paths/payloads and webhook event mapping require test-mode contract
  fixtures and lifecycle proof. Catalog IDs remain deployment configuration.
- Clerk browser UI/environment export, official signed webhook fixtures, and
  Linux/macOS/Windows loopback behavior require Clerk development setup and
  signed desktop builds.
- Groq successful transcription and Dodo ingestion require capped sandbox keys;
  request code is local, but end-to-end exactly-once/reconciliation evidence is
  external.
- Flutter hosted persistence, HTTP parsing, refresh serialization, fresh/legacy
  provider selection, PKCE loopback exchange/cancel/overlap handling, sign-in UI
  states, enabled-model selection, reversible switching/restart, sign-out
  preservation, active-provider readiness, and no-fallback coordinator routing
  are unit/widget tested. The loopback service still needs focused OS-level
  tests, and signed Linux/macOS/Windows browser callback, billing-return,
  secure-storage, recording, and transcription journeys remain external release
  evidence.
- Safe structured logs exist, but no complete metrics/tracing backend,
  dashboards, budgets, or test-fired alert routes exist. Distributed request
  rate limiting and global/provider spend circuit breakers also remain.
- The Cloudflare module-Worker adapter, Hyperdrive/Wrangler configuration,
  one-minute scheduled jobs, and production GitHub deployment workflow bundle
  locally. The real Cloudflare account, Hyperdrive/database resource, custom
  domain, protected environment approvals, and first production deployment still
  require external configuration and evidence.

## External/uncompleted gates

All `DISC-*`, provider sandbox/economic/legal approvals, production
infrastructure selection, live secrets/configuration, backup/restore drill,
penetration review, load/soak testing, signed cross-platform E2E, launch
documents, alpha/beta/live billing cycle, and GA/recurring-operations evidence
remain open. These cannot be truthfully completed from source code alone.
