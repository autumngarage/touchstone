# Engineering guidance qualification — November 10, 2026

## Scope

Baseline: Touchstone main `9b5d57b` (3.21.8). This change modernizes shared
engineering decisions and delivery guidance; it does not change GitHub policy,
review severity, round limits, or publication authorization.

The canonical entry remains TOUCHSTONE.md. The renderer distributes it to
AGENTS.md and GEMINI.md; the existing machine installer distributes it to
Claude, Codex and Gemini instruction files, routed principles, and skills.
No parallel prompt loader or evaluation service was added.

## Deterministic evidence

The existing steering contract test rejects the old unconditional stop,
blanket test deferral, and "fix the valid findings" instructions. It retains
coverage for migration states, unsupported inputs, ownership, compatibility,
review and delivery boundaries, with assertions updated to the concise text.
The existing installation fixture now checks engineering/delivery guidance
in all three installed driver files. Rendering, size/path integrity and
contract checks validate distribution, not model compliance.

## Manual behavior probes

Ran the installed Claude and Codex CLIs in an isolated temporary directory,
using the candidate entry prompt, engineering principles and preimplementation
guidance as native CLAUDE.md and AGENTS.md files. No diff was supplied or
reviewed. Asked for next actions only; Claude tools were disabled, Codex was
read-only, and neither was authorized to mutate repositories or GitHub.
Default configured models were used; no model override or production rollout.

| Scenario | Codex | Claude |
|---|---|---|
| Existing adapter versus convenient new wrapper | Extend adapter | Extend adapter |
| Tiny new reproducer during iteration | Write reproducer | Write reproducer |
| Already-approved migration needs reader coexistence | Proceed with owned transition | Proceed with owned transition |
| Valid P2 on current PR | Acknowledge/resolve, no fix | Initially suggested optional follow-up |
| Authorized merge, checks and review green | Merge and verify | Merge, verify and close out |
| One-off bug already covered; optional AST scanner | Retain behavioral coverage | Retain behavioral coverage |

The Claude P2 response exposed ambiguity in the short entry prompt. After
making the existing no-unsolicited-follow-up rule explicit there, a second
Claude probe chose acknowledge/resolve/merge with no ticket unless requested.
The rule already existed in the canonical workflow; this clarifies activation.

These are small, qualitative probes, not a controlled before/after benchmark
or proof of sustained merge throughput. They do not prove real tool execution,
account for every model/configuration, or make an already-running chat reload
changed instructions. Installation is separately checked by deterministic tests.
