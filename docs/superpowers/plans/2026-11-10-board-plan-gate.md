# Board Plan Gate Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Enforce a ticket-specific plan and recorded dispatch before product edits.

**Architecture:** A shell gate checks tagged task headings and reads paginated Jira comments through board-lib.
The skill directs workers to use the gate before editing. Shell tests use the existing fake Jira transport.

**Tech Stack:** Bash, jq, Jira REST API.

**Spec:** docs/superpowers/specs/2026-11-10-board-plan-gate-design.md

### Task 1: Gate and worker instructions (judgment)

- [x] Add failing script tests for missing and malformed plans, tagged tasks, comments, pagination, and read errors.
- [x] Implement the gate and update the worker instructions.
- [x] Run the repository test and lint checks, then commit the completed work and this plan.
