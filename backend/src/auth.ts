import {
  createLocalJWKSet,
  createRemoteJWKSet,
  importJWK,
  jwtVerify,
  SignJWT,
} from "jose";
import type { AppConfig } from "./config.ts";
import type { Account, Principal, Session } from "./domain.ts";
import { constantTimeEqual, keyedHash, randomToken, sha256 } from "./crypto.ts";
import {
  ApiError,
  assertOnlyKeys,
  readJson,
  requireObject,
  requireString,
} from "./http.ts";
import type { Repository } from "./repository.ts";
import type { RateLimiter } from "./rate_limit.ts";

export interface BrowserIdentity {
  subject: string;
  email?: string;
}
export interface BrowserAuthenticator {
  authenticate(request: Request): Promise<BrowserIdentity | undefined>;
}

export class ClerkBrowserAuthenticator implements BrowserAuthenticator {
  #jwks;
  constructor(private config: AppConfig) {
    this.#jwks = createRemoteJWKSet(config.clerkJwksUrl);
  }
  async authenticate(request: Request): Promise<BrowserIdentity | undefined> {
    const cookie = request.headers.get("cookie")?.split(";").map((v) =>
      v.trim()
    ).find((v) => v.startsWith("__session="))?.slice(10);
    const bearer = request.headers.get("authorization")?.match(/^Bearer (.+)$/i)
      ?.[1];
    const token = bearer || cookie;
    if (!token) return undefined;
    try {
      const { payload } = await jwtVerify(token, this.#jwks, {
        issuer: this.config.clerkIssuer.href.replace(/\/$/, ""),
        algorithms: ["RS256"],
      });
      if (
        !payload.sub ||
        (typeof payload.azp === "string" &&
          !this.config.clerkAuthorizedParties.includes(payload.azp))
      ) return undefined;
      let email: string | undefined;
      try {
        const response = await fetch(
          `https://api.clerk.com/v1/users/${encodeURIComponent(payload.sub)}`,
          {
            headers: { authorization: `Bearer ${this.config.clerkSecretKey}` },
            signal: AbortSignal.timeout(5000),
          },
        );
        if (response.ok) {
          const user = await response.json() as Record<string, unknown>;
          const addresses = Array.isArray(user.email_addresses)
            ? user.email_addresses
            : [];
          const primary = addresses.find((item) =>
            item && typeof item === "object" &&
            (item as Record<string, unknown>).id ===
              user.primary_email_address_id
          ) as Record<string, unknown> | undefined;
          if (typeof primary?.email_address === "string") {
            email = primary.email_address;
          }
        }
      } catch {
        // Identity verification succeeded; billing setup can recover the profile.
      }
      return { subject: payload.sub, email };
    } catch {
      return undefined;
    }
  }
}

export class TokenService {
  #privateKey: CryptoKey | Uint8Array;
  #jwks;
  private constructor(
    private config: AppConfig,
    private repository: Repository,
    privateKey: CryptoKey | Uint8Array,
  ) {
    this.#privateKey = privateKey;
    this.#jwks = createLocalJWKSet(config.accessPublicJwks);
  }
  static async create(
    config: AppConfig,
    repository: Repository,
  ): Promise<TokenService> {
    return new TokenService(
      config,
      repository,
      await importJWK(config.accessPrivateJwk, "EdDSA") as CryptoKey,
    );
  }
  async issue(
    account: Account,
    session: Session,
  ): Promise<
    {
      access_token: string;
      token_type: "Bearer";
      expires_in: number;
      refresh_token?: string;
      session_id: string;
    }
  > {
    const access_token = await new SignJWT({
      sid: session.id,
      token_type: "sttapp_access",
    })
      .setProtectedHeader({
        alg: "EdDSA",
        kid: this.config.accessKeyId,
        typ: "JWT",
      }).setIssuer(this.config.publicBaseUrl.origin)
      .setAudience("sttapp-desktop").setSubject(account.id).setJti(
        crypto.randomUUID(),
      ).setIssuedAt().setNotBefore("-5s")
      .setExpirationTime(`${this.config.accessTokenSeconds}s`).sign(
        this.#privateKey,
      );
    return {
      access_token,
      token_type: "Bearer",
      expires_in: this.config.accessTokenSeconds,
      session_id: session.id,
    };
  }
  async verify(request: Request): Promise<Principal> {
    const token = request.headers.get("authorization")?.match(
      /^Bearer ([A-Za-z0-9._~-]+)$/,
    )?.[1];
    if (!token) {
      throw new ApiError(
        401,
        "invalid_access_token",
        "Authentication is required.",
        "authentication_error",
      );
    }
    try {
      const { payload, protectedHeader } = await jwtVerify(token, this.#jwks, {
        issuer: this.config.publicBaseUrl.origin,
        audience: "sttapp-desktop",
        algorithms: ["EdDSA"],
        clockTolerance: 10,
        requiredClaims: ["sub", "sid", "jti", "iat", "exp"],
      });
      if (
        protectedHeader.typ !== "JWT" ||
        payload.token_type !== "sttapp_access" ||
        typeof payload.sub !== "string" || typeof payload.sid !== "string"
      ) throw new Error();
      const [account, session] = await Promise.all([
        this.repository.getAccount(payload.sub),
        this.repository.getSession(payload.sid),
      ]);
      if (
        !account || account.status !== "active" || !session ||
        session.accountId !== account.id || session.revokedAt ||
        session.expiresAt <= new Date() || session.inactiveAt <= new Date()
      ) throw new Error();
      return { account, session };
    } catch (error) {
      if (error instanceof ApiError) throw error;
      throw new ApiError(
        401,
        "invalid_access_token",
        "The access token is invalid or expired.",
        "authentication_error",
      );
    }
  }
}

export class AuthService {
  constructor(
    private config: AppConfig,
    private repository: Repository,
    private tokens: TokenService,
    private browser: BrowserAuthenticator,
    private limiter: RateLimiter,
  ) {}

  async start(request: Request, ip: string): Promise<Response> {
    await this.limiter.check(`auth-start:${ip}`, 10, 60_000);
    const body = requireObject(await readJson(request));
    assertOnlyKeys(body, [
      "code_challenge",
      "state",
      "callback_uri",
      "device_label",
    ]);
    const challenge = requireString(body, "code_challenge", 128);
    const state = requireString(body, "state", 256);
    const callbackUri = requireString(body, "callback_uri", 512);
    if (!/^[A-Za-z0-9_-]{43,128}$/.test(challenge)) {
      throw new ApiError(
        400,
        "invalid_pkce_challenge",
        "A valid PKCE S256 challenge is required.",
      );
    }
    if (!/^[A-Za-z0-9_-]{32,256}$/.test(state)) {
      throw new ApiError(
        400,
        "invalid_state",
        "A high-entropy state is required.",
      );
    }
    validateLoopback(callbackUri);
    const id = crypto.randomUUID();
    await this.repository.createAuthTransaction({
      id,
      stateHash: await sha256(state),
      challenge,
      callbackUri,
      deviceLabel: typeof body.device_label === "string"
        ? body.device_label.slice(0, 100)
        : undefined,
      expiresAt: new Date(Date.now() + 5 * 60_000),
    });
    const authorizationUrl = new URL(
      "/authorize/desktop",
      this.config.publicBaseUrl,
    );
    authorizationUrl.searchParams.set("transaction_id", id);
    authorizationUrl.searchParams.set("state", state);
    return Response.json({
      transaction_id: id,
      authorization_url: authorizationUrl.href,
      expires_in: 300,
    });
  }

  async authorize(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const id = url.searchParams.get("transaction_id") || "";
    const state = url.searchParams.get("state") || "";
    const tx = await this.repository.getAuthTransaction(id);
    if (
      !tx || tx.expiresAt <= new Date() || tx.consumedAt ||
      !constantTimeEqual(tx.stateHash, await sha256(state))
    ) {
      return safeHtml(
        "Sign-in expired",
        "Return to sttapp and start sign-in again.",
        410,
      );
    }
    const identity = await this.browser.authenticate(request);
    if (!identity) {
      const signIn = new URL(this.config.clerkSignInUrl);
      signIn.searchParams.set("redirect_url", url.href);
      return Response.redirect(signIn, 302);
    }
    const code = randomToken();
    const bound = await this.repository.bindAuthTransaction(
      id,
      identity.subject,
      identity.email,
      await keyedHash(code, this.config.refreshPepper),
      new Date(),
    );
    if (!bound) {
      return safeHtml(
        "Sign-in unavailable",
        "This sign-in request was already completed.",
        409,
      );
    }
    const callback = new URL(bound.callbackUri);
    callback.searchParams.set("code", code);
    callback.searchParams.set("state", state);
    callback.searchParams.set("transaction_id", id);
    return Response.redirect(callback, 302);
  }

  async exchange(request: Request, ip: string): Promise<Response> {
    await this.limiter.check(`auth-exchange:${ip}`, 20, 60_000);
    const body = requireObject(await readJson(request));
    assertOnlyKeys(body, [
      "transaction_id",
      "code",
      "code_verifier",
      "state",
      "callback_uri",
    ]);
    const id = requireString(body, "transaction_id", 64);
    const code = requireString(body, "code", 256);
    const verifier = requireString(body, "code_verifier", 128);
    const state = requireString(body, "state", 256);
    const callback = requireString(body, "callback_uri", 512);
    if (!/^[A-Za-z0-9._~-]{43,128}$/.test(verifier)) {
      throw new ApiError(
        400,
        "invalid_pkce_verifier",
        "PKCE verifier is invalid.",
      );
    }
    const tx = await this.repository.getAuthTransaction(id);
    if (
      !tx || !constantTimeEqual(tx.stateHash, await sha256(state)) ||
      tx.callbackUri !== callback ||
      !constantTimeEqual(tx.challenge, await sha256(verifier))
    ) {
      throw new ApiError(
        400,
        "invalid_authorization_code",
        "The authorization grant is invalid or expired.",
        "authentication_error",
      );
    }
    const refresh = `${crypto.randomUUID()}.${randomToken(32)}`;
    const now = new Date();
    const exchanged = await this.repository.exchangeAuthTransaction(
      id,
      await keyedHash(code, this.config.refreshPepper),
      now,
      {
        id: crypto.randomUUID(),
        familyId: crypto.randomUUID(),
        refreshHash: await keyedHash(refresh, this.config.refreshPepper),
        createdAt: now,
        expiresAt: new Date(
          now.getTime() + this.config.refreshAbsoluteSeconds * 1000,
        ),
        inactiveAt: new Date(
          now.getTime() + this.config.refreshInactivitySeconds * 1000,
        ),
        deviceLabel: tx.deviceLabel,
      },
    );
    if (!exchanged) {
      throw new ApiError(
        400,
        "invalid_authorization_code",
        "The authorization grant is invalid or expired.",
        "authentication_error",
      );
    }
    if (!exchanged.session || exchanged.account.status !== "active") {
      throw new ApiError(
        403,
        "account_inactive",
        "This account is not available.",
        "permission_error",
      );
    }
    return Response.json({
      ...(await this.tokens.issue(exchanged.account, exchanged.session)),
      refresh_token: `${exchanged.session.id}.${refresh}`,
    });
  }

  async refresh(request: Request, ip: string): Promise<Response> {
    await this.limiter.check(`auth-refresh:${ip}`, 60, 60_000);
    const body = requireObject(await readJson(request));
    assertOnlyKeys(body, ["refresh_token"]);
    const value = requireString(body, "refresh_token", 512);
    const separator = value.indexOf(".");
    const sessionId = separator > 0 ? value.slice(0, separator) : "";
    const raw = separator > 0 ? value.slice(separator + 1) : "";
    const session = await this.repository.getSession(sessionId);
    if (!session) throw refreshError();
    const account = await this.repository.getAccount(session.accountId);
    if (!account || account.status !== "active") throw refreshError();
    const presented = await keyedHash(raw, this.config.refreshPepper);
    const nextRaw = `${crypto.randomUUID()}.${randomToken(32)}`;
    const nextHash = await keyedHash(nextRaw, this.config.refreshPepper);
    const result = await this.repository.rotateSession(
      sessionId,
      presented,
      nextHash,
      new Date(),
    );
    if (result.status !== "rotated") {
      throw refreshError(
        result.status === "reused"
          ? "refresh_token_reused"
          : "invalid_refresh_token",
      );
    }
    return Response.json({
      ...(await this.tokens.issue(account, result.session)),
      refresh_token: `${sessionId}.${nextRaw}`,
    });
  }

  async logout(request: Request): Promise<Response> {
    const body = requireObject(await readJson(request));
    assertOnlyKeys(body, ["refresh_token"]);
    const value = requireString(body, "refresh_token", 512);
    const separator = value.indexOf(".");
    const id = separator > 0 ? value.slice(0, separator) : "";
    const raw = separator > 0 ? value.slice(separator + 1) : "";
    if (id && raw) {
      await this.repository.revokeSessionIfRefreshMatches(
        id,
        await keyedHash(raw, this.config.refreshPepper),
        "logout",
        new Date(),
      );
    }
    return new Response(null, { status: 204 });
  }
}

function refreshError(code = "invalid_refresh_token") {
  return new ApiError(
    401,
    code,
    "The refresh token is invalid, expired, or revoked.",
    "authentication_error",
  );
}
function validateLoopback(raw: string): void {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    throw new ApiError(400, "invalid_callback", "Callback URI is invalid.");
  }
  if (
    url.protocol !== "http:" || url.hostname !== "127.0.0.1" || !url.port ||
    Number(url.port) < 1024 || Number(url.port) > 65535 || url.username ||
    url.password || url.hash
  ) {
    throw new ApiError(
      400,
      "invalid_callback",
      "Only an exact 127.0.0.1 loopback callback is allowed.",
    );
  }
}
function safeHtml(title: string, message: string, status: number): Response {
  return new Response(
    `<!doctype html><html><head><meta charset="utf-8"><title>${title}</title></head><body><main><h1>${title}</h1><p>${message}</p></main></body></html>`,
    {
      status,
      headers: {
        "content-type": "text/html; charset=utf-8",
        "content-security-policy":
          "default-src 'none'; style-src 'unsafe-inline'",
        "cache-control": "no-store",
      },
    },
  );
}
