// The gd-mcp-auth commands: add, login, status, logout, remove. Prints status lines only, never a secret.
import { spawn } from "node:child_process";
import { listen, readPastedRedirect } from "./callback.mjs";
import { authorizationUrl, checkIssuer, chooseClientId, discover, exchangeCode, makePkce } from "./oauth.mjs";
import { readSecret } from "./secret-input.mjs";
import {
  assertName, assertSafeUrl, CliError, deleteSecret, findServer, loadRegistry, loadSecret, saveRegistry, saveSecret,
} from "./shared.mjs";

const LOGIN_TIMEOUT_MS = Number(process.env.GD_MCP_LOGIN_TIMEOUT_MS) || 5 * 60 * 1000;
const USAGE = `usage:
  mcp-auth add <name> <url> [--auth oauth|bearer|none] [--client-id <id>] [--client-metadata-url <url>] [--scope <s>]
  mcp-auth login <name> [--no-browser]
  mcp-auth status [<name>]
  mcp-auth logout <name>
  mcp-auth remove <name>`;

/**
 * Splits arguments into positional values and --flags (a flag takes a value unless it is --no-browser).
 */
function parse(args) {
  const positional = [];
  const flags = {};
  for (let i = 0; i < args.length; i += 1) {
    if (args[i] === "--no-browser") flags.noBrowser = true;
    else if (args[i].startsWith("--")) {
      if (args[i + 1] === undefined) throw new CliError(`${args[i]} needs a value`);
      flags[args[i].slice(2)] = args[i + 1];
      i += 1;
    } else positional.push(args[i]);
  }
  return { positional, flags };
}

/**
 * Returns the registry entry for a name or throws a "not registered" error that points to `add`.
 */
function requireServer(registry, name) {
  const server = findServer(registry, name);
  if (!server) throw new CliError(`not registered: ${name}; run: mcp-auth add ${name} <url>`);
  return server;
}

/**
 * add: writes a registry entry. The entry holds names and URLs only.
 */
function add(args) {
  const { positional, flags } = parse(args);
  if (positional.length !== 2) throw new CliError(USAGE);
  const [name, url] = positional;
  assertName(name);
  assertSafeUrl(url, "url");
  const type = flags.auth ?? "oauth";
  if (!["oauth", "bearer", "none"].includes(type)) throw new CliError("--auth must be oauth, bearer or none");
  const registry = loadRegistry();
  if (findServer(registry, name)) throw new CliError(`${name} is already registered; run: mcp-auth remove ${name}`);
  const auth = { type };
  if (type === "oauth") {
    if (flags["client-id"]) auth.clientId = flags["client-id"];
    if (flags["client-metadata-url"]) auth.clientMetadataUrl = flags["client-metadata-url"];
    if (flags.scope) auth.scope = flags.scope;
  }
  registry.servers[name] = { transport: "http", url, auth };
  saveRegistry(registry);
  console.log(`registered ${name} (${type})`);
  return 0;
}

/**
 * Opens a URL in the user's browser. The address is an argument, not a shell string.
 */
function openBrowser(url) {
  const command = process.env.GD_MCP_BROWSER || (process.platform === "darwin" ? "open" : "xdg-open");
  const child = spawn(command, [url], { stdio: "ignore", detached: true });
  child.on("error", () => console.log("could not open a browser; open the address above by hand"));
  child.unref();
}

/**
 * Formats the expiry of a record for a status line.
 */
const expiry = (record) => (record.expiresAt ? new Date(record.expiresAt).toISOString() : "no expiry given");

/**
 * Runs the OAuth login for an oauth server: discovery, client id, PKCE, loopback or pasted redirect, token save.
 */
async function loginOauth(name, server, flags) {
  const meta = await discover(server.url);
  const pkce = makePkce();
  const callback = await listen({ state: pkce.state, timeoutMs: LOGIN_TIMEOUT_MS });
  const stopPaste = new AbortController();
  try {
    const clientId = await chooseClientId(meta, server.auth, callback.redirectUri);
    const url = authorizationUrl(meta, {
      clientId,
      redirectUri: callback.redirectUri,
      challenge: pkce.challenge,
      state: pkce.state,
      resource: server.url,
      scope: server.auth.scope ?? flags.scope ?? meta.requestedScope,
    });
    const waits = [callback.result];
    if (flags.noBrowser) {
      console.log(`open this address in a browser, sign in, then paste the address the browser lands on:\n${url}`);
      const pasted = readPastedRedirect({ state: pkce.state, signal: stopPaste.signal });
      // If the listener wins the race, the aborted paste read rejects with nobody waiting; that is expected.
      pasted.catch(() => {});
      waits.push(pasted);
    } else {
      console.log(`opening the browser to sign in to ${name}; if nothing opens, use this address:\n${url}`);
      openBrowser(url);
    }
    const { code, iss } = await Promise.race(waits);
    checkIssuer(meta, iss);
    const record = await exchangeCode(meta, {
      clientId, code, verifier: pkce.verifier, redirectUri: callback.redirectUri, resource: server.url,
    });
    saveSecret(name, record);
    console.log(`signed in as ${name}, expires at ${expiry(record)}`);
  } finally {
    stopPaste.abort();
    callback.close();
  }
}

/**
 * login: OAuth in the browser for oauth servers; a token read from stdin (no echo) for bearer servers.
 */
async function login(args) {
  const { positional, flags } = parse(args);
  if (positional.length !== 1) throw new CliError(USAGE);
  const name = positional[0];
  const server = requireServer(loadRegistry(), name);
  const type = server.auth?.type;
  if (type === "none") throw new CliError(`${name} needs no sign-in`);
  if (type === "bearer") {
    const token = await readSecret(`token for ${name} (input is hidden): `);
    saveSecret(name, { accessToken: token });
    console.log(`saved the token for ${name}`);
    return 0;
  }
  await loginOauth(name, server, flags);
  return 0;
}

/**
 * Describes one server's sign-in state in a single line.
 */
function statusLine(name, server) {
  const record = loadSecret(name);
  const type = server.auth?.type ?? "none";
  if (type === "none") return `${name}: no sign-in needed`;
  if (!record) return `${name}: not signed in`;
  if (typeof record.expiresAt === "number" && record.expiresAt < Date.now()) {
    return `${name}: access token expired ${expiry(record)}${record.refreshToken ? " (refresh available)" : ""}`;
  }
  return `${name}: signed in, expires ${type === "bearer" ? "never (api token)" : expiry(record)}`;
}

/**
 * status: prints each registered server's sign-in state, or one server's when a name is given.
 */
function status(args) {
  const registry = loadRegistry();
  const names = args.length > 0 ? [args[0]] : Object.keys(registry.servers);
  if (names.length === 0) console.log("no servers registered");
  for (const name of names) console.log(statusLine(name, requireServer(registry, name)));
  return 0;
}

/**
 * logout: deletes the saved token and keeps the registry entry.
 */
function logout(args) {
  if (args.length !== 1) throw new CliError(USAGE);
  requireServer(loadRegistry(), args[0]);
  console.log(deleteSecret(args[0]) ? `signed out ${args[0]}` : `${args[0]} was not signed in`);
  return 0;
}

/**
 * remove: deletes the saved token and the registry entry.
 */
function remove(args) {
  if (args.length !== 1) throw new CliError(USAGE);
  const registry = loadRegistry();
  requireServer(registry, args[0]);
  deleteSecret(args[0]);
  delete registry.servers[args[0]];
  saveRegistry(registry);
  console.log(`removed ${args[0]}`);
  return 0;
}

const COMMANDS = { add, login, status, logout, remove };

/**
 * Runs the command named by the first argument and returns its exit code. Errors print one redacted line.
 */
export async function main(args) {
  const command = COMMANDS[args[0]];
  if (!command) {
    console.error(USAGE);
    return 1;
  }
  try {
    return await command(args.slice(1));
  } catch (error) {
    if (!(error instanceof CliError)) throw error;
    console.error(error.message);
    return error.exitCode;
  }
}
