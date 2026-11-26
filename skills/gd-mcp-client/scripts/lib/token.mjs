// Gets a usable access token for a server and refreshes it when it has expired.
import { assertSafeUrl } from "./paths.mjs";
import { CliError, redact } from "./redact.mjs";
import { canSaveSecret, loadSecret, saveSecret } from "./store.mjs";

const SKEW_MS = 60_000;
const TIMEOUT_MS = 30_000;

/**
 * Exchanges the refresh token for a new access token and saves the result. Throws a redacted, actionable error.
 */
export async function refreshToken(name, record, resource) {
  if (!record.refreshToken || !record.tokenEndpoint || !record.clientId) {
    throw new CliError(`the token for ${name} has expired and cannot be refreshed; run gd-mcp-auth login ${name}`);
  }
  assertSafeUrl(record.tokenEndpoint, "token endpoint");
  // Never refresh when the result cannot be saved: a server that rotates refresh tokens would lock out every agent.
  if (!canSaveSecret(name)) {
    throw new CliError(
      `the token for ${name} has expired and this process cannot save a refreshed one (read-only sandbox); ` +
        "run any gd-mcp-client command from a normal terminal or an agent without that sandbox, which refreshes it " +
        "for all",
    );
  }
  const body = new URLSearchParams({
    grant_type: "refresh_token",
    refresh_token: record.refreshToken,
    client_id: record.clientId,
    resource,
  });
  let response;
  try {
    response = await fetch(record.tokenEndpoint, {
      method: "POST",
      body,
      redirect: "manual",
      headers: { "content-type": "application/x-www-form-urlencoded", accept: "application/json" },
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
  } catch (error) {
    throw new CliError(`refresh request failed: ${redact(error.message, [record.refreshToken])}`);
  }
  const data = await response.json().catch(() => ({}));
  if (!response.ok || typeof data.access_token !== "string") {
    const reason = typeof data.error === "string" ? data.error : `HTTP ${response.status}`;
    throw new CliError(`refresh failed (${redact(reason)}); run gd-mcp-auth login ${name}`);
  }
  const next = {
    ...record,
    accessToken: data.access_token,
    refreshToken: data.refresh_token ?? record.refreshToken,
    expiresAt: typeof data.expires_in === "number" ? Date.now() + data.expires_in * 1000 : undefined,
  };
  saveSecret(name, next);
  return next;
}

/**
 * Returns the access token to send to a server, refreshing it first when it is expired or about to expire.
 * With force set, it refreshes even when the stored expiry looks fine (used after a 401).
 */
export async function getAccessToken(name, server, { force = false } = {}) {
  const record = loadSecret(name);
  if (!record?.accessToken) throw new CliError(`no token saved for ${name}; run gd-mcp-auth login ${name}`);
  if (server.auth?.type !== "oauth") {
    if (force) throw new CliError(`the server rejected the saved token for ${name}; run gd-mcp-auth login ${name}`);
    return record.accessToken;
  }
  const expired = typeof record.expiresAt === "number" && record.expiresAt - Date.now() < SKEW_MS;
  if (!force && !expired) return record.accessToken;
  const next = await refreshToken(name, record, server.url);
  return next.accessToken;
}
