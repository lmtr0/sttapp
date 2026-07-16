import { loadConfig } from "../config.ts";
import { createProductionDependencies } from "../dependencies.ts";
import { runOutbox, runWebhooks } from "./processors.ts";

const config = loadConfig(Deno.env.toObject());
const deps = await createProductionDependencies(config);
const owner = crypto.randomUUID();
try {
  if (
    !await deps.repository.acquireJobLease(
      "default-workers",
      owner,
      new Date(),
      300,
    )
  ) {
    console.log(
      JSON.stringify({ event: "jobs.skipped", reason: "lease_held" }),
    );
    Deno.exit(0);
  }
  const [usageEvents, webhookEvents] = await Promise.all([
    runOutbox(deps),
    runWebhooks(deps),
  ]);
  const now = new Date();
  const deleted = await deps.repository.cleanup(
    new Date(now.getTime() - config.retentionDays * 86_400_000),
    now,
  );
  const reservationsForReview = await deps.repository
    .recoverExpiredReservations(now);
  console.log(
    JSON.stringify({
      event: "jobs.complete",
      usage_events: usageEvents,
      webhook_events: webhookEvents,
      retained_deleted: deleted,
      reservations_for_review: reservationsForReview,
    }),
  );
} finally {
  await deps.repository.releaseJobLease("default-workers", owner);
  await deps.repository.close();
}
