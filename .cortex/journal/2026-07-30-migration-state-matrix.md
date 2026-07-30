# Require explicit migration state matrices

**Date:** 2026-07-30
**Type:** decision
**Trigger:** T1.1
**Cites:** issue/#558

> Migration work must define behavior for every observable repository state before implementation begins.

## Context

Touchstone updates cross old and new customer installations. The prior
pre-implementation checklist asked for compatibility thinking but did not force
agents to account for absent, legacy-only, canonical-only, partial, and invalid
states. That gap allowed temporary migration code to become ambiguous or
permanent.

## What we decided

For migrations, agents must write a five-state matrix before implementation and
name the outcome and invariant for each state. Compatibility code must be
classified as either active behavior or an inert, time-bounded shim with a
removal condition. Focused fixtures must cover the states the change can
observe.

## Consequences / action items

- [x] Add the matrix contract to `principles/pre-implementation-checklist.md`.
- [x] Route the same requirement through the pre-implementation skill.
- [x] Add steering-contract assertions so generated guidance cannot drop it.
