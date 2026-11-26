// Local mock of an MCP server (Streamable HTTP) and its OAuth login server, for tests and the engine spike.
// Everything runs on 127.0.0.1; no live API is ever called. Token values are random, built at run time.
import { createServer } from "node:http";
import { createHash, randomBytes } from "node:crypto";

/**
 * Makes a random opaque value with a readable prefix, so no fixed secret-shaped string sits in the repo.
 */
const random = (prefix) => `${prefix}_${randomBytes(18).toString("hex")}`;

/**
 * Reads a whole request body as text.
 */
async function readBody(req) {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  return Buffer.concat(chunks).toString("utf8");
}

/**
 * Starts the mock. Options: expiresIn (seconds, default 3600), issuerOverride (wrong `iss` on the redirect),
 * stateOverride (wrong `state` on the redirect), refreshable (default true), cimd (advertise CIMD support),
 * scopesSupported (the resource's scopes_supported), challengeScope (a scope in the 401 challenge).
 * Returns the base URL, the MCP URL, counters for assertions, helpers and close().
 */
export async function startMock(options = {}) {
  const expiresIn = options.expiresIn ?? 3600;
  const refreshable = options.refreshable ?? true;
  const stats = { authHeaders: [], tokenGrants: [], registrations: 0, authorizeQueries: [], initializes: 0 };
  const codes = new Map();
  const accessTokens = new Map();
  const refreshTokens = new Map();
  const staticTokens = new Set(options.staticTokens ?? []);
  let base = "";

  /** Issues an access token (and a refresh token when enabled) and returns the token endpoint JSON. */
  const issue = (clientId, resource) => {
    const access = random("at");
    accessTokens.set(access, { expires: Date.now() + expiresIn * 1000, clientId, resource });
    const body = { access_token: access, token_type: "Bearer", expires_in: expiresIn };
    if (refreshable) {
      const refresh = random("rt");
      refreshTokens.set(refresh, { clientId, resource });
      body.refresh_token = refresh;
    }
    return body;
  };

  /** Sends a JSON response. */
  const json = (res, status, body, headers = {}) => {
    res.writeHead(status, { "content-type": "application/json", ...headers });
    res.end(JSON.stringify(body));
  };

  /** Handles one JSON-RPC message of the MCP endpoint and returns the result object, or null for a notification. */
  const rpc = (message) => {
    if (message.method === "initialize") {
      stats.initializes += 1;
      return {
        protocolVersion: "2025-06-18",
        capabilities: { tools: {} },
        serverInfo: { name: "mock-mcp", version: "1.0.0" },
      };
    }
    if (message.method === "tools/list") {
      return {
        tools: [
          {
            name: "echo",
            description: "Returns the text it is given",
            inputSchema: { type: "object", properties: { text: { type: "string" } }, required: ["text"] },
          },
          { name: "ping", description: "Returns pong", inputSchema: { type: "object", properties: {} } },
        ],
      };
    }
    if (message.method === "tools/call") {
      const { name, arguments: args = {} } = message.params;
      if (name === "echo") return { content: [{ type: "text", text: `echo:${args.text}` }] };
      if (name === "ping") return { content: [{ type: "text", text: "pong" }] };
      return { isError: true, content: [{ type: "text", text: `unknown tool ${name}` }] };
    }
    return null;
  };

  /** Serves the MCP endpoint: checks the bearer token, then answers JSON-RPC as JSON or as a one-event SSE. */
  const mcp = async (req, res) => {
    const auth = req.headers.authorization ?? "";
    stats.authHeaders.push(auth);
    const token = auth.replace(/^Bearer /, "");
    const known = accessTokens.get(token);
    const valid = staticTokens.has(token) || (known && known.expires > Date.now());
    if (options.requireAuth !== false && !valid) {
      return json(res, 401, { error: "invalid_token" }, {
        "www-authenticate": `Bearer resource_metadata="${base}/.well-known/oauth-protected-resource/mcp"${
          options.challengeScope ? `, scope="${options.challengeScope}"` : ""
        }`,
      });
    }
    if (req.method !== "POST") return json(res, 405, { error: "method not allowed" });
    const message = JSON.parse(await readBody(req));
    const result = rpc(message);
    if (result === null && message.id === undefined) {
      res.writeHead(202);
      return res.end();
    }
    if (result === null) {
      return json(res, 200, { jsonrpc: "2.0", id: message.id, error: { code: -32601, message: "Method not found" } });
    }
    const reply = { jsonrpc: "2.0", id: message.id, result };
    const headers = { "mcp-session-id": "mock-session" };
    if (message.method === "tools/call") {
      res.writeHead(200, { "content-type": "text/event-stream", ...headers });
      return res.end(`event: message\ndata: ${JSON.stringify(reply)}\n\n`);
    }
    return json(res, 200, reply, headers);
  };

  /** Serves /authorize like a logged-in browser would: redirects to the loopback callback with a code. */
  const authorize = (url, res) => {
    const q = Object.fromEntries(url.searchParams);
    stats.authorizeQueries.push(q);
    const code = random("code");
    codes.set(code, q);
    const back = new URL(q.redirect_uri);
    back.searchParams.set("code", code);
    back.searchParams.set("state", options.stateOverride ?? q.state);
    back.searchParams.set("iss", options.issuerOverride ?? base);
    res.writeHead(302, { location: back.toString() });
    res.end();
  };

  /** Serves the token endpoint for the authorization_code and refresh_token grants. */
  const token = async (req, res) => {
    const form = Object.fromEntries(new URLSearchParams(await readBody(req)));
    stats.tokenGrants.push({ grant: form.grant_type, resource: form.resource });
    if (form.grant_type === "authorization_code") {
      const original = codes.get(form.code);
      codes.delete(form.code);
      if (!original) return json(res, 400, { error: "invalid_grant" });
      const challenge = createHash("sha256").update(form.code_verifier ?? "").digest("base64url");
      if (challenge !== original.code_challenge) return json(res, 400, { error: "invalid_grant" });
      if (form.redirect_uri !== original.redirect_uri || form.resource !== original.resource) {
        return json(res, 400, { error: "invalid_grant" });
      }
      return json(res, 200, issue(form.client_id, form.resource));
    }
    if (form.grant_type === "refresh_token") {
      const known = refreshTokens.get(form.refresh_token);
      if (!known) return json(res, 400, { error: "invalid_grant" });
      refreshTokens.delete(form.refresh_token);
      return json(res, 200, issue(known.clientId, form.resource ?? known.resource));
    }
    return json(res, 400, { error: "unsupported_grant_type" });
  };

  const server = createServer(async (req, res) => {
    const url = new URL(req.url, base);
    try {
      if (url.pathname === "/mcp") return await mcp(req, res);
      if (url.pathname === "/redirect-me") {
        res.writeHead(307, { location: options.redirectTo ?? `${base}/mcp` });
        return res.end();
      }
      if (url.pathname === "/.well-known/oauth-protected-resource/mcp") {
        return json(res, 200, {
          resource: `${base}/mcp`,
          authorization_servers: [base],
          ...(options.scopesSupported ? { scopes_supported: options.scopesSupported } : {}),
        });
      }
      if (url.pathname === "/.well-known/oauth-authorization-server") {
        return json(res, 200, {
          issuer: base,
          authorization_endpoint: `${base}/authorize`,
          token_endpoint: `${base}/token`,
          registration_endpoint: `${base}/register`,
          code_challenge_methods_supported: options.noPkce ? [] : ["S256"],
          response_types_supported: ["code"],
          grant_types_supported: ["authorization_code", "refresh_token"],
          authorization_response_iss_parameter_supported: true,
          client_id_metadata_document_supported: Boolean(options.cimd),
        });
      }
      if (url.pathname === "/authorize") return authorize(url, res);
      if (url.pathname === "/register") {
        stats.registrations += 1;
        const body = JSON.parse(await readBody(req));
        return json(res, 201, { client_id: random("client"), redirect_uris: body.redirect_uris });
      }
      if (url.pathname === "/token") return await token(req, res);
      return json(res, 404, { error: "not found" });
    } catch (error) {
      return json(res, 500, { error: String(error) });
    }
  });

  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  base = `http://127.0.0.1:${server.address().port}`;
  return {
    base,
    mcpUrl: `${base}/mcp`,
    stats,
    /** Issues a token pair directly, as if a login had just happened (for seeding the token store). */
    issueTokens: (resource = `${base}/mcp`) => issue("seed-client", resource),
    /** Makes every access token handed out so far expire now. */
    expireAll: () => {
      for (const entry of accessTokens.values()) entry.expires = 0;
    },
    /** Stops the server and drops open connections. */
    close: () => new Promise((resolve) => {
      server.closeAllConnections();
      server.close(resolve);
    }),
  };
}
