---
version: 1
---

Write the canonical utility class from the scale, not an arbitrary value, when one exists (`rounded-xs`, not
`rounded-[2px]`).

Why: arbitrary values bypass the design tokens, so spacing, color and radii drift from the system and theming
breaks.
