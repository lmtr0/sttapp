import type { AppConfig } from "./config.ts";
import {
  AuthService,
  type BrowserAuthenticator,
  ClerkBrowserAuthenticator,
  TokenService,
} from "./auth.ts";
import { JsonLogger, type Logger } from "./observability.ts";
import {
  type DodoClient,
  FetchDodoClient,
  FetchGroqClient,
  type GroqClient,
} from "./providers.ts";
import { type RateLimiter, RepositoryRateLimiter } from "./rate_limit.ts";
import type { Repository } from "./repository.ts";
import { PostgresRepository } from "./db/postgres.ts";

export interface AppDependencies {
  config: AppConfig;
  repository: Repository;
  tokens: TokenService;
  auth: AuthService;
  groq: GroqClient;
  dodo: DodoClient;
  limiter: RateLimiter;
  logger: Logger;
  now(): Date;
}

export async function createDependencies(options: {
  config: AppConfig;
  repository: Repository;
  browser: BrowserAuthenticator;
  groq: GroqClient;
  dodo: DodoClient;
  limiter?: RateLimiter;
  logger?: Logger;
  now?: () => Date;
}): Promise<AppDependencies> {
  const limiter = options.limiter ||
    new RepositoryRateLimiter(options.repository);
  const tokens = await TokenService.create(options.config, options.repository);
  return {
    ...options,
    limiter,
    tokens,
    auth: new AuthService(
      options.config,
      options.repository,
      tokens,
      options.browser,
      limiter,
    ),
    logger: options.logger || new JsonLogger(),
    now: options.now || (() => new Date()),
  };
}

export async function createProductionDependencies(
  config: AppConfig,
): Promise<AppDependencies> {
  const repository = new PostgresRepository(config);
  await repository.ensureCatalog(config.catalog);
  const browser = new ClerkBrowserAuthenticator(config);
  return createDependencies({
    config,
    repository,
    browser,
    groq: new FetchGroqClient(config),
    dodo: new FetchDodoClient(config),
  });
}
