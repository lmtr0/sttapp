import type {
  Account,
  AuthTransaction,
  CatalogEntry,
  Session,
  Subscription,
  UsageRecord,
  UsageReservation,
} from "./domain.ts";

export interface NewSession {
  id: string;
  familyId: string;
  refreshHash: string;
  expiresAt: Date;
  inactiveAt: Date;
  deviceLabel?: string;
  createdAt: Date;
}

export type RotationResult =
  | { status: "rotated"; session: Session }
  | { status: "reused" | "invalid" | "expired" };

export type ReservationResult =
  | { status: "reserved" }
  | { status: "spend_limit" | "concurrency_limit" };

export interface Repository {
  ready(): Promise<boolean>;
  close(): Promise<void>;
  ensureCatalog(entries: readonly CatalogEntry[]): Promise<void>;
  createAuthTransaction(transaction: AuthTransaction): Promise<void>;
  getAuthTransaction(id: string): Promise<AuthTransaction | undefined>;
  bindAuthTransaction(
    id: string,
    clerkSubject: string,
    clerkEmail: string | undefined,
    codeHash: string,
    now: Date,
  ): Promise<AuthTransaction | undefined>;
  exchangeAuthTransaction(
    id: string,
    codeHash: string,
    now: Date,
    session: NewSession,
  ): Promise<{ account: Account; session?: Session } | undefined>;
  getOrCreateAccount(clerkSubject: string, email?: string): Promise<Account>;
  getAccount(id: string): Promise<Account | undefined>;
  findAccountByClerkSubject(subject: string): Promise<Account | undefined>;
  setAccountStatus(id: string, status: Account["status"]): Promise<void>;
  saveSession(session: Session): Promise<void>;
  getSession(id: string): Promise<Session | undefined>;
  rotateSession(
    id: string,
    presentedHash: string,
    nextHash: string,
    now: Date,
  ): Promise<RotationResult>;
  revokeSessionIfRefreshMatches(
    id: string,
    presentedHash: string,
    reason: string,
    now: Date,
  ): Promise<void>;
  revokeSession(id: string, reason: string, now: Date): Promise<void>;
  revokeAccountSessions(
    accountId: string,
    reason: string,
    now: Date,
  ): Promise<void>;
  getSubscription(accountId: string): Promise<Subscription>;
  saveSubscription(subscription: Subscription): Promise<void>;
  beginCheckout(
    accountId: string,
    candidateAttemptId: string,
  ): Promise<string | undefined>;
  getBillingCustomer(accountId: string): Promise<string | undefined>;
  saveBillingCustomer(accountId: string, customerId: string): Promise<void>;
  reserveUsage(
    reservation: UsageReservation,
    cycleStart: Date | undefined,
    maxCycleRetailMicros: bigint,
    maxConcurrent: number,
    now: Date,
  ): Promise<ReservationResult>;
  failUsageReservation(
    requestId: string,
    resultClass: string,
    now: Date,
  ): Promise<void>;
  finalizeUsage(
    record: UsageRecord,
    payload: Record<string, unknown>,
  ): Promise<void>;
  usageTotal(accountId: string, from?: Date): Promise<bigint>;
  claimOutbox(
    limit: number,
    now: Date,
  ): Promise<
    Array<
      { eventId: string; payload: Record<string, unknown>; attempts: number }
    >
  >;
  completeOutbox(
    eventId: string,
    success: boolean,
    retryAt?: Date,
    errorClass?: string,
  ): Promise<void>;
  storeWebhook(
    provider: "clerk" | "dodo",
    eventId: string,
    type: string,
    payload: Record<string, unknown>,
    now: Date,
  ): Promise<boolean>;
  markWebhookProcessed(
    provider: "clerk" | "dodo",
    eventId: string,
    errorClass?: string,
  ): Promise<void>;
  listPendingWebhooks(
    limit: number,
  ): Promise<
    Array<
      {
        provider: "clerk" | "dodo";
        eventId: string;
        type: string;
        payload: Record<string, unknown>;
      }
    >
  >;
  cleanup(before: Date, now: Date): Promise<number>;
  recoverExpiredReservations(now: Date): Promise<number>;
  acquireJobLease(
    name: string,
    owner: string,
    now: Date,
    seconds: number,
  ): Promise<boolean>;
  releaseJobLease(name: string, owner: string): Promise<void>;
  consumeRateLimit(
    key: string,
    limit: number,
    windowMs: number,
    now: Date,
  ): Promise<boolean>;
}

export class MemoryRepository implements Repository {
  readonly transactions = new Map<string, AuthTransaction>();
  readonly accounts = new Map<string, Account>();
  readonly accountBySubject = new Map<string, string>();
  readonly sessions = new Map<string, Session>();
  readonly subscriptions = new Map<string, Subscription>();
  readonly customers = new Map<string, string>();
  readonly usages = new Map<string, UsageRecord>();
  readonly reservations = new Map<
    string,
    UsageReservation & {
      state: "reserved" | "failed" | "succeeded" | "review";
    }
  >();
  readonly outbox = new Map<
    string,
    {
      eventId: string;
      payload: Record<string, unknown>;
      attempts: number;
      state: "pending" | "leased" | "delivered" | "dead";
      nextAttempt: Date;
      leaseUntil?: Date;
      errorClass?: string;
    }
  >();
  readonly webhooks = new Map<
    string,
    {
      provider: "clerk" | "dodo";
      eventId: string;
      type: string;
      payload: Record<string, unknown>;
      status: "pending" | "processed" | "failed";
      retryCount: number;
      receivedAt: Date;
    }
  >();
  readonly leases = new Map<string, { owner: string; until: Date }>();
  readonly rateLimits = new Map<
    string,
    { windowStart: number; count: number }
  >();

  async ready(): Promise<boolean> {
    return true;
  }
  async close(): Promise<void> {}
  async ensureCatalog(_entries: readonly CatalogEntry[]): Promise<void> {}
  async createAuthTransaction(transaction: AuthTransaction): Promise<void> {
    if (
      this.transactions.has(transaction.id) ||
      [...this.transactions.values()].some((item) =>
        item.stateHash === transaction.stateHash
      )
    ) throw new Error("duplicate transaction");
    this.transactions.set(transaction.id, structuredClone(transaction));
  }
  async getAuthTransaction(id: string): Promise<AuthTransaction | undefined> {
    const value = this.transactions.get(id);
    return value && structuredClone(value);
  }
  async bindAuthTransaction(
    id: string,
    clerkSubject: string,
    clerkEmail: string | undefined,
    codeHash: string,
    now: Date,
  ): Promise<AuthTransaction | undefined> {
    const tx = this.transactions.get(id);
    if (!tx || tx.expiresAt <= now || tx.consumedAt || tx.clerkSubject) {
      return undefined;
    }
    tx.clerkSubject = clerkSubject;
    tx.clerkEmail = clerkEmail;
    tx.codeHash = codeHash;
    return structuredClone(tx);
  }
  async exchangeAuthTransaction(
    id: string,
    codeHash: string,
    now: Date,
    next: NewSession,
  ): Promise<{ account: Account; session?: Session } | undefined> {
    const tx = this.transactions.get(id);
    if (
      !tx || tx.expiresAt <= now || tx.consumedAt || tx.codeHash !== codeHash ||
      !tx.clerkSubject
    ) return undefined;
    const existing = this.accountBySubject.get(tx.clerkSubject);
    let account = existing ? this.accounts.get(existing)! : undefined;
    if (!account) {
      account = {
        id: crypto.randomUUID(),
        clerkSubject: tx.clerkSubject,
        email: tx.clerkEmail,
        status: "active",
        createdAt: now,
      };
      this.accounts.set(account.id, account);
      this.accountBySubject.set(account.clerkSubject, account.id);
    } else if (tx.clerkEmail) account.email = tx.clerkEmail;
    tx.consumedAt = now;
    if (account.status !== "active") {
      return { account: structuredClone(account) };
    }
    const session: Session = {
      ...next,
      accountId: account.id,
      previousHashes: [],
      generation: 0,
      lastSeenAt: now,
    };
    this.sessions.set(session.id, structuredClone(session));
    return {
      account: structuredClone(account),
      session: structuredClone(session),
    };
  }
  async getOrCreateAccount(
    clerkSubject: string,
    email?: string,
  ): Promise<Account> {
    const existing = this.accountBySubject.get(clerkSubject);
    if (existing) return structuredClone(this.accounts.get(existing)!);
    const account: Account = {
      id: crypto.randomUUID(),
      clerkSubject,
      email,
      status: "active",
      createdAt: new Date(),
    };
    this.accounts.set(account.id, account);
    this.accountBySubject.set(clerkSubject, account.id);
    return structuredClone(account);
  }
  async getAccount(id: string): Promise<Account | undefined> {
    const value = this.accounts.get(id);
    return value && structuredClone(value);
  }
  async findAccountByClerkSubject(
    subject: string,
  ): Promise<Account | undefined> {
    const id = this.accountBySubject.get(subject);
    return id ? this.getAccount(id) : undefined;
  }
  async setAccountStatus(id: string, status: Account["status"]): Promise<void> {
    const account = this.accounts.get(id);
    if (account) account.status = status;
  }
  async saveSession(session: Session): Promise<void> {
    this.sessions.set(session.id, structuredClone(session));
  }
  async getSession(id: string): Promise<Session | undefined> {
    const value = this.sessions.get(id);
    return value && structuredClone(value);
  }
  async rotateSession(
    id: string,
    presentedHash: string,
    nextHash: string,
    now: Date,
  ): Promise<RotationResult> {
    const session = this.sessions.get(id);
    if (!session || session.revokedAt) return { status: "invalid" };
    if (session.expiresAt <= now || session.inactiveAt <= now) {
      session.revokedAt = now;
      session.revokeReason = "expired";
      return { status: "expired" };
    }
    if (session.previousHashes.includes(presentedHash)) {
      session.revokedAt = now;
      session.revokeReason = "refresh_reuse";
      return { status: "reused" };
    }
    if (session.refreshHash !== presentedHash) return { status: "invalid" };
    const inactivityWindow = Math.max(
      1,
      session.inactiveAt.getTime() - session.lastSeenAt.getTime(),
    );
    session.previousHashes.push(session.refreshHash);
    session.refreshHash = nextHash;
    session.generation++;
    session.lastSeenAt = now;
    session.inactiveAt = new Date(
      Math.min(session.expiresAt.getTime(), now.getTime() + inactivityWindow),
    );
    return { status: "rotated", session: structuredClone(session) };
  }
  async revokeSessionIfRefreshMatches(
    id: string,
    presentedHash: string,
    reason: string,
    now: Date,
  ): Promise<void> {
    const session = this.sessions.get(id);
    if (
      session &&
      (session.refreshHash === presentedHash ||
        session.previousHashes.includes(presentedHash)) &&
      !session.revokedAt
    ) {
      session.revokedAt = now;
      session.revokeReason = reason;
    }
  }
  async revokeSession(id: string, reason: string, now: Date): Promise<void> {
    const session = this.sessions.get(id);
    if (session && !session.revokedAt) {
      session.revokedAt = now;
      session.revokeReason = reason;
    }
  }
  async revokeAccountSessions(
    accountId: string,
    reason: string,
    now: Date,
  ): Promise<void> {
    for (const session of this.sessions.values()) {
      if (session.accountId === accountId && !session.revokedAt) {
        session.revokedAt = now;
        session.revokeReason = reason;
      }
    }
  }
  async getSubscription(accountId: string): Promise<Subscription> {
    return structuredClone(
      this.subscriptions.get(accountId) ||
        { accountId, state: "no_subscription", cancelAtPeriodEnd: false },
    );
  }
  async saveSubscription(subscription: Subscription): Promise<void> {
    const current = this.subscriptions.get(subscription.accountId);
    if (
      current?.providerUpdatedAt && subscription.providerUpdatedAt &&
      (current.providerUpdatedAt > subscription.providerUpdatedAt ||
        (current.providerUpdatedAt.getTime() ===
            subscription.providerUpdatedAt.getTime() &&
          (current.providerVersion || "") >=
            (subscription.providerVersion || "")))
    ) return;
    this.subscriptions.set(
      subscription.accountId,
      structuredClone(subscription),
    );
  }
  async beginCheckout(
    accountId: string,
    candidateAttemptId: string,
  ): Promise<string | undefined> {
    const current: Subscription = structuredClone(
      this.subscriptions.get(accountId) ||
        {
          accountId,
          state: "no_subscription" as const,
          cancelAtPeriodEnd: false,
        },
    );
    if (
      !["no_subscription", "canceled", "expired", "checkout_pending"]
        .includes(current.state)
    ) return undefined;
    const attempt = current.state === "checkout_pending" &&
        current.checkoutAttemptId
      ? current.checkoutAttemptId
      : candidateAttemptId;
    this.subscriptions.set(accountId, {
      ...current,
      state: "checkout_pending",
      checkoutAttemptId: attempt,
    });
    return attempt;
  }
  async getBillingCustomer(accountId: string): Promise<string | undefined> {
    return this.customers.get(accountId);
  }
  async saveBillingCustomer(
    accountId: string,
    customerId: string,
  ): Promise<void> {
    const existing = this.customers.get(accountId);
    if (existing && existing !== customerId) {
      throw new Error("customer mapping conflict");
    }
    if (
      [...this.customers].some(([account, value]) =>
        account !== accountId && value === customerId
      )
    ) throw new Error("customer already mapped");
    this.customers.set(accountId, customerId);
  }
  async reserveUsage(
    reservation: UsageReservation,
    cycleStart: Date | undefined,
    maxCycleRetailMicros: bigint,
    maxConcurrent: number,
    now: Date,
  ): Promise<ReservationResult> {
    const active = [...this.reservations.values()].filter((item) =>
      item.accountId === reservation.accountId && item.state === "reserved" &&
      item.expiresAt > now
    );
    if (active.length >= maxConcurrent) return { status: "concurrency_limit" };
    const used = await this.usageTotal(reservation.accountId, cycleStart);
    const reserved = active.reduce(
      (sum, item) => sum + item.reservedRetailMicros,
      0n,
    );
    if (
      used + reserved + reservation.reservedRetailMicros >
        maxCycleRetailMicros
    ) return { status: "spend_limit" };
    if (this.reservations.has(reservation.id)) {
      throw new Error("duplicate request");
    }
    this.reservations.set(reservation.id, {
      ...structuredClone(reservation),
      state: "reserved",
    });
    return { status: "reserved" };
  }
  async failUsageReservation(
    requestId: string,
    resultClass: string,
    _now: Date,
  ): Promise<void> {
    const reservation = this.reservations.get(requestId);
    if (reservation?.state === "reserved") {
      reservation.state = resultClass === "success" ? "succeeded" : "failed";
    }
  }
  async finalizeUsage(
    record: UsageRecord,
    payload: Record<string, unknown>,
  ): Promise<void> {
    if (this.usages.has(record.id) || this.outbox.has(record.eventId)) return;
    const reservation = this.reservations.get(record.id);
    if (!reservation || reservation.state !== "reserved") {
      throw new Error("usage reservation is not active");
    }
    reservation.state = "succeeded";
    this.usages.set(record.id, structuredClone(record));
    this.outbox.set(record.eventId, {
      eventId: record.eventId,
      payload: structuredClone(payload),
      attempts: 0,
      state: "pending",
      nextAttempt: new Date(),
    });
  }
  async usageTotal(accountId: string, from?: Date): Promise<bigint> {
    let total = 0n;
    for (const record of this.usages.values()) {
      if (
        record.accountId === accountId && (!from || record.createdAt >= from)
      ) total += record.retailMicros;
    }
    return total;
  }
  async claimOutbox(limit: number, now: Date) {
    const result = [];
    for (const item of this.outbox.values()) {
      if (result.length >= limit) break;
      if (
        (item.state === "pending" ||
          (item.state === "leased" && item.leaseUntil! <= now)) &&
        item.nextAttempt <= now
      ) {
        item.state = "leased";
        item.leaseUntil = new Date(now.getTime() + 60_000);
        item.attempts++;
        result.push({
          eventId: item.eventId,
          payload: structuredClone(item.payload),
          attempts: item.attempts,
        });
      }
    }
    return result;
  }
  async completeOutbox(
    eventId: string,
    success: boolean,
    retryAt?: Date,
    errorClass?: string,
  ): Promise<void> {
    const item = this.outbox.get(eventId);
    if (!item) return;
    item.errorClass = errorClass;
    if (success) item.state = "delivered";
    else if (item.attempts >= 12) item.state = "dead";
    else {
      item.state = "pending";
      item.nextAttempt = retryAt || new Date(Date.now() + 60_000);
    }
  }
  async storeWebhook(
    provider: "clerk" | "dodo",
    eventId: string,
    type: string,
    payload: Record<string, unknown>,
    now: Date,
  ): Promise<boolean> {
    const key = `${provider}:${eventId}`;
    if (this.webhooks.has(key)) return false;
    this.webhooks.set(key, {
      provider,
      eventId,
      type,
      payload: structuredClone(payload),
      status: "pending",
      retryCount: 0,
      receivedAt: now,
    });
    return true;
  }
  async markWebhookProcessed(
    provider: "clerk" | "dodo",
    eventId: string,
    errorClass?: string,
  ): Promise<void> {
    const item = this.webhooks.get(`${provider}:${eventId}`);
    if (item) {
      if (errorClass) {
        item.retryCount++;
        item.status = item.retryCount >= 12 ? "failed" : "pending";
      } else item.status = "processed";
    }
  }
  async listPendingWebhooks(limit: number) {
    return [...this.webhooks.values()].filter((item) =>
      item.status === "pending"
    ).slice(0, limit).map(({ provider, eventId, type, payload }) => ({
      provider,
      eventId,
      type,
      payload: structuredClone(payload),
    }));
  }
  async cleanup(before: Date, now: Date): Promise<number> {
    let count = 0;
    for (const [id, tx] of this.transactions) {
      if (tx.expiresAt < now) {
        this.transactions.delete(id);
        count++;
      }
    }
    for (const [key, hook] of this.webhooks) {
      if (hook.receivedAt < before && hook.status !== "pending") {
        this.webhooks.delete(key);
        count++;
      }
    }
    return count;
  }
  async recoverExpiredReservations(now: Date): Promise<number> {
    let count = 0;
    for (const reservation of this.reservations.values()) {
      if (reservation.state === "reserved" && reservation.expiresAt < now) {
        reservation.state = "review";
        count++;
      }
    }
    return count;
  }
  async acquireJobLease(
    name: string,
    owner: string,
    now: Date,
    seconds: number,
  ): Promise<boolean> {
    const current = this.leases.get(name);
    if (current && current.until > now && current.owner !== owner) return false;
    this.leases.set(name, {
      owner,
      until: new Date(now.getTime() + seconds * 1000),
    });
    return true;
  }
  async releaseJobLease(name: string, owner: string): Promise<void> {
    if (this.leases.get(name)?.owner === owner) this.leases.delete(name);
  }
  async consumeRateLimit(
    key: string,
    limit: number,
    windowMs: number,
    now: Date,
  ): Promise<boolean> {
    const windowStart = Math.floor(now.getTime() / windowMs) * windowMs;
    const current = this.rateLimits.get(key);
    if (!current || current.windowStart !== windowStart) {
      this.rateLimits.set(key, { windowStart, count: 1 });
      return true;
    }
    current.count++;
    return current.count <= limit;
  }
}
