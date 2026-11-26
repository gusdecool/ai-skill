// OAuth discovery and token requests for an MCP server: RFC 9728 and 8414 discovery, PKCE S256, RFC 8707 resource.
import { createHash, randomBytes } from "node:crypto";
import { assertSafeUrl, CliError, redact } from "./shared.mjs";

const TIMEOUT_MS = 30_000;

/**
 * Fetches JSON from a URL with a timeout and no redirects. Returns {status, headers, data}; data is null if not JSON.
 */
async function getJson(url, init = {}) {
  let response;
  try {
    response = await fetch(url, { redirect: "manual", signal: AbortSignal.timeout(TIMEOUT_MS), ...init });
  } catch (error) {
    throw new CliError(`request to ${new URL(url).origin} failed: ${redact(error.message)}`);
  }
  const data = await response.json().catch(() => null);
  return { status: response.status, headers: response.headers, data };
}

/**
 * Compares two URLs ignoring a trailing slash.
 */
const sameUrl = (a, b) => a.replace(/\/$/, "") === b.replace(/\/$/, "");

/**
 * Finds the protected resource metadata (RFC 9728): the 401 `resource_metadata` pointer first, then well-known URLs.
 */
async function discoverResource(resourceUrl) {
  const url = new URL(resourceUrl);
  const candidates = [];
  const probe = await fetch(resourceUrl, {
    method: "POST",
    redirect: "manual",
    headers: { "content-type": "application/json", accept: "application/json, text/event-stream" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "ping" }),
    signal: AbortSignal.timeout(TIMEOUT_MS),
  }).catch((error) => {
    throw new CliError(`cannot reach ${url.origin}: ${redact(error.message)}`);
  });
  const pointer = /resource_metadata="([^"]+)"/.exec(probe.headers.get("www-authenticate") ?? "");
  if (pointer) candidates.push(pointer[1]);
  const path = url.pathname === "/" ? "" : url.pathname;
  candidates.push(`${url.origin}/.well-known/oauth-protected-resource${path}`);
  candidates.push(`${url.origin}/.well-known/oauth-protected-resource`);
  for (const candidate of candidates) {
    assertSafeUrl(candidate, "resource metadata URL");
    const { status, data } = await getJson(candidate);
    if (status === 200 && data?.authorization_servers?.length > 0) {
      if (data.resource && !sameUrl(data.resource, resourceUrl)) {
        throw new CliError("the server's resource metadata names a different resource; refusing to sign in");
      }
      return data;
    }
  }
  throw new CliError("no OAuth protected-resource metadata found; is this server OAuth-protected?");
}

/**
 * Finds the authorization server metadata (RFC 8414, then OpenID discovery) and checks issuer and PKCE support.
 */
async function discoverAuthServer(issuer) {
  const url = new URL(issuer);
  const path = url.pathname === "/" ? "" : url.pathname.replace(/\/$/, "");
  const candidates = [
    `${url.origin}/.well-known/oauth-authorization-server${path}`,
    `${url.origin}/.well-known/openid-configuration${path}`,
    `${url.origin}${path}/.well-known/openid-configuration`,
  ];
  for (const candidate of candidates) {
    const { status, data } = await getJson(candidate);
    if (status !== 200 || !data) continue;
    if (!data.issuer || !sameUrl(data.issuer, issuer)) {
      throw new CliError("the authorization server metadata names a different issuer; refusing to sign in");
    }
    const methods = data.code_challenge_methods_supported;
    if (!Array.isArray(methods) || !methods.includes("S256")) {
      throw new CliError("the authorization server does not advertise PKCE S256; refusing to sign in");
    }
    assertSafeUrl(data.authorization_endpoint, "authorization endpoint");
    assertSafeUrl(data.token_endpoint, "token endpoint");
    if (data.registration_endpoint) assertSafeUrl(data.registration_endpoint, "registration endpoint");
    return data;
  }
  throw new CliError("no authorization server metadata found");
}

/**
 * Runs discovery for a resource URL. Returns the authorization server metadata.
 */
export async function discover(resourceUrl) {
  const resource = await discoverResource(resourceUrl);
  return discoverAuthServer(resource.authorization_servers[0]);
}

/**
 * Picks a client id: pre-registered, then a Client ID Metadata Document URL, then Dynamic Client Registration.
 */
export async function chooseClientId(meta, oauthConfig, redirectUri) {
  if (oauthConfig?.clientId) return oauthConfig.clientId;
  if (oauthConfig?.clientMetadataUrl && meta.client_id_metadata_document_supported) {
    assertSafeUrl(oauthConfig.clientMetadataUrl, "client metadata URL");
    return oauthConfig.clientMetadataUrl;
  }
  if (!meta.registration_endpoint) {
    throw new CliError("the server offers no dynamic registration; add it again with --client-id <id>");
  }
  const { status, data } = await getJson(meta.registration_endpoint, {
    method: "POST",
    headers: { "content-type": "application/json", accept: "application/json" },
    body: JSON.stringify({
      client_name: "gd-mcp-auth",
      redirect_uris: [redirectUri],
      grant_types: ["authorization_code", "refresh_token"],
      response_types: ["code"],
      token_endpoint_auth_method: "none",
    }),
  });
  if (status >= 300 || typeof data?.client_id !== "string") {
    throw new CliError(`client registration failed (HTTP ${status})`);
  }
  return data.client_id;
}

/**
 * Makes the PKCE verifier and its S256 challenge, and a random state value.
 */
export function makePkce() {
  const verifier = randomBytes(48).toString("base64url");
  const challenge = createHash("sha256").update(verifier).digest("base64url");
  return { verifier, challenge, state: randomBytes(24).toString("base64url") };
}

/**
 * Builds the authorization URL the user opens in a browser.
 */
export function authorizationUrl(meta, { clientId, redirectUri, challenge, state, resource, scope }) {
  const url = new URL(meta.authorization_endpoint);
  const params = {
    response_type: "code",
    client_id: clientId,
    redirect_uri: redirectUri,
    code_challenge: challenge,
    code_challenge_method: "S256",
    state,
    resource,
    ...(scope ? { scope } : {}),
  };
  for (const [key, value] of Object.entries(params)) url.searchParams.set(key, value);
  return url.toString();
}

/**
 * Checks the callback's issuer (RFC 9207): it must match when sent, and must be sent when the server advertises it.
 */
export function checkIssuer(meta, iss) {
  if (iss !== undefined && iss !== null) {
    if (!sameUrl(iss, meta.issuer)) throw new CliError("the sign-in response came from a different issuer; stopped");
  } else if (meta.authorization_response_iss_parameter_supported) {
    throw new CliError("the sign-in response has no issuer, but this server always sends one; stopped");
  }
}

/**
 * Exchanges the login code for tokens (with the PKCE verifier and the resource). Returns the secret record.
 */
export async function exchangeCode(meta, { clientId, code, verifier, redirectUri, resource }) {
  const { status, data } = await getJson(meta.token_endpoint, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded", accept: "application/json" },
    body: new URLSearchParams({
      grant_type: "authorization_code",
      code,
      redirect_uri: redirectUri,
      client_id: clientId,
      code_verifier: verifier,
      resource,
    }),
  });
  if (status >= 300 || typeof data?.access_token !== "string") {
    throw new CliError(`token request failed (${redact(String(data?.error ?? `HTTP ${status}`), [code, verifier])})`);
  }
  return {
    accessToken: data.access_token,
    refreshToken: data.refresh_token,
    expiresAt: typeof data.expires_in === "number" ? Date.now() + data.expires_in * 1000 : undefined,
    clientId,
    tokenEndpoint: meta.token_endpoint,
  };
}
