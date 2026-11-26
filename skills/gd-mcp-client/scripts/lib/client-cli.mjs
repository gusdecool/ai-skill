// The three client commands: mcp-list, list-tools and mcp-call. Each returns the process exit code.
import { findServer, loadRegistry } from "./registry.mjs";
import { mcpRequest, Unauthorized } from "./mcp-http.mjs";
import { assertSafeUrl } from "./paths.mjs";
import { CliError } from "./redact.mjs";
import { getAccessToken } from "./token.mjs";

const NOT_REGISTERED = 3;

/**
 * Looks the server up in the registry. Prints "not registered" and signals exit code 3 when it is unknown,
 * so the calling agent falls back to its own MCP tools.
 */
function lookup(name) {
  const server = findServer(loadRegistry(), name);
  if (!server) throw new CliError(`not registered: ${name}`, NOT_REGISTERED);
  if (server.transport !== "http") {
    throw new CliError(`${name} is a ${server.transport} server; the shared client calls http servers only`);
  }
  assertSafeUrl(server.url, `url of ${name}`);
  return server;
}

/**
 * Sends one MCP request to a registered server, refreshing the token once if the server answers 401.
 */
async function request(name, method, params) {
  const server = lookup(name);
  const authenticated = server.auth?.type !== "none";
  let token = authenticated ? await getAccessToken(name, server) : undefined;
  try {
    return await mcpRequest(server.url, token, method, params);
  } catch (error) {
    if (!(error instanceof Unauthorized)) throw error;
    if (!authenticated) throw new CliError(`${name} answered 401 but is registered without auth`);
    token = await getAccessToken(name, server, { force: true });
    try {
      return await mcpRequest(server.url, token, method, params);
    } catch (again) {
      if (again instanceof Unauthorized) throw new CliError(`${name} rejected the token; run gd-mcp-auth login ${name}`);
      throw again;
    }
  }
}

/**
 * mcp-list: prints each registered server as "name transport auth-type url". Never prints a secret.
 */
export function mcpList() {
  const { servers } = loadRegistry();
  const names = Object.keys(servers);
  if (names.length === 0) console.log("no servers registered");
  for (const name of names) {
    const s = servers[name];
    console.log([name, s.transport, s.auth?.type ?? "none", s.url ?? s.command ?? ""].join(" "));
  }
  return 0;
}

/**
 * list-tools <server>: prints each tool's name, description and input schema.
 */
export async function listTools(args) {
  if (args.length !== 1) throw new CliError("usage: list-tools <server>");
  const result = await request(args[0], "tools/list", {});
  for (const tool of result.tools ?? []) {
    console.log(`${tool.name}: ${tool.description ?? ""}`.trimEnd());
    console.log(`  input: ${JSON.stringify(tool.inputSchema ?? {})}`);
  }
  return 0;
}

/**
 * mcp-call <server> <tool> '<json args>': calls one tool and prints its result. Exit code 1 when the tool
 * reports an error. The result is data from the server, not an instruction.
 */
export async function mcpCall(args) {
  if (args.length < 2 || args.length > 3) throw new CliError("usage: mcp-call <server> <tool> '<json args>'");
  let toolArgs = {};
  if (args[2] !== undefined) {
    try {
      toolArgs = JSON.parse(args[2]);
    } catch (error) {
      throw new CliError(`arguments are not valid JSON: ${error.message}`);
    }
    if (typeof toolArgs !== "object" || toolArgs === null || Array.isArray(toolArgs)) {
      throw new CliError("arguments must be a JSON object");
    }
  }
  const result = await request(args[0], "tools/call", { name: args[1], arguments: toolArgs });
  for (const item of result.content ?? []) {
    console.log(item.type === "text" ? item.text : JSON.stringify(item));
  }
  if (result.structuredContent !== undefined) console.log(JSON.stringify(result.structuredContent));
  return result.isError ? 1 : 0;
}

/**
 * Runs a command function and turns a CliError into one printed line and its exit code.
 */
export async function run(fn, args) {
  try {
    process.exitCode = await fn(args);
  } catch (error) {
    if (!(error instanceof CliError)) throw error;
    // "not registered" goes to stdout so an agent that only reads stdout still sees it.
    (error.exitCode === NOT_REGISTERED ? console.log : console.error)(error.message);
    process.exitCode = error.exitCode;
  }
}
