# Bug: `touchstone init` (no flags) fails with `args[@]: unbound variable` on macOS bash 3.2

**From:** Claude Code (Opus 4.7), end-to-end install of touchstone + cortex into a fresh repo
**Touchstone version:** 2.3.1 (brew, `autumngarage/touchstone`)
**Platform:** macOS 26 (Darwin 25.4.0, arm64), system bash `GNU bash, version 3.2.57(1)-release (arm64-apple-darwin25)`
**Date:** 2026-04-27
**Severity:** High — affects every fresh `touchstone init` on stock macOS when the user passes no flags. This is the documented "Get started" command in the brew caveats.

---

## Summary

Running `touchstone init` with no arguments in a fresh repo aborts before scaffolding any files:

```
==> touchstone v2.3.1 — setting up this project
/opt/homebrew/bin/touchstone: line 242: args[@]: unbound variable
```

Exit code is non-zero; nothing is written. The brewed binary's "Start in a repo: `touchstone init`" caveat is therefore broken out of the box on every macOS install whose default shell is the system bash 3.2.

The bug is latent — has been present since `ae9340b Add toolkit init for existing projects` (2026-04-09) — and shipped through every release since. It went unnoticed because **no test invokes `touchstone init` with zero flags**; every test passes at least one flag (`--help`, `--no-register`, `--no-setup`, etc.) which incidentally populates the `args` array and bypasses the empty-array expansion.

## Repro

```bash
mkdir -p /tmp/tsbug && cd /tmp/tsbug && git init -q
touchstone init
# → /opt/homebrew/bin/touchstone: line 242: args[@]: unbound variable
echo $?
# → 1
```

Or in isolation, the underlying bash quirk:

```bash
/bin/bash -c 'set -euo pipefail; foo=(); echo "${foo[@]}"'
# → /bin/bash: foo[@]: unbound variable
```

## Root cause

`bin/touchstone` runs under `set -euo pipefail` (line 24). `cmd_init` declares an array of forwarded flags at line 98:

```bash
local args=()
```

…populates it conditionally via the flag-parsing loop, then expands it unconditionally at line 242:

```bash
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$project_dir" "${args[@]}"
```

Bash 3.2 (the macOS system bash, frozen at 3.2.57 since 2007 for licensing reasons) treats `"${arr[@]}"` on an empty array as referencing an unset variable when `set -u` is active. Bash 4.4+ fixes this; macOS will not ship 4.x. So the expansion blows up the moment `args` is empty — i.e., whenever the user passes none of the flags that `cmd_init` recognizes.

Confirmed by inspection: every test that exercises `cmd_init` in `tests/test-bootstrap.sh` and `tests/test-claude-md-principles-ref.sh` passes at least one flag, which is why CI is green.

## The same pattern exists at line 235

```bash
exec bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh" "${update_args[@]}"
```

`update_args` is also declared `local update_args=()` (line 222) and expanded with the same shape. It happens not to fire today because the `case` arm that reaches line 235 only runs in the `outdated` init-state branch, and that branch's flag-parsing loop populates `update_args` for at least the `--ship`/`--no-ship` decision. But it's the same hazard one refactor away from biting again. Worth fixing both expansions in the same patch.

The for-loops elsewhere in `bin/touchstone` (`for entry in "${entries[@]}"`, etc.) and in `bootstrap/new-project.sh` are also potential sites — but most of them iterate over arrays that are populated unconditionally, so they don't fire under realistic inputs. The two `bash …/foo.sh "${args[@]}"` exec sites are the load-bearing ones.

## Fix

Standard idiom for bash 3.2-safe empty-array expansion:

```bash
"${args[@]+"${args[@]}"}"
```

— "expand `args[@]` only if it is set." Equivalent under bash 4+ and safe under bash 3.2 with `set -u`.

Suggested patch (illustrative — review for repo style):

```diff
--- a/bin/touchstone
+++ b/bin/touchstone
@@ -232,7 +232,7 @@ cmd_init() {
       # … (preserved comment block)
-      exec bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh" "${update_args[@]}"
+      exec bash "$TOUCHSTONE_ROOT/bootstrap/update-project.sh" ${update_args[@]+"${update_args[@]}"}
       ;;
   esac

   # Fresh init: greet with the branded hero so setup feels like setup.
   tk_hero "setting up this project"

-  bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$project_dir" "${args[@]}"
+  bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$project_dir" ${args[@]+"${args[@]}"}
```

Three alternatives considered and rejected:

1. **Bump shebang to `bash` ≥ 4 (e.g. `#!/usr/bin/env bash` requiring Homebrew bash).** Adds a hard dependency on `brew install bash` for every user, and the brew caveats already invoke `touchstone init` from the system bash environment. The whole point of `#!/usr/bin/env bash` is to let stock macOS work.
2. **Drop `set -u`.** Loses real safety elsewhere in the script. The existing principle ("No silent failures") cuts the other way — keep `set -u`, fix the expansion.
3. **Always seed `args` with a sentinel.** Possible (e.g. always pass `--ship` to `new-project.sh` if `ship_upgrade=true`), but couples the fix to a side effect and doesn't help line 235's case.

The `${arr[@]+"${arr[@]}"}` idiom is the one-line, behavior-preserving fix.

## Regression test

Add to `tests/test-bootstrap.sh` — exercises the path no existing test covers:

```bash
# touchstone init with no flags must succeed (regression: bash 3.2 empty-array
# expansion under `set -u` aborts at "${args[@]}" if not guarded).
PROJECT_INIT_BARE="$TEST_DIR/init-bare"
mkdir -p "$PROJECT_INIT_BARE"
git -C "$PROJECT_INIT_BARE" init >/dev/null
if (cd "$PROJECT_INIT_BARE" && \
    TOUCHSTONE_NO_AUTO_UPDATE=1 \
    "$TOUCHSTONE_ROOT/bin/touchstone" init --no-register --no-setup --no-ship \
   ) >"$TEST_DIR/touchstone-init-bare.txt" 2>&1; then
  assert_contains "$TEST_DIR/touchstone-init-bare.txt" 'touchstone bootstrapped'
else
  echo "FAIL: bare 'touchstone init' must succeed (bash 3.2 empty-args regression)" >&2
  ERRORS=$((ERRORS + 1))
fi
```

(Note: even `--no-register --no-setup --no-ship` populates `args` indirectly — the *truly* bare invocation depends on `args` staying empty. The cleanest regression test is a wrapper that runs `cmd_init` after parsing zero flags. Acceptable shortcut: shell out to `bash -c 'set -u; source bin/touchstone; cmd_init'` in a temp repo. Pick whichever fits the test harness style.)

Belt-and-braces: a `tests/test-shellcheck.sh` rule that flags any unguarded `"${arr[@]}"` expansion under `set -u` would catch the next instance proactively. ShellCheck SC2086/SC2068 don't quite cover this; a bespoke grep-based check inside `test-shellcheck.sh` is probably the right shape.

## Workaround for users hitting this today

Pass any flag that `cmd_init` recognizes — they all populate `args` and dodge the expansion. The most innocuous:

```bash
touchstone init --type swift     # or --type python / --type node / --type generic
```

This is what I used to get past it on the repo I was bootstrapping (a SwiftUI Xcode project at `~/repos/NavExplo`). The init then succeeded normally and scaffolded all 23 files, registered the project, etc.

## Why this matters

`touchstone init` is the **first command** every user runs in a brewed install — it's printed verbatim in the brew caveats. A first-run failure with a bash internals error message is exactly the kind of friction that makes someone give up on a tool before they've used it. The fix is a one-line idiom; the regression test is six lines. Worth shipping as a 2.3.2 patch.

## Suggested release

- `fix(init): guard empty-array expansion for bash 3.2 (`${args[@]+"${args[@]}"}` idiom)`
- Add the no-flag init regression test
- Bump `VERSION` to 2.3.2 and ship through the standard release flow (the homebrew-bump workflow auto-bumps the tap)

Happy to follow up with a PR if useful.
