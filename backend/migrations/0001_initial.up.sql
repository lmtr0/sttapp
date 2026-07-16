CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE accounts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider_environment text NOT NULL CHECK (provider_environment IN ('test','live')),
  clerk_subject text NOT NULL,
  email_snapshot text,
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','suspended','deleting','deleted')),
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), deleted_at timestamptz, anonymized_at timestamptz,
  UNIQUE (provider_environment, clerk_subject), UNIQUE (provider_environment, id)
);
CREATE TABLE auth_transactions (
  id uuid PRIMARY KEY, state_hash text NOT NULL UNIQUE, pkce_challenge text NOT NULL, callback_uri text NOT NULL,
  device_label text, clerk_subject text, clerk_email text, code_hash text, expires_at timestamptz NOT NULL, consumed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(), CHECK (char_length(state_hash) = 43), CHECK (char_length(pkce_challenge) = 43),
  CHECK (code_hash IS NULL OR char_length(code_hash) = 43)
);
CREATE TABLE auth_sessions (
  id uuid PRIMARY KEY, account_id uuid NOT NULL REFERENCES accounts(id), family_id uuid NOT NULL,
  current_refresh_hash text NOT NULL, used_refresh_hashes text[] NOT NULL DEFAULT '{}', generation integer NOT NULL DEFAULT 0,
  expires_at timestamptz NOT NULL, inactive_at timestamptz NOT NULL, last_seen_at timestamptz NOT NULL,
  revoked_at timestamptz, revoke_reason text, device_label text, created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (family_id), CHECK (char_length(current_refresh_hash) = 43), CHECK (generation >= 0)
);
CREATE INDEX auth_sessions_account_active_idx ON auth_sessions(account_id) WHERE revoked_at IS NULL;
CREATE TABLE billing_customers (
  account_id uuid PRIMARY KEY REFERENCES accounts(id), provider_environment text NOT NULL CHECK (provider_environment IN ('test','live')),
  dodo_customer_id text NOT NULL, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (provider_environment, dodo_customer_id),
  FOREIGN KEY (provider_environment, account_id) REFERENCES accounts(provider_environment, id)
);
CREATE TABLE subscriptions (
  account_id uuid PRIMARY KEY REFERENCES accounts(id), provider_environment text NOT NULL CHECK (provider_environment IN ('test','live')),
  dodo_subscription_id text, product_id text NOT NULL, normalized_state text NOT NULL,
  raw_state text, period_start timestamptz, period_end timestamptz, cancel_at_period_end boolean NOT NULL DEFAULT false,
  provider_updated_at timestamptz, provider_update_version text, checkout_attempt_id uuid, reconciled_at timestamptz, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (provider_environment, dodo_subscription_id),
  FOREIGN KEY (provider_environment, account_id) REFERENCES accounts(provider_environment, id),
  CHECK (normalized_state IN ('no_subscription','checkout_pending','active','canceling','past_due','on_hold','canceled','expired','billing_unknown'))
);
CREATE TABLE price_catalog (
  id text NOT NULL, provider_environment text NOT NULL CHECK (provider_environment IN ('test','live')),
  public_model text NOT NULL, upstream_model text NOT NULL, currency char(3) NOT NULL,
  upstream_micros_per_hour bigint NOT NULL CHECK (upstream_micros_per_hour >= 0), retail_micros_per_hour bigint NOT NULL CHECK (retail_micros_per_hour >= 0),
  markup_basis_points integer NOT NULL CHECK (markup_basis_points >= 0), minimum_billable_seconds integer NOT NULL CHECK (minimum_billable_seconds >= 0),
  meter_id text NOT NULL, event_name text NOT NULL, effective_range tstzrange NOT NULL, enabled boolean NOT NULL DEFAULT true,
  PRIMARY KEY (provider_environment, id),
  EXCLUDE USING gist (provider_environment WITH =, public_model WITH =, currency WITH =, effective_range WITH &&) WHERE (enabled)
);
CREATE TABLE transcription_requests (
  id uuid PRIMARY KEY, account_id uuid NOT NULL REFERENCES accounts(id), provider_environment text NOT NULL CHECK (provider_environment IN ('test','live')), catalog_id text NOT NULL,
  idempotency_key text, state text NOT NULL, reservation_expires_at timestamptz, reserved_retail_micros bigint,
  actual_milliseconds bigint, billable_milliseconds bigint,
  retail_micros bigint, upstream_result_class text, created_at timestamptz NOT NULL DEFAULT now(), finalized_at timestamptz,
  CHECK (state IN ('reserved','succeeded','failed','review')),
  CHECK (reserved_retail_micros IS NULL OR reserved_retail_micros >= 0),
  CHECK (actual_milliseconds IS NULL OR actual_milliseconds >= 0),
  CHECK (billable_milliseconds IS NULL OR billable_milliseconds >= 0),
  CHECK (retail_micros IS NULL OR retail_micros >= 0),
  FOREIGN KEY (provider_environment, catalog_id) REFERENCES price_catalog(provider_environment, id),
  FOREIGN KEY (provider_environment, account_id) REFERENCES accounts(provider_environment, id)
);
CREATE UNIQUE INDEX transcription_requests_idempotency_idx ON transcription_requests(account_id, idempotency_key) WHERE idempotency_key IS NOT NULL;
CREATE TABLE usage_ledger (
  id uuid PRIMARY KEY, account_id uuid NOT NULL REFERENCES accounts(id), request_id uuid REFERENCES transcription_requests(id),
  entry_type text NOT NULL CHECK (entry_type IN ('debit','refund','promotional_credit','support_credit','reconciliation_adjustment')), provider_environment text NOT NULL CHECK (provider_environment IN ('test','live')),
  catalog_id text, retail_micros bigint NOT NULL, actual_milliseconds bigint, billable_milliseconds bigint,
  reason text, actor_id text, created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (actual_milliseconds IS NULL OR actual_milliseconds >= 0),
  CHECK (billable_milliseconds IS NULL OR billable_milliseconds >= 0),
  FOREIGN KEY (provider_environment, catalog_id) REFERENCES price_catalog(provider_environment, id),
  FOREIGN KEY (provider_environment, account_id) REFERENCES accounts(provider_environment, id)
);
CREATE OR REPLACE FUNCTION reject_financial_mutation() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'usage ledger is append-only'; END $$;
CREATE TRIGGER usage_ledger_immutable BEFORE UPDATE OR DELETE ON usage_ledger FOR EACH ROW EXECUTE FUNCTION reject_financial_mutation();
CREATE TABLE usage_outbox (
  event_id text PRIMARY KEY, usage_id uuid NOT NULL UNIQUE REFERENCES usage_ledger(id), payload jsonb NOT NULL,
  state text NOT NULL DEFAULT 'pending' CHECK (state IN ('pending','leased','delivered','dead')),
  attempts integer NOT NULL DEFAULT 0, next_attempt_at timestamptz NOT NULL DEFAULT now(), lease_until timestamptz,
  provider_response_class text, delivered_at timestamptz, created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX usage_outbox_ready_idx ON usage_outbox(next_attempt_at) WHERE state IN ('pending','leased');
CREATE TABLE webhook_events (
  provider text NOT NULL CHECK (provider IN ('clerk','dodo')), provider_environment text NOT NULL CHECK (provider_environment IN ('test','live')),
  event_id text NOT NULL, event_type text NOT NULL, verified_at timestamptz NOT NULL, status text NOT NULL DEFAULT 'pending',
  retry_count integer NOT NULL DEFAULT 0 CHECK (retry_count >= 0), safe_payload jsonb NOT NULL, payload_hash text, last_error_class text, processed_at timestamptz,
  CHECK (status IN ('pending','processed','failed')),
  PRIMARY KEY (provider, provider_environment, event_id)
);
CREATE TABLE reconciliation_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), kind text NOT NULL, window_start timestamptz, window_end timestamptz,
  cursor jsonb, totals jsonb NOT NULL DEFAULT '{}', variance jsonb NOT NULL DEFAULT '{}', status text NOT NULL,
  resolution text, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE audit_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), actor_id text NOT NULL, action text NOT NULL, reason text NOT NULL,
  related_type text NOT NULL, related_id text NOT NULL, safe_metadata jsonb NOT NULL DEFAULT '{}', created_at timestamptz NOT NULL DEFAULT now()
);
CREATE OR REPLACE FUNCTION reject_audit_mutation() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'audit log is immutable'; END $$;
CREATE TRIGGER audit_log_immutable BEFORE UPDATE OR DELETE ON audit_log FOR EACH ROW EXECUTE FUNCTION reject_audit_mutation();
CREATE TABLE job_leases (name text PRIMARY KEY, owner_id text NOT NULL, lease_until timestamptz NOT NULL, updated_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE rate_limit_buckets (key text PRIMARY KEY, window_start timestamptz NOT NULL, count integer NOT NULL CHECK (count > 0), updated_at timestamptz NOT NULL DEFAULT now());

CREATE INDEX auth_transactions_expiry_idx ON auth_transactions(expires_at);
CREATE INDEX transcription_requests_account_created_idx ON transcription_requests(account_id, created_at);
CREATE INDEX transcription_requests_reservations_idx ON transcription_requests(account_id, reservation_expires_at) WHERE state='reserved';
CREATE INDEX usage_ledger_account_created_idx ON usage_ledger(account_id, created_at);
CREATE INDEX webhook_events_pending_idx ON webhook_events(status, verified_at);
