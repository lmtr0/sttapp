import { createApplication, type RequestContext } from "./src/app.ts";
import { ConfigError, loadConfig } from "./src/config.ts";
import {
  type AppDependencies,
  createProductionDependencies,
} from "./src/dependencies.ts";
import { runJobsOnce } from "./src/jobs/run.ts";

interface HyperdriveBinding {
  connectionString: string;
}

interface WorkerBindings {
  HYPERDRIVE: HyperdriveBinding;
  [key: string]: string | HyperdriveBinding | undefined;
}

interface WorkerExecutionContext {
  waitUntil(promise: Promise<unknown>): void;
}

interface WorkerRuntime {
  dependencies: AppDependencies;
  handler: ReturnType<typeof createApplication>;
}

let runtimePromise: Promise<WorkerRuntime> | undefined;

async function createRuntime(env: WorkerBindings): Promise<WorkerRuntime> {
  if (!env.HYPERDRIVE?.connectionString) {
    throw new ConfigError("HYPERDRIVE", "binding is required");
  }
  const values: Record<string, string> = {};
  for (const [key, value] of Object.entries(env)) {
    if (typeof value === "string") values[key] = value;
  }
  values.DATABASE_URL = env.HYPERDRIVE.connectionString;
  const dependencies = await createProductionDependencies(loadConfig(values));
  return {
    dependencies,
    handler: createApplication(dependencies),
  };
}

async function runtime(env: WorkerBindings): Promise<WorkerRuntime> {
  runtimePromise ??= createRuntime(env);
  try {
    return await runtimePromise;
  } catch (error) {
    runtimePromise = undefined;
    throw error;
  }
}

function requestContext(request: Request): RequestContext {
  const peerIp = request.headers.get("cf-connecting-ip")?.trim();
  return peerIp ? { peerIp } : {};
}

export default {
  async fetch(request: Request, env: WorkerBindings): Promise<Response> {
    const active = await runtime(env);
    return active.handler(request, requestContext(request));
  },

  scheduled(
    _controller: unknown,
    env: WorkerBindings,
    context: WorkerExecutionContext,
  ): void {
    context.waitUntil(
      (async () => {
        const active = await runtime(env);
        const result = await runJobsOnce(active.dependencies);
        active.dependencies.logger.log({
          event: result.skipped ? "jobs.skipped" : "jobs.complete",
          reason: result.skipped ? "lease_held" : undefined,
          usage_events: result.usageEvents,
          webhook_events: result.webhookEvents,
          retained_deleted: result.retainedDeleted,
          reservations_for_review: result.reservationsForReview,
        });
      })(),
    );
  },
};
