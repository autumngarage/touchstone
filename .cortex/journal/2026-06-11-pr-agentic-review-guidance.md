# Shift Delivery Guidance To PR-Visible Agentic Reviews

**Date:** 2026-06-11
**Type:** decision
**Trigger:** T1.1
**Cites:** principles/ai-delivery-architecture.md, principles/git-workflow.md

> Touchstone delivery guidance now treats the pull request as the review surface the driving CLI must watch through approval and merge.

## Context

The existing steering emphasized a local merge gate: open the PR, run deterministic checks and Conductor review at merge time, then merge. The desired direction is that the PR becomes the visible review/check surface, and the driving LLM remains responsible for watching PR comments, addressing actionable feedback, and merging only after approval.

## What we decided

We updated the canonical delivery guidance to make PR-visible review the lifecycle center. `TOUCHSTONE.md`, `principles/ai-delivery-architecture.md`, and `principles/git-workflow.md` now say that the driver owns PR comment triage, fix commits, approval tracking, and merge. Conductor remains the worker/reviewer router for Touchstone-managed LLM review, and local merge review is described as a final backstop where projects still use it.

## Consequences / action items

- [x] Update steering and architecture docs to describe PR-visible agentic review.
- [x] Update the dogfood contract test so agents must infer PR watching and merge-after-approval behavior.
- [ ] Follow up with implementation work where scripts still model review primarily as a local merge gate.
