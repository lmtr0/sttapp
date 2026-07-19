import { loadConfig } from "../config.ts";
import { createProductionDependencies } from "../dependencies.ts";
import { runJobsOnce } from "./run.ts";

const config = loadConfig(Deno.env.toObject());
const deps = await createProductionDependencies(config);
try {
  const result = await runJobsOnce(deps);
  if (result.skipped) {
    console.log(
      JSON.stringify({ event: "jobs.skipped", reason: "lease_held" }),
    );
  } else {
    console.log(
      JSON.stringify({
        event: "jobs.complete",
        usage_events: result.usageEvents,
        webhook_events: result.webhookEvents,
        retained_deleted: result.retainedDeleted,
        reservations_for_review: result.reservationsForReview,
      }),
    );
  }
} finally {
  await deps.repository.close();
}
