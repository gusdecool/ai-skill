---
name: gd-mcp-auth
description: Use when the user wants to add, connect, sign in to, re-authenticate, sign out of or remove an MCP server for the shared MCP client, for example "add the X MCP" or "log in to the X MCP again". Runs the one-time OAuth login in the user's own browser, or stores an API token, and saves it in the macOS Keychain without ever showing it to the agent. Not for calling or listing a server's tools (use gd-mcp-client), and not for changing an agent's own MCP settings.
license: MIT
metadata:
  author: gusdecool
  version: "1.0"
---

# MCP auth (shared registry)

Adds servers to the registry that `gd-mcp-client` reads, and signs the user in. It installs together with
`gd-mcp-client` (it shares that skill's code), and needs Node 24 or newer. Script: `scripts/mcp-auth`, relative to this
skill's folder. It prints status lines only. **The agent never sees a token, a login code or a PKCE secret.**

## Commands

| Command | What it does |
|---|---|
| `mcp-auth add <name> <url> [--auth oauth\|bearer\|none] [--client-id <id>] [--client-metadata-url <url>] [--scope <s>]` | Writes the registry entry. Default `--auth oauth`. The name uses a-z, 0-9 and hyphen. The URL is https (http only on 127.0.0.1) |
| `mcp-auth login <name> [--no-browser]` | OAuth servers: opens the user's browser and waits. API-token servers: the user types the token (hidden) or it is piped on stdin |
| `mcp-auth status [<name>]` | Prints signed in, expired or not signed in. Never the token |
| `mcp-auth logout <name>` | Deletes the saved token, keeps the registry entry |
| `mcp-auth remove <name>` | Deletes the saved token and the registry entry |

## Steps to add a server

1. Ask the user for the server's URL and a short name. Ask whether it uses OAuth (a browser login) or an API token.
2. Run `mcp-auth add <name> <url>` (add `--auth bearer` for an API token).
3. Tell the user that the next step is theirs and runs on their machine, then run `mcp-auth login <name>`.
   - OAuth: the browser opens, the user signs in, the script prints `signed in as <name>, expires at <time>`.
   - API token: the user types the token at the hidden prompt. **Never ask the user to paste a token into the chat,
     and never put it on a command line** (`ps` shows arguments).
   - No browser on the machine (SSH, remote): use `--no-browser`. It prints an address; the user opens it elsewhere,
     signs in, then pastes back the address the browser lands on (the page itself will not load).
4. Check with `mcp-auth status <name>`, then use `gd-mcp-client`.

## Rules

- Do these steps only when the user asks to add, sign in to, sign out of or remove a server.
- Tokens are kept in the macOS Keychain (one entry per server), or a 0600 file under `~/.config/gd-mcp/tokens/` where
  there is no keychain. This stops accidental leaks (git, logs, chat); it does not stop malware running as the user.
- Login follows the MCP authorization spec: discovery, a client id (pre-registered, then a client metadata URL, then
  dynamic registration), PKCE S256, a random `state`, the `resource` parameter, an `iss` check, a listener on
  `127.0.0.1` on a random port that accepts one request, and a 5 minute timeout.
- If login fails with a message about the server, report that message. Do not retry in a loop.
- If the keychain is locked, tell the user to unlock it; do not switch to the file store on your own.
