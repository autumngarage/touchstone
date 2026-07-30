# tests/fixtures — stand-ins for Touchstone's fast test tier

The files in this directory are **not** real Cortex or Sentinel
binaries. They are deterministic stand-ins that mimic the externally
observable contract of `cortex init` and `sentinel init` (file scaffold,
gitignore edits, exit code, and sibling-version output) without paying
the real binaries' startup or banner costs.

`tests/test-bootstrap.sh` prepends this directory to `PATH` so that
every `command -v cortex` / `command -v sentinel` check inside
`bootstrap/new-project.sh` resolves to the stub. The fast tier therefore
exercises Touchstone's bootstrap contract — file ordering, gitignore
scope, atomic-commit semantics, the `--no-with-cortex` / `--no-with-sentinel`
opt-outs — without spawning a real Cortex or Sentinel process.

The slow tier (`tests/slow-bootstrap.sh`) sets
`TOUCHSTONE_REAL_BOOTSTRAP=1`, which skips the `PATH` override and
exercises the real installed binaries. That is the integration smoke
path; it must be run before a release-confidence check whenever the
contract between Touchstone and Cortex or Sentinel changes.

The narrower per-test inline stubs in `test-bootstrap.sh` (R5.1/R5.2,
sibling-detection) override these fixtures by prepending an even-tighter
stub dir to `PATH` for their own scope. They stay tightly scoped because
those tests assert on stub-specific output (e.g. `cortex 9.9.9 (installed)`).
