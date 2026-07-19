import type { AppDependencies } from "../dependencies.ts";
import { runOutbox, runWebhooks } from "./processors.ts";

export interface JobRunResult {
  skipped: boolean;
  usageEvents: number;
  webhookEvents: number;
  retainedDeleted: number;
  reservationsForReview: number;
}

export async function runJobsOnce(
  deps: AppDependencies,
): Promise<JobRunResult> {
  const owner = crypto.randomUUID();
  if (
    !await deps.repository.acquireJobLease(
      "default-workers",
      owner,
      deps.now(),
      300,
    )
  ) {
    return {
      skipped: true,
      usageEvents: 0,
      webhookEvents: 0,
      retainedDeleted: 0,
      reservationsForReview: 0,
    };
  }

  try {
    const [usageEvents, webhookEvents] = await Promise.all([
      runOutbox(deps),
      runWebhooks(deps),
    ]);
    const now = deps.now();
    const retainedDeleted = await deps.repository.cleanup(
      new Date(
        now.getTime() - deps.config.retentionDays * 86_400_000,
      ),
      now,
    );
    const reservationsForReview = await deps.repository
      .recoverExpiredReservations(now);
    return {
      skipped: false,
      usageEvents,
      webhookEvents,
      retainedDeleted,
      reservationsForReview,
    };
  } finally {
    await deps.repository.releaseJobLease("default-workers", owner);
  }
}
