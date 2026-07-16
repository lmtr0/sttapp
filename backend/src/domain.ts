export type Environment = "development" | "test" | "production";
export type ProviderEnvironment = "test" | "live";
export type SubscriptionState =
  | "no_subscription"
  | "checkout_pending"
  | "active"
  | "canceling"
  | "past_due"
  | "on_hold"
  | "canceled"
  | "expired"
  | "billing_unknown";

export interface Account {
  id: string;
  clerkSubject: string;
  email?: string;
  status: "active" | "suspended" | "deleting" | "deleted";
  createdAt: Date;
}

export interface AuthTransaction {
  id: string;
  stateHash: string;
  challenge: string;
  callbackUri: string;
  deviceLabel?: string;
  clerkSubject?: string;
  clerkEmail?: string;
  codeHash?: string;
  expiresAt: Date;
  consumedAt?: Date;
}

export interface Session {
  id: string;
  accountId: string;
  familyId: string;
  refreshHash: string;
  previousHashes: string[];
  generation: number;
  expiresAt: Date;
  inactiveAt: Date;
  lastSeenAt: Date;
  revokedAt?: Date;
  revokeReason?: string;
  deviceLabel?: string;
  createdAt: Date;
}

export interface Subscription {
  accountId: string;
  providerId?: string;
  rawState?: string;
  state: SubscriptionState;
  periodStart?: Date;
  periodEnd?: Date;
  cancelAtPeriodEnd: boolean;
  providerUpdatedAt?: Date;
  providerVersion?: string;
  checkoutAttemptId?: string;
}

export interface CatalogEntry {
  id: string;
  publicModel: string;
  upstreamModel: string;
  currency: "USD";
  upstreamMicrosPerHour: bigint;
  retailMicrosPerHour: bigint;
  markupBasisPoints: number;
  minimumBillableSeconds: number;
  meterId: string;
  eventName: string;
  effectiveFrom: Date;
  effectiveTo?: Date;
  enabled: boolean;
}

export interface UsageRecord {
  id: string;
  accountId: string;
  catalogId: string;
  actualMilliseconds: number;
  billableMilliseconds: number;
  retailMicros: bigint;
  eventId: string;
  createdAt: Date;
}

export interface UsageReservation {
  id: string;
  accountId: string;
  catalogId: string;
  reservedRetailMicros: bigint;
  expiresAt: Date;
  createdAt: Date;
}

export interface Principal {
  account: Account;
  session: Session;
}

export function hasHostedEntitlement(state: SubscriptionState): boolean {
  return state === "active" || state === "canceling";
}

const transitionMap: Record<SubscriptionState, ReadonlySet<SubscriptionState>> =
  {
    no_subscription: new Set(["checkout_pending", "active", "billing_unknown"]),
    checkout_pending: new Set(["active", "no_subscription", "billing_unknown"]),
    active: new Set([
      "active",
      "canceling",
      "past_due",
      "on_hold",
      "canceled",
      "expired",
      "billing_unknown",
    ]),
    canceling: new Set([
      "active",
      "canceling",
      "past_due",
      "canceled",
      "expired",
      "billing_unknown",
    ]),
    past_due: new Set([
      "active",
      "on_hold",
      "canceled",
      "expired",
      "billing_unknown",
    ]),
    on_hold: new Set(["active", "canceled", "expired", "billing_unknown"]),
    canceled: new Set(["active", "expired", "billing_unknown"]),
    expired: new Set(["active", "billing_unknown"]),
    billing_unknown: new Set([
      "no_subscription",
      "checkout_pending",
      "active",
      "canceling",
      "past_due",
      "on_hold",
      "canceled",
      "expired",
    ]),
  };

export function canTransitionSubscription(
  from: SubscriptionState,
  to: SubscriptionState,
): boolean {
  return transitionMap[from].has(to);
}
