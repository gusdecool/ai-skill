// The code gd-mcp-auth shares with gd-mcp-client (registry, token store, redaction). Both skills install together.
export { assertName, assertSafeUrl } from "../../../gd-mcp-client/scripts/lib/paths.mjs";
export { CliError, redact } from "../../../gd-mcp-client/scripts/lib/redact.mjs";
export { findServer, loadRegistry, saveRegistry } from "../../../gd-mcp-client/scripts/lib/registry.mjs";
export { deleteSecret, loadSecret, saveSecret } from "../../../gd-mcp-client/scripts/lib/store.mjs";
