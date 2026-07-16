import postgres from "postgres";
import type { AppConfig } from "../config.ts";
import type {
  Account,
  AuthTransaction,
  CatalogEntry,
  Session,
  Subscription,
  SubscriptionState,
  UsageRecord,
  UsageReservation,
} from "../domain.ts";
import type {
  NewSession,
  Repository,
  ReservationResult,
  RotationResult,
} from "../repository.ts";

type Row = Record<string, unknown>;

export class PostgresRepository implements Repository {
  #sql;
  constructor(private config: AppConfig) {
    this.#sql = postgres(config.databaseUrl, {
      max: config.databasePoolSize,
      idle_timeout: 20,
      connect_timeout: 10,
      ssl: config.databaseTls ? "require" : false,
      prepare: true,
      connection: {
        application_name: "sttapp-backend",
        statement_timeout: Math.min(config.requestTimeoutMs, 30_000),
        lock_timeout: 5000,
      },
    });
  }
  async ready(): Promise<boolean> {
    try {
      await this.#sql`SELECT 1`;
      return true;
    } catch {
      return false;
    }
  }
  async close(): Promise<void> {
    await this.#sql.end();
  }
  async ensureCatalog(entries: readonly CatalogEntry[]): Promise<void> {
    for (const entry of entries) {
      await this
        .#sql`INSERT INTO price_catalog(id,provider_environment,public_model,upstream_model,currency,upstream_micros_per_hour,retail_micros_per_hour,markup_basis_points,minimum_billable_seconds,meter_id,event_name,effective_range,enabled) VALUES (${entry.id},${this.config.providerEnvironment},${entry.publicModel},${entry.upstreamModel},${entry.currency},${entry.upstreamMicrosPerHour.toString()},${entry.retailMicrosPerHour.toString()},${entry.markupBasisPoints},${entry.minimumBillableSeconds},${entry.meterId},${entry.eventName},tstzrange(${entry.effectiveFrom},${
        entry.effectiveTo || null
      },'[)'),${entry.enabled}) ON CONFLICT(provider_environment,id) DO NOTHING`;
      const [stored] = await this
        .#sql`SELECT public_model,retail_micros_per_hour::text,meter_id FROM price_catalog WHERE id=${entry.id} AND provider_environment=${this.config.providerEnvironment}`;
      if (
        !stored || stored.public_model !== entry.publicModel ||
        stored.retail_micros_per_hour !==
          entry.retailMicrosPerHour.toString() ||
        stored.meter_id !== entry.meterId
      ) {
        throw new Error(
          `Catalog entry ${entry.id} does not match deployment configuration`,
        );
      }
    }
  }
  async createAuthTransaction(tx: AuthTransaction): Promise<void> {
    await this.#sql`INSERT INTO auth_transactions ${
      this.#sql(
        {
          id: tx.id,
          state_hash: tx.stateHash,
          pkce_challenge: tx.challenge,
          callback_uri: tx.callbackUri,
          device_label: tx.deviceLabel || null,
          expires_at: tx.expiresAt,
        },
        "id",
        "state_hash",
        "pkce_challenge",
        "callback_uri",
        "device_label",
        "expires_at",
      )
    }`;
  }
  async getAuthTransaction(id: string): Promise<AuthTransaction | undefined> {
    const [row] = await this
      .#sql`SELECT * FROM auth_transactions WHERE id=${id}`;
    return row && authTransaction(row as Row);
  }
  async bindAuthTransaction(
    id: string,
    clerkSubject: string,
    clerkEmail: string | undefined,
    codeHash: string,
    now: Date,
  ): Promise<AuthTransaction | undefined> {
    const [row] = await this
      .#sql`UPDATE auth_transactions SET clerk_subject=${clerkSubject},clerk_email=${
      clerkEmail || null
    },code_hash=${codeHash} WHERE id=${id} AND expires_at>${now} AND consumed_at IS NULL AND clerk_subject IS NULL RETURNING *`;
    return row && authTransaction(row as Row);
  }
  async exchangeAuthTransaction(
    id: string,
    codeHash: string,
    now: Date,
    next: NewSession,
  ): Promise<{ account: Account; session?: Session } | undefined> {
    return await this.#sql.begin(async (sql) => {
      const [transaction] =
        await sql`UPDATE auth_transactions SET consumed_at=${now} WHERE id=${id} AND code_hash=${codeHash} AND clerk_subject IS NOT NULL AND consumed_at IS NULL AND expires_at>${now} RETURNING *`;
      if (!transaction) return undefined;
      const tx = authTransaction(transaction as Row);
      const [accountRow] =
        await sql`INSERT INTO accounts(provider_environment,clerk_subject,email_snapshot) VALUES (${this.config.providerEnvironment},${tx
          .clerkSubject!},${
          tx.clerkEmail || null
        }) ON CONFLICT(provider_environment,clerk_subject) DO UPDATE SET email_snapshot=COALESCE(EXCLUDED.email_snapshot,accounts.email_snapshot),updated_at=now() RETURNING *`;
      const value = account(accountRow as Row);
      if (value.status !== "active") return { account: value };
      const [sessionRow] = await sql`INSERT INTO auth_sessions ${
        sql(
          {
            id: next.id,
            account_id: value.id,
            family_id: next.familyId,
            current_refresh_hash: next.refreshHash,
            used_refresh_hashes: [],
            generation: 0,
            expires_at: next.expiresAt,
            inactive_at: next.inactiveAt,
            last_seen_at: now,
            device_label: next.deviceLabel || null,
            created_at: next.createdAt,
          },
          "id",
          "account_id",
          "family_id",
          "current_refresh_hash",
          "used_refresh_hashes",
          "generation",
          "expires_at",
          "inactive_at",
          "last_seen_at",
          "device_label",
          "created_at",
        )
      } RETURNING *`;
      return { account: value, session: session(sessionRow as Row) };
    });
  }
  async getOrCreateAccount(
    clerkSubject: string,
    email?: string,
  ): Promise<Account> {
    const [row] = await this
      .#sql`INSERT INTO accounts(provider_environment, clerk_subject, email_snapshot) VALUES (${this.config.providerEnvironment},${clerkSubject},${
      email || null
    }) ON CONFLICT(provider_environment,clerk_subject) DO UPDATE SET email_snapshot=COALESCE(EXCLUDED.email_snapshot,accounts.email_snapshot),updated_at=now() RETURNING *`;
    return account(row as Row);
  }
  async getAccount(id: string): Promise<Account | undefined> {
    const [row] = await this
      .#sql`SELECT * FROM accounts WHERE id=${id} AND provider_environment=${this.config.providerEnvironment}`;
    return row && account(row as Row);
  }
  async findAccountByClerkSubject(
    subject: string,
  ): Promise<Account | undefined> {
    const [row] = await this
      .#sql`SELECT * FROM accounts WHERE clerk_subject=${subject} AND provider_environment=${this.config.providerEnvironment}`;
    return row && account(row as Row);
  }
  async setAccountStatus(id: string, status: Account["status"]): Promise<void> {
    await this
      .#sql`UPDATE accounts SET status=${status},updated_at=now(),deleted_at=CASE WHEN ${status}='deleted' THEN now() ELSE deleted_at END WHERE id=${id} AND provider_environment=${this.config.providerEnvironment}`;
  }
  async saveSession(session: Session): Promise<void> {
    await this.#sql`INSERT INTO auth_sessions ${
      this.#sql(
        {
          id: session.id,
          account_id: session.accountId,
          family_id: session.familyId,
          current_refresh_hash: session.refreshHash,
          used_refresh_hashes: session.previousHashes,
          generation: session.generation,
          expires_at: session.expiresAt,
          inactive_at: session.inactiveAt,
          last_seen_at: session.lastSeenAt,
          revoked_at: session.revokedAt || null,
          revoke_reason: session.revokeReason || null,
          device_label: session.deviceLabel || null,
          created_at: session.createdAt,
        },
        "id",
        "account_id",
        "family_id",
        "current_refresh_hash",
        "used_refresh_hashes",
        "generation",
        "expires_at",
        "inactive_at",
        "last_seen_at",
        "revoked_at",
        "revoke_reason",
        "device_label",
        "created_at",
      )
    }`;
  }
  async getSession(id: string): Promise<Session | undefined> {
    const [row] = await this.#sql`SELECT * FROM auth_sessions WHERE id=${id}`;
    return row && session(row as Row);
  }
  async rotateSession(
    id: string,
    presentedHash: string,
    nextHash: string,
    now: Date,
  ): Promise<RotationResult> {
    return await this.#sql.begin(async (sql) => {
      const [raw] =
        await sql`SELECT * FROM auth_sessions WHERE id=${id} FOR UPDATE`;
      if (!raw) return { status: "invalid" } as const;
      const value = session(raw as Row);
      if (value.revokedAt) return { status: "invalid" } as const;
      if (value.expiresAt <= now || value.inactiveAt <= now) {
        await sql`UPDATE auth_sessions SET revoked_at=${now},revoke_reason='expired' WHERE id=${id}`;
        return { status: "expired" } as const;
      }
      if (value.previousHashes.includes(presentedHash)) {
        await sql`UPDATE auth_sessions SET revoked_at=${now},revoke_reason='refresh_reuse' WHERE family_id=${value.familyId}`;
        return { status: "reused" } as const;
      }
      if (value.refreshHash !== presentedHash) {
        return { status: "invalid" } as const;
      }
      const inactivity = Math.max(
        1,
        value.inactiveAt.getTime() - value.lastSeenAt.getTime(),
      );
      const inactiveAt = new Date(
        Math.min(value.expiresAt.getTime(), now.getTime() + inactivity),
      );
      const [updated] =
        await sql`UPDATE auth_sessions SET used_refresh_hashes=array_append(used_refresh_hashes,current_refresh_hash),current_refresh_hash=${nextHash},generation=generation+1,last_seen_at=${now},inactive_at=${inactiveAt} WHERE id=${id} RETURNING *`;
      return { status: "rotated", session: session(updated as Row) } as const;
    });
  }
  async revokeSessionIfRefreshMatches(
    id: string,
    presentedHash: string,
    reason: string,
    now: Date,
  ): Promise<void> {
    await this
      .#sql`UPDATE auth_sessions SET revoked_at=COALESCE(revoked_at,${now}),revoke_reason=COALESCE(revoke_reason,${reason}) WHERE id=${id} AND (current_refresh_hash=${presentedHash} OR ${presentedHash}=ANY(used_refresh_hashes))`;
  }
  async revokeSession(id: string, reason: string, now: Date): Promise<void> {
    await this
      .#sql`UPDATE auth_sessions SET revoked_at=COALESCE(revoked_at,${now}),revoke_reason=COALESCE(revoke_reason,${reason}) WHERE id=${id}`;
  }
  async revokeAccountSessions(
    accountId: string,
    reason: string,
    now: Date,
  ): Promise<void> {
    await this
      .#sql`UPDATE auth_sessions SET revoked_at=${now},revoke_reason=${reason} WHERE account_id=${accountId} AND revoked_at IS NULL`;
  }
  async getSubscription(accountId: string): Promise<Subscription> {
    const [row] = await this
      .#sql`SELECT * FROM subscriptions WHERE account_id=${accountId} AND provider_environment=${this.config.providerEnvironment}`;
    return row
      ? subscription(row as Row)
      : { accountId, state: "no_subscription", cancelAtPeriodEnd: false };
  }
  async saveSubscription(value: Subscription): Promise<void> {
    await this
      .#sql`INSERT INTO subscriptions(account_id,provider_environment,dodo_subscription_id,product_id,normalized_state,raw_state,period_start,period_end,cancel_at_period_end,provider_updated_at,provider_update_version,checkout_attempt_id) VALUES (${value.accountId},${this.config.providerEnvironment},${
      value.providerId || null
    },${this.config.dodoProductId},${value.state},${value.rawState || null},${
      value.periodStart || null
    },${value.periodEnd || null},${value.cancelAtPeriodEnd},${
      value.providerUpdatedAt || null
    },${value.providerVersion || null},${
      value.checkoutAttemptId || null
    }) ON CONFLICT(account_id) DO UPDATE SET dodo_subscription_id=COALESCE(EXCLUDED.dodo_subscription_id,subscriptions.dodo_subscription_id),normalized_state=EXCLUDED.normalized_state,raw_state=EXCLUDED.raw_state,period_start=EXCLUDED.period_start,period_end=EXCLUDED.period_end,cancel_at_period_end=EXCLUDED.cancel_at_period_end,provider_updated_at=EXCLUDED.provider_updated_at,provider_update_version=EXCLUDED.provider_update_version,checkout_attempt_id=COALESCE(EXCLUDED.checkout_attempt_id,subscriptions.checkout_attempt_id),updated_at=now() WHERE EXCLUDED.provider_updated_at IS NULL OR subscriptions.provider_updated_at IS NULL OR subscriptions.provider_updated_at<EXCLUDED.provider_updated_at OR (subscriptions.provider_updated_at=EXCLUDED.provider_updated_at AND COALESCE(subscriptions.provider_update_version,'')<COALESCE(EXCLUDED.provider_update_version,''))`;
  }
  async beginCheckout(
    accountId: string,
    candidateAttemptId: string,
  ): Promise<string | undefined> {
    return await this.#sql.begin(async (sql) => {
      await sql`SELECT pg_advisory_xact_lock(hashtextextended(${accountId},1))`;
      const [raw] =
        await sql`SELECT * FROM subscriptions WHERE account_id=${accountId} AND provider_environment=${this.config.providerEnvironment} FOR UPDATE`;
      if (!raw) {
        await sql`INSERT INTO subscriptions(account_id,provider_environment,product_id,normalized_state,checkout_attempt_id) VALUES (${accountId},${this.config.providerEnvironment},${this.config.dodoProductId},'checkout_pending',${candidateAttemptId})`;
        return candidateAttemptId;
      }
      const current = subscription(raw as Row);
      if (
        !["no_subscription", "canceled", "expired", "checkout_pending"]
          .includes(current.state)
      ) return undefined;
      const attempt = current.state === "checkout_pending" &&
          current.checkoutAttemptId
        ? current.checkoutAttemptId
        : candidateAttemptId;
      await sql`UPDATE subscriptions SET normalized_state='checkout_pending',checkout_attempt_id=${attempt},updated_at=now() WHERE account_id=${accountId}`;
      return attempt;
    });
  }
  async getBillingCustomer(accountId: string): Promise<string | undefined> {
    const [row] = await this
      .#sql`SELECT dodo_customer_id FROM billing_customers WHERE account_id=${accountId} AND provider_environment=${this.config.providerEnvironment}`;
    return row?.dodo_customer_id as string | undefined;
  }
  async saveBillingCustomer(
    accountId: string,
    customerId: string,
  ): Promise<void> {
    await this
      .#sql`INSERT INTO billing_customers(account_id,provider_environment,dodo_customer_id) VALUES (${accountId},${this.config.providerEnvironment},${customerId}) ON CONFLICT(account_id) DO UPDATE SET updated_at=now() WHERE billing_customers.dodo_customer_id=EXCLUDED.dodo_customer_id`;
    const stored = await this.getBillingCustomer(accountId);
    if (stored !== customerId) throw new Error("customer mapping conflict");
  }
  async reserveUsage(
    reservation: UsageReservation,
    cycleStart: Date | undefined,
    maxCycleRetailMicros: bigint,
    maxConcurrent: number,
    now: Date,
  ): Promise<ReservationResult> {
    return await this.#sql.begin(async (sql) => {
      await sql`SELECT pg_advisory_xact_lock(hashtextextended(${reservation.accountId},0))`;
      const [active] = cycleStart
        ? await sql`SELECT
            (SELECT COALESCE(SUM(retail_micros),0) FROM usage_ledger WHERE account_id=${reservation.accountId} AND created_at>=${cycleStart})::text AS used,
            (SELECT COALESCE(SUM(reserved_retail_micros),0) FROM transcription_requests WHERE account_id=${reservation.accountId} AND state='reserved' AND reservation_expires_at>${now})::text AS reserved,
            (SELECT COUNT(*) FROM transcription_requests WHERE account_id=${reservation.accountId} AND state='reserved' AND reservation_expires_at>${now})::int AS concurrent`
        : await sql`SELECT
            (SELECT COALESCE(SUM(retail_micros),0) FROM usage_ledger WHERE account_id=${reservation.accountId})::text AS used,
            (SELECT COALESCE(SUM(reserved_retail_micros),0) FROM transcription_requests WHERE account_id=${reservation.accountId} AND state='reserved' AND reservation_expires_at>${now})::text AS reserved,
            (SELECT COUNT(*) FROM transcription_requests WHERE account_id=${reservation.accountId} AND state='reserved' AND reservation_expires_at>${now})::int AS concurrent`;
      if (Number(active.concurrent) >= maxConcurrent) {
        return { status: "concurrency_limit" } as const;
      }
      if (
        BigInt(String(active.used)) + BigInt(String(active.reserved)) +
            reservation.reservedRetailMicros >
          maxCycleRetailMicros
      ) return { status: "spend_limit" } as const;
      await sql`INSERT INTO transcription_requests(id,account_id,provider_environment,catalog_id,state,reservation_expires_at,reserved_retail_micros,created_at) VALUES (${reservation.id},${reservation.accountId},${this.config.providerEnvironment},${reservation.catalogId},'reserved',${reservation.expiresAt},${reservation.reservedRetailMicros.toString()},${reservation.createdAt})`;
      return { status: "reserved" } as const;
    });
  }
  async failUsageReservation(
    requestId: string,
    resultClass: string,
    now: Date,
  ): Promise<void> {
    await this
      .#sql`UPDATE transcription_requests SET state='failed',upstream_result_class=${resultClass},finalized_at=${now} WHERE id=${requestId} AND state='reserved'`;
  }
  async finalizeUsage(
    record: UsageRecord,
    payload: Record<string, unknown>,
  ): Promise<void> {
    await this.#sql.begin(async (sql) => {
      const [request] =
        await sql`UPDATE transcription_requests SET state='succeeded',actual_milliseconds=${record.actualMilliseconds},billable_milliseconds=${record.billableMilliseconds},retail_micros=${record.retailMicros.toString()},upstream_result_class='success',finalized_at=${record.createdAt} WHERE id=${record.id} AND account_id=${record.accountId} AND catalog_id=${record.catalogId} AND state='reserved' RETURNING id`;
      if (!request) {
        const [existing] =
          await sql`SELECT state FROM transcription_requests WHERE id=${record.id} FOR UPDATE`;
        if (existing?.state === "succeeded") return;
        throw new Error("usage reservation is not active");
      }
      const [ledger] =
        await sql`INSERT INTO usage_ledger(id,account_id,request_id,entry_type,provider_environment,catalog_id,retail_micros,actual_milliseconds,billable_milliseconds) VALUES (${record.id},${record.accountId},${record.id},'debit',${this.config.providerEnvironment},${record.catalogId},${record.retailMicros.toString()},${record.actualMilliseconds},${record.billableMilliseconds}) ON CONFLICT(id) DO NOTHING RETURNING id`;
      if (ledger) {
        await sql`INSERT INTO usage_outbox(event_id,usage_id,payload) VALUES (${record.eventId},${record.id},${
          sql.json(JSON.parse(JSON.stringify(payload)))
        }) ON CONFLICT(event_id) DO NOTHING`;
      }
    });
  }
  async usageTotal(accountId: string, from?: Date): Promise<bigint> {
    const [row] = from
      ? await this
        .#sql`SELECT COALESCE(SUM(retail_micros),0)::text AS total FROM usage_ledger WHERE account_id=${accountId} AND created_at>=${from}`
      : await this
        .#sql`SELECT COALESCE(SUM(retail_micros),0)::text AS total FROM usage_ledger WHERE account_id=${accountId}`;
    return BigInt(row?.total as string || "0");
  }
  async claimOutbox(limit: number, now: Date) {
    return await this.#sql.begin(async (sql) => {
      const rows =
        await sql`SELECT event_id,payload,attempts FROM usage_outbox WHERE (state='pending' OR (state='leased' AND lease_until<=${now})) AND next_attempt_at<=${now} ORDER BY next_attempt_at FOR UPDATE SKIP LOCKED LIMIT ${limit}`;
      const ids = rows.map((row) => row.event_id as string);
      if (ids.length) {
        await sql`UPDATE usage_outbox SET state='leased',lease_until=${new Date(
          now.getTime() + 15 * 60_000,
        )},attempts=attempts+1 WHERE event_id IN ${sql(ids)}`;
      }
      return rows.map((row) => ({
        eventId: row.event_id as string,
        payload: row.payload as Record<string, unknown>,
        attempts: Number(row.attempts) + 1,
      }));
    });
  }
  async completeOutbox(
    eventId: string,
    success: boolean,
    retryAt?: Date,
    errorClass?: string,
  ): Promise<void> {
    if (success) {
      await this
        .#sql`UPDATE usage_outbox SET state='delivered',delivered_at=now(),lease_until=NULL,provider_response_class=${
        errorClass || "success"
      } WHERE event_id=${eventId}`;
    } else {await this
        .#sql`UPDATE usage_outbox SET state=CASE WHEN attempts>=12 THEN 'dead' ELSE 'pending' END,next_attempt_at=${
        retryAt || new Date(Date.now() + 60_000)
      },lease_until=NULL,provider_response_class=${
        errorClass || "retryable"
      } WHERE event_id=${eventId}`;}
  }
  async storeWebhook(
    provider: "clerk" | "dodo",
    eventId: string,
    type: string,
    payload: Record<string, unknown>,
    now: Date,
  ): Promise<boolean> {
    const rows = await this
      .#sql`INSERT INTO webhook_events(provider,provider_environment,event_id,event_type,verified_at,safe_payload) VALUES (${provider},${this.config.providerEnvironment},${eventId},${type},${now},${
      this.#sql.json(JSON.parse(JSON.stringify(payload)))
    }) ON CONFLICT DO NOTHING RETURNING event_id`;
    return rows.length === 1;
  }
  async markWebhookProcessed(
    provider: "clerk" | "dodo",
    eventId: string,
    errorClass?: string,
  ): Promise<void> {
    if (errorClass) {
      await this
        .#sql`UPDATE webhook_events SET status=CASE WHEN retry_count>=11 THEN 'failed' ELSE 'pending' END,last_error_class=${errorClass},processed_at=NULL,retry_count=retry_count+1 WHERE provider=${provider} AND provider_environment=${this.config.providerEnvironment} AND event_id=${eventId}`;
    } else {
      await this
        .#sql`UPDATE webhook_events SET status='processed',last_error_class=NULL,processed_at=now() WHERE provider=${provider} AND provider_environment=${this.config.providerEnvironment} AND event_id=${eventId}`;
    }
  }
  async listPendingWebhooks(limit: number) {
    const rows = await this
      .#sql`SELECT provider,event_id,event_type,safe_payload FROM webhook_events WHERE provider_environment=${this.config.providerEnvironment} AND status='pending' ORDER BY verified_at LIMIT ${limit}`;
    return rows.map((row) => ({
      provider: row.provider as "clerk" | "dodo",
      eventId: row.event_id as string,
      type: row.event_type as string,
      payload: row.safe_payload as Record<string, unknown>,
    }));
  }
  async cleanup(before: Date, now: Date): Promise<number> {
    const tx = await this
      .#sql`DELETE FROM auth_transactions WHERE expires_at<${now}`;
    const hooks = await this
      .#sql`DELETE FROM webhook_events WHERE verified_at<${before} AND status<>'pending'`;
    const rateLimits = await this
      .#sql`DELETE FROM rate_limit_buckets WHERE updated_at<${before}`;
    return tx.count + hooks.count + rateLimits.count;
  }
  async recoverExpiredReservations(now: Date): Promise<number> {
    const reservations = await this
      .#sql`UPDATE transcription_requests SET state='review',upstream_result_class='reservation_expired',finalized_at=${now} WHERE state='reserved' AND reservation_expires_at<${now}`;
    return reservations.count;
  }
  async acquireJobLease(
    name: string,
    owner: string,
    now: Date,
    seconds: number,
  ): Promise<boolean> {
    const until = new Date(now.getTime() + seconds * 1000);
    const rows = await this
      .#sql`INSERT INTO job_leases(name,owner_id,lease_until) VALUES (${name},${owner},${until}) ON CONFLICT(name) DO UPDATE SET owner_id=EXCLUDED.owner_id,lease_until=EXCLUDED.lease_until,updated_at=now() WHERE job_leases.lease_until<=${now} OR job_leases.owner_id=${owner} RETURNING name`;
    return rows.length === 1;
  }
  async releaseJobLease(name: string, owner: string): Promise<void> {
    await this
      .#sql`DELETE FROM job_leases WHERE name=${name} AND owner_id=${owner}`;
  }
  async consumeRateLimit(
    key: string,
    limit: number,
    windowMs: number,
    now: Date,
  ): Promise<boolean> {
    const windowStart = new Date(
      Math.floor(now.getTime() / windowMs) * windowMs,
    );
    const [row] = await this
      .#sql`INSERT INTO rate_limit_buckets(key,window_start,count) VALUES (${key},${windowStart},1) ON CONFLICT(key) DO UPDATE SET window_start=CASE WHEN rate_limit_buckets.window_start<>EXCLUDED.window_start THEN EXCLUDED.window_start ELSE rate_limit_buckets.window_start END,count=CASE WHEN rate_limit_buckets.window_start<>EXCLUDED.window_start THEN 1 ELSE rate_limit_buckets.count+1 END,updated_at=now() RETURNING count`;
    return Number(row.count) <= limit;
  }
}

function date(value: unknown): Date {
  return value instanceof Date ? value : new Date(String(value));
}
function authTransaction(row: Row): AuthTransaction {
  return {
    id: String(row.id),
    stateHash: String(row.state_hash),
    challenge: String(row.pkce_challenge),
    callbackUri: String(row.callback_uri),
    deviceLabel: row.device_label ? String(row.device_label) : undefined,
    clerkSubject: row.clerk_subject ? String(row.clerk_subject) : undefined,
    clerkEmail: row.clerk_email ? String(row.clerk_email) : undefined,
    codeHash: row.code_hash ? String(row.code_hash) : undefined,
    expiresAt: date(row.expires_at),
    consumedAt: row.consumed_at ? date(row.consumed_at) : undefined,
  };
}
function account(row: Row): Account {
  return {
    id: String(row.id),
    clerkSubject: String(row.clerk_subject),
    email: row.email_snapshot ? String(row.email_snapshot) : undefined,
    status: row.status as Account["status"],
    createdAt: date(row.created_at),
  };
}
function session(row: Row): Session {
  return {
    id: String(row.id),
    accountId: String(row.account_id),
    familyId: String(row.family_id),
    refreshHash: String(row.current_refresh_hash),
    previousHashes: Array.isArray(row.used_refresh_hashes)
      ? row.used_refresh_hashes.map(String)
      : [],
    generation: Number(row.generation),
    expiresAt: date(row.expires_at),
    inactiveAt: date(row.inactive_at),
    lastSeenAt: date(row.last_seen_at),
    revokedAt: row.revoked_at ? date(row.revoked_at) : undefined,
    revokeReason: row.revoke_reason ? String(row.revoke_reason) : undefined,
    deviceLabel: row.device_label ? String(row.device_label) : undefined,
    createdAt: date(row.created_at),
  };
}
function subscription(row: Row): Subscription {
  return {
    accountId: String(row.account_id),
    providerId: row.dodo_subscription_id
      ? String(row.dodo_subscription_id)
      : undefined,
    rawState: row.raw_state ? String(row.raw_state) : undefined,
    state: row.normalized_state as SubscriptionState,
    periodStart: row.period_start ? date(row.period_start) : undefined,
    periodEnd: row.period_end ? date(row.period_end) : undefined,
    cancelAtPeriodEnd: Boolean(row.cancel_at_period_end),
    providerUpdatedAt: row.provider_updated_at
      ? date(row.provider_updated_at)
      : undefined,
    providerVersion: row.provider_update_version
      ? String(row.provider_update_version)
      : undefined,
    checkoutAttemptId: row.checkout_attempt_id
      ? String(row.checkout_attempt_id)
      : undefined,
  };
}
