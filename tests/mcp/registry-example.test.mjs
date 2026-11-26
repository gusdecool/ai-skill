// Checks the example registry and the skill docs: valid format, example hosts only, no credential-shaped value.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { REPO } from "./helpers.mjs";

const EXAMPLE = join(REPO, "skills", "gd-mcp-client", "registry.example.json");
const FILES = [EXAMPLE, ...["gd-mcp-client", "gd-mcp-auth"].map((s) => join(REPO, "skills", s, "SKILL.md"))];

// Shapes that secret scanners match: user:pass@ URLs, long opaque runs, well-known token prefixes, bearer headers.
const CREDENTIAL_SHAPES = [
  /:\/\/[^/\s@]*:[^/\s@]*@/,
  /[A-Za-z0-9_-]{32,}/,
  /\b(ghp|gho|ghs|github_pat|sk|pk|xox[a-z])[-_][A-Za-z0-9]{8,}/,
  /\bAKIA[0-9A-Z]{12,}/,
  /\beyJ[A-Za-z0-9_-]{10,}/,
  /Bearer\s+[A-Za-z0-9._~+/=-]{8,}/,
];

test("the example registry has the right format and only example hosts", () => {
  const registry = JSON.parse(readFileSync(EXAMPLE, "utf8"));
  assert.equal(registry.version, 1);
  for (const [name, server] of Object.entries(registry.servers)) {
    assert.match(name, /^[a-z0-9][a-z0-9-]*$/);
    assert.equal(server.transport, "http");
    assert.equal(new URL(server.url).hostname, "mcp.example.com");
    assert.ok(["oauth", "bearer", "none"].includes(server.auth.type));
    assert.deepEqual(Object.keys(server.auth).filter((key) => key !== "type"), [], "no extra auth fields");
  }
});

test("the example registry and the skill docs hold no credential-shaped value", () => {
  for (const file of FILES) {
    const text = readFileSync(file, "utf8");
    for (const shape of CREDENTIAL_SHAPES) {
      assert.ok(!shape.test(text), `${file} matches ${shape}`);
    }
  }
});
