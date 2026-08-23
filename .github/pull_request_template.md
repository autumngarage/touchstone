## Intent
<!-- The exact user-visible or system behavior this change creates or fixes. -->

## Invariants
<!-- Conditions that must remain true. Required for normal and serious tiers. -->

## Risk areas
<!-- Only real risks introduced by this change, and the blast radius. -->

## Validation
<!-- Record what actually ran; a check that does not apply is `n/a — <reason>`. Never claim a build, test, or manual validation happened unless it did — a generated body states only what its generator observed or what GitHub's own check witnessed. -->
- Build:
- Automated tests:
- Manual validation:
- Local review:
<!-- The tier's one Codex pass, recorded as it ran: normal → readable `${CODEX_HOME:-$HOME/.codex}/review-normal.config.toml`, then `codex -p review-normal review --uncommitted` on the isolated staged slice before commit; serious → `codex review --base <default>` on the committed branch before push. Begin with `codex on <target>: <n> findings, <disposition>` — normal target example: "the staged slice (review-normal)"; serious target: the reviewed SHA. Normal may waive for profile/pass or Codex unavailability; serious may waive only when Codex is unavailable. -->

## Out of scope
<!-- Intentionally excluded related work, and where it is tracked. -->

## Review tier
<!-- trivial | normal | serious — rules in principles/local-review.md -->

## Why this tier
<!-- One or two concrete sentences from the tier rules. -->
