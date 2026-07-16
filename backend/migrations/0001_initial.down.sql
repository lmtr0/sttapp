DROP TABLE IF EXISTS rate_limit_buckets, job_leases, audit_log, reconciliation_runs, webhook_events, usage_outbox, usage_ledger, transcription_requests, price_catalog, subscriptions, billing_customers, auth_sessions, auth_transactions, accounts CASCADE;
DROP FUNCTION IF EXISTS reject_financial_mutation();
DROP FUNCTION IF EXISTS reject_audit_mutation();
