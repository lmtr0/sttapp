import { assertEquals } from "@std/assert";
import {
  normalizeDodoState,
  runOutbox,
  runWebhooks,
} from "../src/jobs/processors.ts";
import { runJobsOnce } from "../src/jobs/run.ts";
import { redact } from "../src/observability.ts";
import { testDependencies } from "./helpers.ts";

Deno.test("redaction recursively removes credentials and content", () => {
  assertEquals(
    redact({
      authorization: "Bearer canary",
      nested: { transcript: "canary text", ok: 1 },
    }),
    {
      authorization: "[REDACTED]",
      nested: { transcript: "[REDACTED]", ok: 1 },
    },
  );
});
Deno.test("subscription states normalize provider changes", () => {
  assertEquals(normalizeDodoState("active"), "active");
  assertEquals(normalizeDodoState("on_hold"), "on_hold");
  assertEquals(normalizeDodoState("future_status"), "billing_unknown");
});
Deno.test("Dodo data.object metadata binds the subscription and older events lose", async () => {
  const deps = await testDependencies();
  const account = await deps.repository.getOrCreateAccount("user_webhook");
  const updatedAt = new Date("2026-07-16T12:00:00Z");
  await deps.repository.storeWebhook(
    "dodo",
    "msg_new",
    "subscription.active",
    {
      created_at: updatedAt.toISOString(),
      data: {
        object: {
          id: "sub_test",
          status: "active",
          metadata: { sttapp_account_id: account.id },
        },
      },
    },
    new Date(),
  );
  assertEquals(await runWebhooks(deps), 1);
  assertEquals(
    (await deps.repository.getSubscription(account.id)).state,
    "active",
  );
  await deps.repository.saveSubscription({
    accountId: account.id,
    state: "canceled",
    cancelAtPeriodEnd: false,
    providerUpdatedAt: new Date("2026-07-16T11:59:59Z"),
    providerVersion: "msg_old",
  });
  assertEquals(
    (await deps.repository.getSubscription(account.id)).state,
    "active",
  );
});
Deno.test("outbox worker leases and delivers exactly one logical event", async () => {
  const deps = await testDependencies();
  const accountId = crypto.randomUUID();
  const id = crypto.randomUUID();
  assertEquals(
    await deps.repository.reserveUsage(
      {
        id,
        accountId,
        catalogId: "test-turbo",
        reservedRetailMicros: 134n,
        expiresAt: new Date(Date.now() + 60_000),
        createdAt: new Date(),
      },
      undefined,
      1000n,
      1,
      new Date(),
    ),
    { status: "reserved" },
  );
  await deps.repository.finalizeUsage({
    id,
    accountId,
    catalogId: "test-turbo",
    actualMilliseconds: 1000,
    billableMilliseconds: 10000,
    retailMicros: 134n,
    eventId: "usage_test",
    createdAt: new Date(),
  }, { event_id: "usage_test" });
  assertEquals(await runOutbox(deps), 1);
  assertEquals(await runOutbox(deps), 0);
  assertEquals(deps.dodo.usage.length, 1);
});

Deno.test("scheduled jobs release their lease and skip a competing run", async () => {
  const deps = await testDependencies();
  const first = await runJobsOnce(deps);
  assertEquals(first.skipped, false);
  assertEquals(first.usageEvents, 0);
  assertEquals(
    await deps.repository.acquireJobLease(
      "default-workers",
      "competing-worker",
      deps.now(),
      300,
    ),
    true,
  );
  assertEquals((await runJobsOnce(deps)).skipped, true);
});

Deno.test("live reservations enforce concurrency and spend before provider work", async () => {
  const deps = await testDependencies();
  const now = new Date();
  const accountId = crypto.randomUUID();
  const reservation = (id: string, amount: bigint) => ({
    id,
    accountId,
    catalogId: "test-turbo",
    reservedRetailMicros: amount,
    expiresAt: new Date(now.getTime() + 60_000),
    createdAt: now,
  });
  assertEquals(
    await deps.repository.reserveUsage(
      reservation("first", 400n),
      undefined,
      1000n,
      1,
      now,
    ),
    { status: "reserved" },
  );
  assertEquals(
    await deps.repository.reserveUsage(
      reservation("second", 1n),
      undefined,
      1000n,
      1,
      now,
    ),
    { status: "concurrency_limit" },
  );
  await deps.repository.failUsageReservation("first", "upstream_error", now);
  assertEquals(
    await deps.repository.reserveUsage(
      reservation("third", 1001n),
      undefined,
      1000n,
      1,
      now,
    ),
    { status: "spend_limit" },
  );
});
