import assert from "node:assert/strict";
import { copyFileSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import {
  addProposal,
  extractModels,
  findMissing,
  parseTable,
  proposeTier,
  run,
  renderRow,
  type ModelInfo,
  type Source,
} from "./model-watch.ts";

const MODELS_PATH: URL = new URL("../../skills/gusdecool-model-policy/models.md", import.meta.url);

/** Builds a minimal models.md body around the given table rows. */
const tableWith = (rows: string[]): string =>
  ["Last checked: 2026-01-01", "", "| Provider | Low | Mid | High | Ultra |", "|---|---|---|---|---|", ...rows].join(
    "\n",
  );

test("proposeTier maps output price to the spec bands relative to Sonnet", () => {
  assert.equal(proposeTier(0.4 * 10, 10), "Low");
  assert.equal(proposeTier(0.5 * 10, 10), "Low");
  assert.equal(proposeTier(10, 10), "Mid");
  assert.equal(proposeTier(1.5 * 10, 10), "Mid");
  assert.equal(proposeTier(20, 10), "High");
  assert.equal(proposeTier(3 * 10, 10), "High");
  assert.equal(proposeTier(40, 10), "Ultra");
});

test("findMissing returns only models absent from the table", () => {
  const known: Set<string> = new Set(["Sonnet 5.5", "Argon", "K2.7 Code"]);
  const found: ModelInfo[] = [
    { provider: "Claude", slug: "Sonnet 5.5", outputPrice: 10 },
    { provider: "Gemini", slug: "4 Argon", outputPrice: 20 },
    { provider: "Kimi", slug: "k2.7-code", outputPrice: 4 },
    { provider: "Gemini", slug: "3.8 Flash-Lite", outputPrice: 2 },
  ];
  assert.deepEqual(
    findMissing(known, found).map((m: ModelInfo): string => m.slug),
    ["3.8 Flash-Lite"],
  );
});

test("findMissing does not confuse Flash with Flash-Lite", () => {
  const found: ModelInfo[] = [{ provider: "Gemini", slug: "3.8 Flash-Lite", outputPrice: 2 }];
  assert.equal(findMissing(new Set(["3.8 Flash"]), found).length, 1);
});

test("parseTable round-trips the real skills/gusdecool-model-policy/models.md and ignores the API ID table", () => {
  const parsed: Map<string, Map<string, string[]>> = parseTable(readFileSync(MODELS_PATH, "utf8"));
  assert.deepEqual([...parsed.keys()], ["Claude", "Codex", "Gemini", "DeepSeek", "Kimi"]);
  assert.deepEqual(parsed.get("Claude")?.get("Ultra"), ["Fable 5.2", "Mythos 5.2"]);
  assert.deepEqual(parsed.get("Codex")?.get("Ultra"), ["Astra"]);
  assert.deepEqual(parsed.get("Kimi")?.get("Mid"), ["K2.7 Code", "K3.1-pro", "K3"]);
  assert.deepEqual([...(parsed.get("Gemini")?.keys() ?? [])], ["Low", "Mid", "High", "Ultra"]);
});

test("parseTable counts a proposed model as known", () => {
  const parsed: Map<string, Map<string, string[]>> = parseTable(
    tableWith(["| Codex | Luna | Sol, Terra (proposed) | Astra | none |"]),
  );
  assert.deepEqual(parsed.get("Codex")?.get("Mid"), ["Sol", "Terra"]);
});

test("parseTable throws when the table is missing", () => {
  assert.throws(() => parseTable("# nothing here"), /table/i);
});

test("renderRow writes the proposed marker", () => {
  assert.equal(renderRow({ provider: "Codex", slug: "Terra", outputPrice: 5 }), "Terra (proposed)");
});

test("addProposal fills a none cell, appends to a filled one, and bumps the date", () => {
  const md: string = tableWith(["| Codex | Luna | Sol | none | none |", "| Kimi | K2.6 | K2.7 Code | none | none |"]);
  const withHigh: string = addProposal(md, { provider: "Codex", slug: "Astra", outputPrice: 50 }, "High", "2026-02-02");
  assert.match(withHigh, /\| Codex \| Luna \| Sol \| Astra \(proposed\) \| none \|/);
  assert.match(withHigh, /Last checked: 2026-02-02/);
  const withMid: string = addProposal(md, { provider: "Kimi", slug: "K3", outputPrice: 14 }, "Mid", "2026-02-02");
  assert.match(withMid, /\| Kimi \| K2\.6 \| K2\.7 Code, K3 \(proposed\) \| none \| none \|/);
});

test("addProposal throws for a provider that has no row", () => {
  assert.throws(
    () => addProposal(tableWith([]), { provider: "Nobody", slug: "X", outputPrice: 1 }, "Low", "2026-02-02"),
    /Nobody/,
  );
});

const SOURCE: Source = {
  url: "https://example.test/pricing",
  pattern: "^\\| gpt-\\d[\\d.]*-(?<slug>\\w+) \\| \\$[\\d.]+ \\| \\$(?<price>[\\d.]+) \\|",
  start: "## Standard",
  end: "## Batch",
};

test("extractModels reads slugs and prices inside the scope and keeps the first duplicate", () => {
  const text: string = [
    "| gpt-5-old | $1.00 | $9.00 |",
    "## Standard",
    "| gpt-6.1-sol | $2.00 | $10.00 |",
    "| gpt-6-sol | $2.00 | $11.00 |",
    "| gpt-6-luna | $0.10 | $0.50 |",
    "## Batch",
    "| gpt-6-astra | $5.00 | $25.00 |",
  ].join("\n");
  const found: ModelInfo[] = extractModels("Codex", SOURCE, text);
  assert.deepEqual(found, [
    { provider: "Codex", slug: "Sol", outputPrice: 10 },
    { provider: "Codex", slug: "Luna", outputPrice: 0.5 },
  ]);
});

test("extractModels applies the price scale and the ignore list", () => {
  const source: Source = {
    url: "https://example.test",
    pattern: "(?<slug>K\\d) ¥(?<price>[\\d.]+)",
    usdPerUnit: 0.1,
    ignore: "^K1$",
  };
  const found: ModelInfo[] = extractModels("Kimi", source, "K1 ¥5 K2 ¥20");
  assert.deepEqual(found, [{ provider: "Kimi", slug: "K2", outputPrice: 2 }]);
});

test("extractModels throws on zero matches so a layout change fails the run", () => {
  assert.throws(() => extractModels("Codex", SOURCE, "## Standard\nnothing\n## Batch"), /zero|no match/i);
});

test("extractModels throws when the scope marker is gone", () => {
  assert.throws(() => extractModels("Codex", SOURCE, "| gpt-6-sol | $2.00 | $10.00 |"), /## Standard/);
});

const RUN_SOURCES: string = JSON.stringify({
  Claude: { url: "https://claude.test", pattern: "Claude (?<slug>Sonnet [\\d.]+) \\$(?<price>[\\d.]+)" },
  Kimi: { url: "https://kimi.test", pattern: "(?<slug>K[\\d.]+) \\$(?<price>[\\d.]+)" },
});

/** Copies models.md into a temp dir with a sources file, and returns both paths. */
const scratchFiles = (): { models: string; sources: string } => {
  const dir: string = mkdtempSync(join(tmpdir(), "model-watch-"));
  const models: string = join(dir, "models.md");
  const sources: string = join(dir, "sources.json");
  copyFileSync(MODELS_PATH, models);
  writeFileSync(sources, RUN_SOURCES);
  return { models, sources };
};

/** Builds a fetch stub that answers by URL; an unknown URL answers 500. */
const fakeFetch = (pages: Record<string, string>): typeof fetch =>
  (async (url: string | URL | Request): Promise<Response> => {
    const body: string | undefined = pages[String(url)];
    return body === undefined ? new Response("boom", { status: 500 }) : new Response(body);
  }) as typeof fetch;

test("run proposes a new model once and a second run reports nothing new", async () => {
  const { models, sources } = scratchFiles();
  const pages: Record<string, string> = {
    "https://claude.test": "Claude Sonnet 5.5 $10",
    "https://kimi.test": "K2.6 $1 K9 $12",
  };
  const first: string[] = await run(models, sources, fakeFetch(pages), "2026-03-03");
  assert.equal(first.length, 1);
  assert.match(first[0], /K9 \(proposed\) in Mid/);
  assert.match(readFileSync(models, "utf8"), /K2\.7 Code, K3\.1-pro, K3, K9 \(proposed\)/);
  assert.match(readFileSync(models, "utf8"), /Last checked: 2026-03-03/);
  const afterFirst: string = readFileSync(models, "utf8");
  assert.deepEqual(await run(models, sources, fakeFetch(pages), "2026-03-10"), []);
  assert.equal(readFileSync(models, "utf8"), afterFirst);
});

test("run leaves models.md untouched when nothing is new", async () => {
  const { models, sources } = scratchFiles();
  const before: string = readFileSync(models, "utf8");
  const pages: Record<string, string> = {
    "https://claude.test": "Claude Sonnet 5.5 $10",
    "https://kimi.test": "K2.6 $1",
  };
  assert.deepEqual(await run(models, sources, fakeFetch(pages), "2030-01-01"), []);
  assert.equal(readFileSync(models, "utf8"), before);
});

test("run fails when a page cannot be fetched and names the page", async () => {
  const { models, sources } = scratchFiles();
  const pages: Record<string, string> = { "https://claude.test": "Claude Sonnet 5.5 $10" };
  await assert.rejects(run(models, sources, fakeFetch(pages), "2026-03-03"), /kimi\.test: HTTP 500/);
});

test("run fails, and does not report no changes, when a page layout changed", async () => {
  const { models, sources } = scratchFiles();
  const pages: Record<string, string> = {
    "https://claude.test": "Claude Sonnet 5.5 $10",
    "https://kimi.test": "<html>a redesigned page</html>",
  };
  await assert.rejects(run(models, sources, fakeFetch(pages), "2026-03-03"), /Kimi: .*zero models/);
});
