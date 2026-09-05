---
paths:
  - "bin/**"
  - "scripts/**"
  - "hooks/**"
  - "tests/**"
  - "policy/**"
  - ".github/**"
  - ".touchstone.toml"
  - "install.sh"
  - "setup.sh"
---

# Testing

Run the smallest deterministic test files that exercise the changed behavior,
then run pre-commit on the changed files. The complete suite is the protected
hosted gate — deterministic, offline, and fetching nothing. The protected
workflow pinned by `policy/github/touchstone-main.json` runs the one
`.touchstone.toml` command, with no third-party dependency. The target
repository carries no duplicate validation workflow. That is deliberate: a
required check that can go red because a package host had a bad minute is not a
gate (#742, #803, #808).

This local optimization is conditional on effective policy containing the
protected workflow. Without it, run the complete suite locally and track the
rollout gap.

Lint is not part of the test suite. It runs at pre-commit and via `pre-commit run --all-files`: `shellcheck`, `shfmt`, `markdownlint`, and `actionlint`. `.pre-commit-config.yaml` and `.markdownlint.json` are the canonical config.
