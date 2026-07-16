import type { AppDependencies } from "../dependencies.ts";
import type { SubscriptionState } from "../domain.ts";

export async function runOutbox(
  deps: AppDependencies,
  limit = 50,
): Promise<number> {
  const items = await deps.repository.claimOutbox(limit, deps.now());
  for (const item of items) {
    try {
      await deps.dodo.ingestUsage(item.payload);
      await deps.repository.completeOutbox(item.eventId, true);
    } catch (error) {
      const backoff = Math.min(3600, 2 ** Math.min(item.attempts, 10)) * 1000 +
        crypto.getRandomValues(new Uint16Array(1))[0] % 1000;
      await deps.repository.completeOutbox(
        item.eventId,
        false,
        new Date(deps.now().getTime() + backoff),
        error && typeof error === "object" && "code" in error
          ? String(error.code)
          : error instanceof Error
          ? error.name
          : "unknown",
      );
    }
  }
  return items.length;
}

export async function runWebhooks(
  deps: AppDependencies,
  limit = 50,
): Promise<number> {
  const items = await deps.repository.listPendingWebhooks(limit);
  for (const item of items) {
    try {
      if (item.provider === "clerk") {
        await processClerk(item.type, item.payload, deps);
      } else await processDodo(item.type, item.eventId, item.payload, deps);
      await deps.repository.markWebhookProcessed(item.provider, item.eventId);
    } catch (error) {
      await deps.repository.markWebhookProcessed(
        item.provider,
        item.eventId,
        error instanceof Error ? error.name : "unknown",
      );
    }
  }
  return items.length;
}

async function processClerk(
  type: string,
  payload: Record<string, unknown>,
  deps: AppDependencies,
): Promise<void> {
  const data = object(payload.data);
  const subject = string(data.id);
  if (!subject) return;
  if (type === "user.deleted") {
    const account = await deps.repository.findAccountByClerkSubject(subject);
    if (account) {
      await deps.repository.setAccountStatus(account.id, "deleted");
      await deps.repository.revokeAccountSessions(
        account.id,
        "clerk_user_deleted",
        deps.now(),
      );
    }
  }
}

async function processDodo(
  type: string,
  eventId: string,
  payload: Record<string, unknown>,
  deps: AppDependencies,
): Promise<void> {
  const envelope = object(payload.data);
  const data = Object.keys(object(envelope.object)).length
    ? object(envelope.object)
    : envelope;
  const metadata = object(data.metadata);
  const accountId = string(metadata.sttapp_account_id) ||
    string(data.sttapp_account_id);
  if (!accountId) return;
  const current = await deps.repository.getSubscription(accountId);
  const raw = string(data.status) || type;
  const cancelAtPeriodEnd = Boolean(
    data.cancel_at_next_billing_date || data.cancel_at_period_end,
  );
  const normalized = normalizeDodoState(raw, type);
  const state = normalized === "active" && cancelAtPeriodEnd
    ? "canceling"
    : normalized;
  await deps.repository.saveSubscription({
    accountId,
    providerId: string(data.subscription_id) || string(data.id) ||
      current.providerId,
    rawState: raw,
    state,
    periodStart: parsedDate(data.current_period_start) || current.periodStart,
    periodEnd: parsedDate(data.current_period_end) || current.periodEnd,
    cancelAtPeriodEnd,
    providerUpdatedAt: parsedDate(data.updated_at) ||
      parsedDate(payload.created_at) || deps.now(),
    providerVersion: eventId,
  });
}

export function normalizeDodoState(
  raw: string,
  eventType = "",
): SubscriptionState {
  const value = `${raw} ${eventType}`.toLowerCase();
  if (/on.?hold/.test(value)) return "on_hold";
  if (/past.?due|payment.failed/.test(value)) return "past_due";
  if (/cancel.*period|cancel_at/.test(value)) return "canceling";
  if (/expired/.test(value)) return "expired";
  if (/cancel|refund|dispute|chargeback/.test(value)) return "canceled";
  if (/active|renew|payment.succeeded|subscription.created/.test(value)) {
    return "active";
  }
  if (/pending|checkout/.test(value)) return "checkout_pending";
  return "billing_unknown";
}

function object(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : {};
}
function string(value: unknown): string | undefined {
  return typeof value === "string" && value ? value : undefined;
}
function parsedDate(value: unknown): Date | undefined {
  if (typeof value !== "string" && typeof value !== "number") return undefined;
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? undefined : date;
}
