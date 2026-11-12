/**
 * Weekly model watcher. Reads each provider's official pricing page (models.sources.json), finds models that
 * are not in the tier table, and adds them as "name (proposed)" in the suggested tier.
 * A page that cannot be fetched, or whose pattern matches nothing, throws so the run fails instead of staying quiet.
 */
import { readFileSync, writeFileSync } from "node:fs";

export type Tier = "Low" | "Mid" | "High" | "Ultra";

/** One model found on a provider page. `slug` is the name as written in models.md; prices are USD per 1M output. */
export interface ModelInfo {
  provider: string;
  slug: string;
  outputPrice: number;
}

/**
 * One official page per provider. `pattern` (or several) is a regex with named groups `slug` and `price`, run with
 * the `gm` flags. `start`/`end` cut the page to the part that lists current models, `ignore` is a regex for names to
 * skip (legacy or non-text models), `usdPerUnit` converts a non-USD price, `format: "html"` strips tags first.
 */
export interface Source {
  url: string;
  pattern: string | string[];
  format?: "html" | "text";
  start?: string;
  end?: string;
  ignore?: string;
  usdPerUnit?: number;
}

const TIERS: Tier[] = ["Low", "Mid", "High", "Ultra"];
const PROPOSED_SUFFIX = " (proposed)";
const TABLE_HEADER: RegExp = /^\|\s*Provider\s*\|\s*Low\s*\|\s*Mid\s*\|\s*High\s*\|\s*Ultra\s*\|\s*$/;

/** Lowercases a model name and drops everything but letters and digits, so "Flash-Lite" equals "flash lite". */
const normalize = (name: string): string => name.toLowerCase().replace(/[^a-z0-9]/g, "");

/** True when a found name is the table name, or the table name with a leading version ("4 Argon" for "Argon"). */
const sameModel = (tableName: string, foundName: string): boolean => {
  const table: string = normalize(tableName);
  const found: string = normalize(foundName);
  return table.length > 0 && (found === table || found.endsWith(table));
};

/**
 * Suggests a tier from the output price relative to Sonnet: up to 0.5x Low, up to 1.5x Mid, up to 3x High, else Ultra.
 */
export const proposeTier = (outputPrice: number, sonnetOutputPrice: number): Tier => {
  const ratio: number = outputPrice / sonnetOutputPrice;
  if (ratio <= 0.5) return "Low";
  if (ratio <= 1.5) return "Mid";
  if (ratio <= 3) return "High";
  return "Ultra";
};

/**
 * Parses the `| Provider | Low | Mid | High | Ultra |` table of models.md into provider, then tier, then model names.
 * `none` becomes an empty list and the "(proposed)" marker is dropped. Other tables in the file are ignored.
 */
export const parseTable = (markdown: string): Map<string, Map<string, string[]>> => {
  const lines: string[] = markdown.split("\n");
  const headerIndex: number = lines.findIndex((line: string): boolean => TABLE_HEADER.test(line));
  if (headerIndex === -1) throw new Error("models.md has no '| Provider | Low | Mid | High | Ultra |' table");
  const result: Map<string, Map<string, string[]>> = new Map();
  // Skip the header and the |---| separator, then read rows until the table ends.
  for (let i: number = headerIndex + 2; i < lines.length && lines[i].startsWith("|"); i++) {
    const cells: string[] = lines[i].split("|").slice(1, -1).map((cell: string): string => cell.trim());
    if (cells.length !== TIERS.length + 1) {
      throw new Error(`models.md table row has ${cells.length} cells: ${lines[i]}`);
    }
    const tiers: Map<string, string[]> = new Map();
    TIERS.forEach((tier: Tier, index: number): void => {
      const cell: string = cells[index + 1];
      const names: string[] =
        cell.toLowerCase() === "none"
          ? []
          : cell.split(",").map((name: string): string => name.replace(/\(proposed\)/i, "").trim());
      tiers.set(tier, names);
    });
    result.set(cells[0], tiers);
  }
  return result;
};

/** Returns the found models whose name is not in the known set of table names. */
export const findMissing = (known: Set<string>, found: ModelInfo[]): ModelInfo[] =>
  found.filter((info: ModelInfo): boolean => ![...known].some((name: string): boolean => sameModel(name, info.slug)));

/** Renders the table-cell entry for a model the job adds: its name followed by the proposed marker. */
export const renderRow = (info: ModelInfo): string => `${info.slug}${PROPOSED_SUFFIX}`;

/**
 * Returns models.md with the model added to the provider's row under the given tier, and the date line set.
 * Throws when the provider has no row, so a renamed provider fails the run.
 */
export const addProposal = (markdown: string, info: ModelInfo, tier: Tier, date: string): string => {
  const lines: string[] = markdown.split("\n");
  const headerIndex: number = lines.findIndex((line: string): boolean => TABLE_HEADER.test(line));
  if (headerIndex === -1) throw new Error("models.md has no '| Provider | Low | Mid | High | Ultra |' table");
  const rowIndex: number = lines.findIndex(
    (line: string, i: number): boolean => i > headerIndex + 1 && line.startsWith(`| ${info.provider} |`),
  );
  if (rowIndex === -1) throw new Error(`models.md has no row for provider ${info.provider}`);
  const cells: string[] = lines[rowIndex].split("|").slice(1, -1).map((cell: string): string => cell.trim());
  const column: number = TIERS.indexOf(tier) + 1;
  cells[column] = cells[column].toLowerCase() === "none" ? renderRow(info) : `${cells[column]}, ${renderRow(info)}`;
  lines[rowIndex] = `| ${cells.join(" | ")} |`;
  return lines.join("\n").replace(/^Last checked: .*$/m, `Last checked: ${date}`);
};

/** Strips scripts, styles and tags from an HTML page and collapses whitespace, so patterns see plain text. */
const htmlToText = (html: string): string =>
  html
    .replace(/<(script|style)[^>]*>[\s\S]*?<\/\1>/gi, " ")
    .replace(/<[^>]*>/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/&quot;/g, '"')
    .replace(/&nbsp;/g, " ")
    .replace(/\s+/g, " ");

/** Cuts the page to the text between the start and end markers; a missing marker throws. */
const scopeText = (text: string, source: Source): string => {
  let scoped: string = text;
  if (source.start !== undefined) {
    const from: number = scoped.indexOf(source.start);
    if (from === -1) throw new Error(`${source.url}: start marker '${source.start}' not found, page layout changed`);
    scoped = scoped.slice(from);
  }
  if (source.end !== undefined) {
    const to: number = scoped.indexOf(source.end, 1);
    if (to === -1) throw new Error(`${source.url}: end marker '${source.end}' not found, page layout changed`);
    scoped = scoped.slice(0, to);
  }
  return scoped;
};

/**
 * Extracts the models listed on one provider page. Throws when a pattern lacks the `slug` or `price` group, or
 * matches nothing. Keeps the first of repeated names, because pages list the newest model first.
 */
export const extractModels = (provider: string, source: Source, pageText: string): ModelInfo[] => {
  const text: string = scopeText(source.format === "html" ? htmlToText(pageText) : pageText, source);
  const patterns: string[] = Array.isArray(source.pattern) ? source.pattern : [source.pattern];
  const ignore: RegExp | null = source.ignore === undefined ? null : new RegExp(source.ignore, "i");
  const scale: number = source.usdPerUnit ?? 1;
  const found: ModelInfo[] = [];
  for (const pattern of patterns) {
    const matches: RegExpExecArray[] = [...text.matchAll(new RegExp(pattern, "gm"))];
    if (matches.length === 0) throw new Error(`${provider}: pattern ${pattern} matched zero models on ${source.url}`);
    for (const match of matches) {
      const slug: string | undefined = match.groups?.slug?.trim();
      const price: number = Number.parseFloat(match.groups?.price ?? "");
      if (!slug || Number.isNaN(price)) throw new Error(`${provider}: pattern ${pattern} lacks a slug or price group`);
      if (ignore?.test(slug)) continue;
      if (found.some((info: ModelInfo): boolean => normalize(info.slug) === normalize(slug))) continue;
      found.push({ provider, slug: slug[0].toUpperCase() + slug.slice(1), outputPrice: price * scale });
    }
  }
  return found;
};

/** Fetches one page as text; a network error or a non-2xx status throws. */
const fetchPage = async (url: string, fetchFn: typeof fetch): Promise<string> => {
  const response: Response = await fetchFn(url, {
    headers: { "user-agent": "agent-standards-model-watch" },
    signal: AbortSignal.timeout(30_000),
  });
  if (!response.ok) throw new Error(`${url}: HTTP ${response.status}`);
  return response.text();
};

/**
 * Runs the watch: fetches every source, proposes missing models in models.md and returns summary lines.
 * Collects every provider error and throws them together, so one broken page does not hide another.
 */
export const run = async (
  modelsPath: string,
  sourcesPath: string,
  fetchFn: typeof fetch,
  today: string,
): Promise<string[]> => {
  const sources: Record<string, Source> = JSON.parse(readFileSync(sourcesPath, "utf8"));
  let markdown: string = readFileSync(modelsPath, "utf8");
  const table: Map<string, Map<string, string[]>> = parseTable(markdown);
  const errors: string[] = [];
  const foundByProvider: Map<string, ModelInfo[]> = new Map();
  for (const [provider, source] of Object.entries(sources)) {
    try {
      foundByProvider.set(provider, extractModels(provider, source, await fetchPage(source.url, fetchFn)));
    } catch (error) {
      errors.push(error instanceof Error ? error.message : String(error));
    }
  }
  if (errors.length > 0) throw new Error(`Model watch failed:\n${errors.join("\n")}`);

  // The Mid model of Claude (Sonnet) anchors the price bands.
  const sonnetName: string | undefined = table.get("Claude")?.get("Mid")?.[0];
  const sonnet: ModelInfo | undefined = foundByProvider
    .get("Claude")
    ?.find((info: ModelInfo): boolean => sonnetName !== undefined && sameModel(sonnetName, info.slug));
  if (!sonnet) throw new Error(`Model watch failed: Claude Mid model '${sonnetName}' not found on its pricing page`);

  const summary: string[] = [];
  for (const [provider, found] of foundByProvider) {
    const row: Map<string, string[]> | undefined = table.get(provider);
    if (!row) throw new Error(`Model watch failed: models.md has no row for provider ${provider}`);
    const known: Set<string> = new Set([...row.values()].flat());
    for (const info of findMissing(known, found)) {
      const tier: Tier = proposeTier(info.outputPrice, sonnet.outputPrice);
      markdown = addProposal(markdown, info, tier, today);
      summary.push(`- ${provider}: ${renderRow(info)} in ${tier} (output $${info.outputPrice.toFixed(2)} per 1M)`);
    }
  }
  if (summary.length > 0) writeFileSync(modelsPath, markdown);
  return summary;
};

/** Entry point: runs against the repo files and prints what was proposed. */
const main = async (): Promise<void> => {
  const today: string = new Date().toISOString().slice(0, 10);
  const summary: string[] = await run(
    new URL("../../skills/gd-model-policy/models.md", import.meta.url).pathname,
    new URL("models.sources.json", import.meta.url).pathname,
    fetch,
    today,
  );
  console.log(summary.length > 0 ? `Proposed models:\n${summary.join("\n")}` : "No new models.");
};

if (import.meta.main) {
  main().catch((error: unknown): void => {
    console.error(error instanceof Error ? error.message : error);
    process.exit(1);
  });
}
