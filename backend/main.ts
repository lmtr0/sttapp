import { createApplication } from "./src/app.ts";
import { loadConfig } from "./src/config.ts";
import { createProductionDependencies } from "./src/dependencies.ts";

export { createApplication } from "./src/app.ts";
export type { AppDependencies } from "./src/dependencies.ts";

if (import.meta.main) {
  const config = loadConfig(Deno.env.toObject());
  const dependencies = await createProductionDependencies(config);
  const handler = createApplication(dependencies);
  console.log(JSON.stringify({ event: "server.started", port: config.port }));
  Deno.serve(
    { port: config.port },
    (request, info) =>
      handler(request, {
        peerIp: "hostname" in info.remoteAddr
          ? info.remoteAddr.hostname
          : undefined,
      }),
  );
}
