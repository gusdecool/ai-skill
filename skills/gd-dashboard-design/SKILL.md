---
name: gd-dashboard-design
description: >-
  Use when creating or modifying a dashboard, chart, or monitoring widget in Grafana or similar tools. Covers
  mockup-first gates, metric verification, PromQL standardization, compact grid positioning, and deployment.
license: MIT
metadata:
  author: gusdecool
  version: "1.0"
---

# Dashboard design

Rules and workflow for creating or modifying dashboards, charts, and monitoring widgets.

## 1. Mockup first gate

Never write or modify dashboard JSON files, manifests, or database queries without showing the visual design first
and getting the user's explicit approval. Present it as:

1. **A visual mockup artifact**: An interactive HTML artifact styled in dark mode (matching Grafana Cloud), or a
   structured layout showing exactly how the panel looks, its columns, and visual thresholds.
2. **The exact metric queries**: The PromQL, SQL, or metric expressions for each series and calculation.
3. **Thresholds and units**: Warning and critical levels (e.g. 70% green, 85% orange, 100% red) and units (`bytes`,
   `percent`, `short`).

Put the approved mockup and queries in the pull request description. If the design changes during review, update the
mockup.

Why: dashboard JSON files are hundreds of lines of nested coordinates and transformations that are impossible to
reliably judge from code diffs; reviewing the visual mockup and queries first prevents wasted build rounds and broken
live panels.

## 2. Upstream metric audit

Before drafting dashboard queries, verify that the required metrics are actively exported and collected.

- Check the collector or agent configuration (for example, Grafana Alloy `prometheus.relabel "keep"` in
  `platform/apps/alloy.yaml`, Fluent Bit filters, or Prometheus scrape configs).
- Ensure required metric names (e.g., `container_spec_memory_limit_bytes`) are not dropped by metric reduction filters
  or relabel rules before creating panels that depend on them.
- If a metric must be enabled upstream, bundle the collector configuration change in the same pull request as the
  dashboard update.

Why: querying a metric that the agent or scraper drops results in permanently empty panels with no syntax errors.

## 3. Standardize scales (% of limit vs raw absolute units)

When monitoring resource utilization across heterogeneous workloads (e.g., pods or containers with different limits):

- **Prefer percentage of limit over raw bytes/cores**: A pod with a 128 MiB limit running at 120 MiB is at 94% capacity
  and about to crash from OOM, but looks like a flat line at the bottom of an absolute bytes graph next to a 2 GiB pod.
- Standardizing to `% of limit` puts every workload on the same 0% to 100% scale, allowing spikes and saturation to be
  spotted instantly.
- Show hard limit (100%) and warning (85%) threshold lines clearly.
- Provide a companion status table showing the absolute numbers (current used, configured limit, and % used) side by
  side.

Why: raw units hide impending failures on small services and exaggerate normal usage on large ones.

## 4. Compact layout and grid positioning

- Grafana uses a 24-column grid (`gridPos`: `x`, `y`, `w`, `h`).
- Group related widgets into compact rows. For companion widgets (such as a time-series spike graph and its
  corresponding status table), arrange them in **1 row with 2 columns** (`w: 12, x: 0` and `w: 12, x: 12`).
- Increment the dashboard's `version` field in the JSON model with every update.

Why: full-width stacked panels waste screen space and force constant scrolling during incident triage.

## 5. Table transformations

For Prometheus instant vector tables joining multiple queries:
- Set `"instant": true` and `"format": "table"` on each target.
- Use `joinByField` (e.g. `byField: "pod"`) to join queries into a single unified row.
- Use `organize` to hide duplicate metadata columns (`Time`, duplicate labels) and assign readable column headers.
- Configure field overrides for units (`bytes`, `percent`) and render percentage columns with a `gradient-gauge` or
  `lcd-gauge` display mode.

Why: raw Prometheus tables emit disconnected time series that clutter the table without transformations.
