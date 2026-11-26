// A minimal MCP client over Streamable HTTP: initialize, then one request (tools/list or tools/call).
// The token goes only to the exact registry URL; any redirect is refused so it cannot reach another host.
import { CliError, redact } from "./redact.mjs";

const PROTOCOL_VERSION = "2025-06-18";
const TIMEOUT_MS = 60_000;

/**
 * Raised when the server answers 401, so the caller can refresh the token once and retry.
 */
export class Unauthorized extends Error {}

/**
 * Reads the JSON-RPC reply for a request id out of a JSON body or a text/event-stream body.
 */
async function readReply(response, id) {
  const text = await response.text();
  const type = response.headers.get("content-type") ?? "";
  const messages = [];
  if (type.includes("text/event-stream")) {
    for (const block of text.split(/\r?\n\r?\n/)) {
      const data = block.split(/\r?\n/).filter((line) => line.startsWith("data:")).map((line) => line.slice(5).trim());
      if (data.length > 0) messages.push(JSON.parse(data.join("\n")));
    }
  } else if (text.trim()) {
    messages.push(JSON.parse(text));
  }
  const reply = messages.find((message) => message.id === id);
  if (!reply) throw new CliError("the server sent no reply to the request");
  if (reply.error) throw new CliError(`server error ${reply.error.code}: ${reply.error.message}`);
  return reply.result;
}

/**
 * Sends one JSON-RPC message to the server URL with the bearer token, refusing redirects.
 */
async function post(url, token, headers, message) {
  const response = await fetch(url, {
    method: "POST",
    redirect: "manual",
    headers: {
      "content-type": "application/json",
      accept: "application/json, text/event-stream",
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      ...headers,
    },
    body: JSON.stringify(message),
    signal: AbortSignal.timeout(TIMEOUT_MS),
  });
  if (response.status >= 300 && response.status < 400) {
    throw new CliError(`the server redirected (HTTP ${response.status}); the token was not sent on. Fix the URL`);
  }
  if (response.status === 401) throw new Unauthorized();
  if (!response.ok) throw new CliError(`the server answered HTTP ${response.status}`);
  return response;
}

/**
 * Runs initialize, the initialized notification and then one request. Returns the result of that request.
 */
export async function mcpRequest(url, token, method, params) {
  try {
    const init = await post(url, token, {}, {
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: {
        protocolVersion: PROTOCOL_VERSION,
        capabilities: {},
        clientInfo: { name: "gd-mcp-client", version: "1.0.0" },
      },
    });
    const initResult = await readReply(init, 1);
    const headers = { "mcp-protocol-version": initResult.protocolVersion ?? PROTOCOL_VERSION };
    const session = init.headers.get("mcp-session-id");
    if (session) headers["mcp-session-id"] = session;
    await post(url, token, headers, { jsonrpc: "2.0", method: "notifications/initialized" });
    const response = await post(url, token, headers, { jsonrpc: "2.0", id: 2, method, params });
    return await readReply(response, 2);
  } catch (error) {
    if (error instanceof Unauthorized || error instanceof CliError) throw error;
    throw new CliError(`request failed: ${redact(error.message, [token])}`);
  }
}
