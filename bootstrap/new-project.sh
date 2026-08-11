#!/usr/bin/env bash
#
# bootstrap/new-project.sh — spin up a new project with touchstone files.
#
# Usage:
#   new-project.sh <project-dir>
#   new-project.sh <project-dir> --no-register   # skip adding to ~/.touchstone-projects
#   new-project.sh <project-dir> --type node|python|swift|rust|go|generic|auto
#   new-project.sh <project-dir> --gitbutler
#
# What this does:
#   1. Creates the directory if it doesn't exist, initializes git
#   2. Copies templates, principles, hooks, and scripts into the project
#   3. Makes scripts executable
#   4. Writes .touchstone-version and .touchstone-manifest
#   5. Registers the project in ~/.touchstone-projects (for update-all)
#   6. Prints next steps
#
# After running, fill in the {{PLACEHOLDERS}} in CLAUDE.md, AGENTS.md, and GEMINI.md.
# CLAUDE.md steers Claude Code; AGENTS.md steers Codex and other agents; GEMINI.md steers Gemini CLI.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib/safe-write.sh
source "$TOUCHSTONE_ROOT/lib/safe-write.sh"
# shellcheck source=lib/sed-inplace.sh
source "$TOUCHSTONE_ROOT/lib/sed-inplace.sh"
# shellcheck source=../lib/install-hooks.sh
source "$TOUCHSTONE_ROOT/lib/install-hooks.sh"
# shellcheck source=../lib/touchstone-block.sh
source "$TOUCHSTONE_ROOT/lib/touchstone-block.sh"
# shellcheck source=../lib/install-skills.sh
source "$TOUCHSTONE_ROOT/lib/install-skills.sh"

REGISTER=true

REGISTER_REQUESTED=false # Doctrine 0002: track whether --register / --no-register was passed.
INPUT_TYPE=""
# shellcheck disable=SC2034  # set below, read by future --type-aware branches.
INPUT_TYPE_REQUESTED=false # Tracks explicit --type (not the auto-detect fall-through).
INPUT_GIT_WORKFLOW=""
INPUT_GITBUTLER_MCP=""
INPUT_CI=""
INPUT_SCAFFOLD_TESTS=false
WORKFLOW_CONFIG_REQUESTED=false

# Doctrine 0002 wizard — new state. Each *_REQUESTED flag records whether the
# user passed the flag-form, so the interactive block can skip prompts the
# user has already answered via flags (flag precedence).
YES_MODE="${YES_MODE:-false}"
SKIP_LANGUAGE_SCAFFOLD=false
SKIP_LANGUAGE_SCAFFOLD_REQUESTED=false
WITH_CORTEX="" # unset | true | false
WITH_CORTEX_REQUESTED=false
WITH_SENTINEL=""
WITH_SENTINEL_REQUESTED=false
INITIAL_COMMIT=true
INITIAL_COMMIT_REQUESTED=false
GITHUB_MODE="" # unset | private | public | none
GITHUB_MODE_REQUESTED=false

usage() {
  echo "Usage: $0 <project-dir> [--yes|-y] [--register|--no-register] [--type node|python|swift|rust|go|generic|auto] [--skip-language-scaffold] [--gitbutler|--no-gitbutler] [--gitbutler-mcp|--no-gitbutler-mcp] [--ci github|none] [--scaffold-tests] [--with-cortex|--no-with-cortex] [--with-sentinel|--no-with-sentinel] [--initial-commit|--no-initial-commit] [--github-private|--github-public|--no-github]"
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

# Convert a directory basename to PascalCase for Swift targets.
# Split on `-`, `_`, or whitespace; capitalize each word; strip everything else.
# Examples:
#   autumn-mail     -> AutumnMail
#   my_cool_app     -> MyCoolApp
#   autumn-mail-pro -> AutumnMailPro
to_pascal_case() {
  local raw="$1" word out=""
  # Replace separators with spaces, then iterate words.
  raw="$(printf '%s' "$raw" | tr '_-' '  ')"
  for word in $raw; do
    # Drop any character outside [A-Za-z0-9] so the result is a valid Swift identifier.
    word="$(printf '%s' "$word" | tr -cd '[:alnum:]')"
    [ -z "$word" ] && continue
    local first rest
    first="$(printf '%s' "$word" | cut -c1 | tr '[:lower:]' '[:upper:]')"
    rest="$(printf '%s' "$word" | cut -c2-)"
    out="${out}${first}${rest}"
  done
  # Fallback: if nothing survived (e.g., basename was all separators), use a safe default.
  if [ -z "$out" ]; then
    out="App"
  fi
  # Swift identifiers can't start with a digit; prefix with underscore if needed.
  case "$out" in
    [0-9]*) out="_$out" ;;
  esac
  printf '%s' "$out"
}

escape_sed_replacement() {
  printf '%s' "$1" | sed 's/[\\/&]/\\&/g'
}

next_backup_path() {
  local dst="$1"
  local backup="$dst.bak"
  local i=1

  while [ -e "$backup" ]; do
    backup="$dst.bak.$i"
    i=$((i + 1))
  done

  printf '%s' "$backup"
}

normalize_project_type() {
  local value="$1"
  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"

  case "$value" in
    "" | auto) printf 'auto' ;;
    node | js | javascript | ts | typescript) printf 'node' ;;
    python | py) printf 'python' ;;
    swift) printf 'swift' ;;
    rust | rs) printf 'rust' ;;
    go | golang) printf 'go' ;;
    generic) printf 'generic' ;;
    *)
      echo "ERROR: unknown project type '$1' (expected node, python, swift, rust, go, generic, or auto)" >&2
      return 1
      ;;
  esac
}

normalize_git_workflow() {
  local value="$1"
  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"

  case "$value" in
    "" | git | plain | standard | classic) printf 'git' ;;
    gitbutler | butler | but) printf 'gitbutler' ;;
    *)
      echo "ERROR: unknown git workflow '$1' (expected git or gitbutler)" >&2
      return 1
      ;;
  esac
}

normalize_yes_no() {
  local value="$1"
  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
  case "$value" in
    y | yes | true | 1 | on) printf 'true' ;;
    n | no | false | 0 | off) printf 'false' ;;
    *) printf '%s' "$value" ;;
  esac
}

prompt_yes_no() {
  local prompt="$1"
  local default="$2"
  local suffix answer

  if [ "$default" = "true" ]; then
    suffix="[Y/n]"
  else
    suffix="[y/N]"
  fi

  # Doctrine 0002: --yes accepts all defaults without prompting.
  if [ "${YES_MODE:-false}" = "true" ]; then
    printf '%s' "$default"
    return 0
  fi

  read -r -p "   $prompt $suffix: " answer
  answer="$(trim "$answer")"
  if [ -z "$answer" ]; then
    printf '%s' "$default"
  else
    normalize_yes_no "$answer"
  fi
}

detect_node_package_manager() {
  local dir="$1" package_manager

  if [ -f "$dir/package.json" ]; then
    package_manager="$(sed -n 's/.*"packageManager"[[:space:]]*:[[:space:]]*"\([^@"]*\)@.*/\1/p' "$dir/package.json" | head -1)"
    if [ -z "$package_manager" ]; then
      package_manager="$(sed -n 's/.*"packageManager"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$dir/package.json" | head -1)"
    fi
    if [ -n "$package_manager" ]; then
      printf '%s\n' "$package_manager"
      return 0
    fi
  fi

  if [ -f "$dir/pnpm-lock.yaml" ] || [ -f "$dir/pnpm-workspace.yaml" ]; then
    printf 'pnpm\n'
  elif [ -f "$dir/yarn.lock" ]; then
    printf 'yarn\n'
  elif [ -f "$dir/bun.lock" ] || [ -f "$dir/bun.lockb" ]; then
    printf 'bun\n'
  elif [ -f "$dir/package.json" ]; then
    printf 'npm\n'
  else
    printf '\n'
  fi
}

detect_project_type() {
  local dir="$1"

  if [ -f "$dir/pnpm-workspace.yaml" ]; then
    printf 'node\n'
  elif [ -f "$dir/package.json" ] || [ -f "$dir/tsconfig.json" ]; then
    printf 'node\n'
  elif [ -f "$dir/Cargo.toml" ]; then
    printf 'rust\n'
  elif [ -f "$dir/Package.swift" ]; then
    printf 'swift\n'
  elif [ -f "$dir/go.mod" ]; then
    printf 'go\n'
  elif [ -f "$dir/uv.lock" ] || [ -f "$dir/pyproject.toml" ] || [ -f "$dir/requirements.txt" ]; then
    printf 'python\n'
  else
    printf 'generic\n'
  fi
}

detect_monorepo() {
  local dir="$1"

  if [ -f "$dir/pnpm-workspace.yaml" ]; then
    printf 'true\n'
  elif [ -f "$dir/Cargo.toml" ] && grep -q '^\[workspace\]' "$dir/Cargo.toml" 2>/dev/null; then
    printf 'true\n'
  elif [ -f "$dir/package.json" ] && grep -q '"workspaces"' "$dir/package.json" 2>/dev/null; then
    printf 'true\n'
  else
    printf 'false\n'
  fi
}

detect_targets() {
  local root="$1" base target_dir profile targets=""

  for base in apps packages services; do
    [ -d "$root/$base" ] || continue
    for target_dir in "$root/$base"/*; do
      [ -d "$target_dir" ] || continue
      profile="$(detect_project_type "$target_dir")"
      [ "$profile" = "generic" ] && continue
      if [ -n "$targets" ]; then
        targets="${targets},"
      fi
      targets="${targets}$(basename "$target_dir"):$base/$(basename "$target_dir"):$profile"
    done
  done

  printf '%s\n' "$targets"
}

# Profile-aware test scaffolder. Called only when --scaffold-tests is set.
# Writes exactly one smoke test per profile when no tests already exist —
# never overwrites, so re-running with the flag on a project that has real
# tests is a no-op. Framework-agnostic filenames so whatever the project
# adopts later (vitest/jest/bun test; pytest; go test; cargo test) discovers
# these without config changes.
scaffold_smoke_test_for_profile() {
  local project_dir="$1" profile="$2"

  case "$profile" in
    python)
      if _profile_has_any_tests_python "$project_dir"; then
        echo "==> tests: already present; skipping scaffold"
        return 0
      fi
      mkdir -p "$project_dir/tests"
      if [ ! -f "$project_dir/tests/__init__.py" ]; then
        : >"$project_dir/tests/__init__.py"
      fi
      cat >"$project_dir/tests/test_smoke.py" <<'PYTEST'
# Placeholder smoke test. Replace with real coverage as soon as there's
# behavior worth testing — touchstone-run.sh test runs whatever exists here.
def test_smoke() -> None:
    assert True
PYTEST
      echo "==> tests: scaffolded tests/test_smoke.py (pytest)"
      ;;
    node)
      if _profile_has_any_tests_node "$project_dir"; then
        echo "==> tests: already present; skipping scaffold"
        return 0
      fi
      mkdir -p "$project_dir/tests"
      # .test.ts works with vitest, jest, and bun test without framework config.
      # describe/it globals are injected by all three.
      cat >"$project_dir/tests/smoke.test.ts" <<'NODETEST'
// Placeholder smoke test. Replace with real coverage as soon as there's
// behavior worth testing — touchstone-run.sh test runs whatever "test" script
// package.json declares. Works with vitest/jest/bun test out of the box.
describe("smoke", () => {
  it("passes", () => {
    expect(true).toBe(true);
  });
});
NODETEST
      echo "==> tests: scaffolded tests/smoke.test.ts (vitest/jest/bun test)"
      ;;
    go)
      if _profile_has_any_tests_go "$project_dir"; then
        echo "==> tests: already present; skipping scaffold"
        return 0
      fi
      # Determine the package declaration for smoke_test.go. Go packages are
      # declared per-file and must match every other .go file in the same
      # directory, but a Go *module* path (e.g. github.com/acme/widget) is
      # not a valid package identifier — package names are restricted to
      # [a-zA-Z_][a-zA-Z0-9_]*. Match an existing root-level .go file if one
      # exists; otherwise default to `main` (safe and compilable even in a
      # library-style module with no other .go files at root).
      local package_name="" first_go
      first_go="$(find "$project_dir" -maxdepth 1 -type f -name '*.go' \
        -not -name '*_test.go' -print -quit 2>/dev/null || true)"
      if [ -n "$first_go" ] && [ -f "$first_go" ]; then
        package_name="$(sed -n 's/^package \([a-zA-Z_][a-zA-Z0-9_]*\).*/\1/p' "$first_go" | head -1)"
      fi
      package_name="${package_name:-main}"
      cat >"$project_dir/smoke_test.go" <<GOTEST
// Placeholder smoke test. Replace with real coverage as soon as there's
// behavior worth testing — touchstone-run.sh test runs go test ./... over
// every package in the module.
package ${package_name}

import "testing"

func TestSmoke(t *testing.T) {
	if false {
		t.Fatal("unreachable")
	}
}
GOTEST
      echo "==> tests: scaffolded smoke_test.go (go test, package ${package_name})"
      ;;
    rust)
      # cargo init already creates src/lib.rs with #[test] or tests/ — scaffolding
      # would either conflict or duplicate. Skip with a note.
      echo "==> tests: skipped for rust (cargo init already scaffolds tests)"
      ;;
    swift)
      # Swift tests are scaffolded by scaffold_swift_package_boilerplate on fresh
      # --type swift bootstraps. For re-inits with existing Swift content, leave
      # whatever's there alone — users own their tests.
      if _has_any_swift_sources "$project_dir"; then
        echo "==> tests: swift sources already present; scaffold is a no-op"
      else
        echo "==> tests: swift tests scaffolded by boilerplate function"
      fi
      ;;
    generic | "")
      echo "==> tests: profile is 'generic' — no default test layout to scaffold"
      echo "          set test_command= in .touchstone-config for your stack"
      ;;
    *)
      echo "==> tests: scaffold not implemented for profile '$profile'"
      ;;
  esac
}

_profile_has_any_tests_python() {
  local dir="$1" matches
  # Match discoverable test FILES, not merely a tests/ directory — an empty
  # tests/ (or one with only __init__.py / helpers) doesn't satisfy the
  # purpose of scaffolding and leaves the "validate silently skips" gap open.
  matches="$(find "$dir" -maxdepth 3 -type f \
    \( -name 'test_*.py' -o -name '*_test.py' \) -print -quit 2>/dev/null || true)"
  [ -n "$matches" ]
}

_profile_has_any_tests_node() {
  local dir="$1" matches
  # Same reason as Python — treating any __tests__/tests/test directory as
  # "tests present" lets empty scaffolds pass through silently. Covers all
  # four extension pairs (.ts/.tsx/.js/.jsx) for both .test.* and .spec.*
  # conventions — React/TS projects commonly use Button.spec.tsx.
  matches="$(find "$dir" -maxdepth 4 -type f \
    \( -name '*.test.ts' -o -name '*.test.tsx' -o -name '*.test.js' -o -name '*.test.jsx' \
    -o -name '*.spec.ts' -o -name '*.spec.tsx' -o -name '*.spec.js' -o -name '*.spec.jsx' \) \
    -print -quit 2>/dev/null || true)"
  [ -n "$matches" ]
}

_profile_has_any_tests_go() {
  local dir="$1" matches
  matches="$(find "$dir" -maxdepth 4 -type f -name '*_test.go' -print -quit 2>/dev/null || true)"
  [ -n "$matches" ]
}

# Treat any pre-existing Package.swift, Sources/*.swift, or Tests/*.swift as
# "already scaffolded" so re-running bootstrap on a real Swift project never
# clobbers user code. Same intent as _profile_has_any_tests_* — presence of a
# directory isn't enough; match actual content.
_has_any_swift_sources() {
  local dir="$1" matches
  if [ -f "$dir/Package.swift" ]; then
    return 0
  fi
  matches="$(find "$dir/Sources" "$dir/Tests" -maxdepth 4 -type f -name '*.swift' -print -quit 2>/dev/null || true)"
  [ -n "$matches" ]
}

# Scaffold a minimal Swift Package for --type swift on a fresh bootstrap.
# Writes Package.swift, Sources/<PascalName>/<PascalName>App.swift, and
# Tests/<PascalName>Tests/SmokeTests.swift. Skips the whole scaffold if any
# Swift content is already present, so re-running on a real project is a no-op.
scaffold_swift_package_boilerplate() {
  local project_dir="$1" pascal_name
  pascal_name="$(to_pascal_case "$(basename "$project_dir")")"

  if _has_any_swift_sources "$project_dir"; then
    echo "==> swift: already present; skipping boilerplate scaffold"
    return 0
  fi

  mkdir -p "$project_dir/Sources/$pascal_name" "$project_dir/Tests/${pascal_name}Tests"

  cat >"$project_dir/Package.swift" <<SWIFTPKG
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "${pascal_name}",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "${pascal_name}", targets: ["${pascal_name}"]),
    ],
    targets: [
        .executableTarget(
            name: "${pascal_name}",
            path: "Sources/${pascal_name}"
        ),
        .testTarget(
            name: "${pascal_name}Tests",
            dependencies: ["${pascal_name}"],
            path: "Tests/${pascal_name}Tests"
        ),
    ]
)
SWIFTPKG

  cat >"$project_dir/Sources/$pascal_name/${pascal_name}App.swift" <<SWIFTAPP
import SwiftUI

@main
struct ${pascal_name}App: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("${pascal_name}")
                .font(.largeTitle)
        }
        .frame(minWidth: 480, minHeight: 320)
        .padding()
    }
}
SWIFTAPP

  cat >"$project_dir/Tests/${pascal_name}Tests/SmokeTests.swift" <<SWIFTTEST
import XCTest
@testable import ${pascal_name}

final class SmokeTests: XCTestCase {
    func testPackageBuildsAndLinks() {
        XCTAssertTrue(true, "If this test runs, the package builds and links.")
    }
}
SWIFTTEST

  echo "==> swift: scaffolded Package.swift, Sources/${pascal_name}/, Tests/${pascal_name}Tests/"
}

# Append per-profile entries to .gitignore after the base templates/gitignore copy.
# Only runs on fresh scaffolds and is idempotent — only appends entries not already
# present. Other profiles are no-ops for this PR.
append_profile_gitignore_entries() {
  local project_dir="$1" profile="$2"
  local gitignore="$project_dir/.gitignore"

  [ -f "$gitignore" ] || return 0

  case "$profile" in
    swift)
      local entries=(
        ".build/"
        ".swiftpm/"
        "*.xcodeproj/"
        "DerivedData/"
        "Package.resolved"
      )
      local header="# Swift / SPM"
      local needs_append=false entry
      for entry in "${entries[@]}"; do
        if ! grep -qxF "$entry" "$gitignore" 2>/dev/null; then
          needs_append=true
          break
        fi
      done
      if [ "$needs_append" = false ]; then
        return 0
      fi
      {
        # Ensure the previous line doesn't run into the new block.
        if [ -s "$gitignore" ] && [ -n "$(tail -c1 "$gitignore")" ]; then
          printf '\n'
        fi
        printf '\n%s\n' "$header"
        for entry in "${entries[@]}"; do
          if ! grep -qxF "$entry" "$gitignore" 2>/dev/null; then
            printf '%s\n' "$entry"
          fi
        done
      } >>"$gitignore"
      echo "==> .gitignore: appended Swift / SPM entries"
      ;;
    *)
      return 0
      ;;
  esac
}

# Resolve the project profile exactly like scripts/touchstone-run.sh:load_config
# and bin/touchstone:cmd_doctor_project do, so per-profile flags here dispatch
# against the same profile the runner and doctor would use:
#   - project_type= and profile= are aliases for the same slot, last-write-wins
#   - empty or "auto" -> detect from manifest files
#   - "generic" with a detected non-generic profile -> upgrade to the detected
resolve_project_type_from_config() {
  local dir="$1" line value candidate result=""

  if [ -f "$dir/.touchstone-config" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line#"${line%%[![:space:]]*}"}"
      case "$line" in \#* | "") continue ;; esac
      case "$line" in *=*) ;; *) continue ;; esac
      candidate="${line%%=*}"
      candidate="${candidate#"${candidate%%[![:space:]]*}"}"
      candidate="${candidate%"${candidate##*[![:space:]]}"}"
      case "$candidate" in
        project_type | profile)
          value="${line#*=}"
          value="${value#"${value%%[![:space:]]*}"}"
          value="${value%"${value##*[![:space:]]}"}"
          result="$value"
          ;;
      esac
    done <"$dir/.touchstone-config"
  fi

  if [ -z "$result" ] || [ "$result" = "auto" ]; then
    result="$(detect_project_type "$dir")"
  elif [ "$result" = "generic" ]; then
    local detected
    detected="$(detect_project_type "$dir")"
    [ "$detected" != "generic" ] && result="$detected"
  fi

  printf '%s' "$result"
}

if [ "$#" -lt 1 ]; then
  usage >&2
  exit 1
fi

case "$1" in
  -h | --help)
    usage
    exit 0
    ;;
  -*)
    echo "ERROR: missing project-dir before option '$1'" >&2
    usage >&2
    exit 1
    ;;
esac

PROJECT_DIR="$1"
shift

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    -y | --yes)
      YES_MODE=true
      shift
      ;;
    --no-register)
      REGISTER=false
      REGISTER_REQUESTED=true
      shift
      ;;
    --register)
      REGISTER=true
      REGISTER_REQUESTED=true
      shift
      ;;
    --with-cortex)
      WITH_CORTEX=true
      WITH_CORTEX_REQUESTED=true
      shift
      ;;
    --no-with-cortex)
      WITH_CORTEX=false
      WITH_CORTEX_REQUESTED=true
      shift
      ;;
    --with-sentinel)
      WITH_SENTINEL=true
      WITH_SENTINEL_REQUESTED=true
      shift
      ;;
    --no-with-sentinel)
      WITH_SENTINEL=false
      WITH_SENTINEL_REQUESTED=true
      shift
      ;;
    --initial-commit)
      INITIAL_COMMIT=true
      INITIAL_COMMIT_REQUESTED=true
      shift
      ;;
    --no-initial-commit)
      INITIAL_COMMIT=false
      INITIAL_COMMIT_REQUESTED=true
      shift
      ;;
    --github-private)
      GITHUB_MODE=private
      GITHUB_MODE_REQUESTED=true
      shift
      ;;
    --github-public)
      GITHUB_MODE=public
      GITHUB_MODE_REQUESTED=true
      shift
      ;;
    --no-github)
      GITHUB_MODE=none
      GITHUB_MODE_REQUESTED=true
      shift
      ;;
    --skip-language-scaffold)
      SKIP_LANGUAGE_SCAFFOLD=true
      SKIP_LANGUAGE_SCAFFOLD_REQUESTED=true
      shift
      ;;
    --type)
      [ "$#" -ge 2 ] || {
        echo "ERROR: --type requires a value (node, python, swift, rust, go, generic, auto)" >&2
        exit 1
      }
      INPUT_TYPE="$(normalize_project_type "$2")"
      # shellcheck disable=SC2034  # reserved for --type-aware branches.
      INPUT_TYPE_REQUESTED=true
      shift 2
      ;;
    --unsafe-paths | --reviewer | --local-review-command | --review-routing | --small-review-lines)
      [ "$#" -ge 2 ] || {
        echo "ERROR: $1 requires a value" >&2
        exit 1
      }
      echo "WARNING: $1 is retired and ignored; GitHub Codex PR review is mandatory." >&2
      shift 2
      ;;
    --no-ai-review | --no-review | --review-assist | --no-review-assist | --review-autofix | --no-review-autofix)
      echo "WARNING: $1 is retired and ignored; GitHub Codex PR review is mandatory." >&2
      shift
      ;;
    --git-workflow)
      [ "$#" -ge 2 ] || {
        echo "ERROR: --git-workflow requires a value (git or gitbutler)" >&2
        exit 1
      }
      INPUT_GIT_WORKFLOW="$(normalize_git_workflow "$2")"
      WORKFLOW_CONFIG_REQUESTED=true
      shift 2
      ;;
    --gitbutler)
      INPUT_GIT_WORKFLOW="gitbutler"
      WORKFLOW_CONFIG_REQUESTED=true
      shift
      ;;
    --no-gitbutler)
      INPUT_GIT_WORKFLOW="git"
      INPUT_GITBUTLER_MCP=false
      WORKFLOW_CONFIG_REQUESTED=true
      shift
      ;;
    --gitbutler-mcp)
      INPUT_GITBUTLER_MCP=true
      WORKFLOW_CONFIG_REQUESTED=true
      shift
      ;;
    --no-gitbutler-mcp)
      INPUT_GITBUTLER_MCP=false
      WORKFLOW_CONFIG_REQUESTED=true
      shift
      ;;
    --ci)
      # Accept either `--ci` alone (defaults to github) or `--ci <provider>`
      # for future providers (gitlab, circle). For now only github is shipped.
      if [ "$#" -ge 2 ] && [[ "$2" != --* ]]; then
        case "$2" in
          github | none)
            INPUT_CI="$2"
            shift 2
            ;;
          *)
            echo "ERROR: --ci value must be one of: github, none" >&2
            exit 1
            ;;
        esac
      else
        INPUT_CI="github"
        shift
      fi
      ;;
    --no-ci)
      INPUT_CI="none"
      shift
      ;;
    --scaffold-tests)
      INPUT_SCAFFOLD_TESTS=true
      shift
      ;;
    *)
      echo "ERROR: unknown argument '$1'" >&2
      exit 1
      ;;
  esac
done

# Resolve to absolute path.
if [[ "$PROJECT_DIR" != /* ]]; then
  PROJECT_DIR="$(pwd)/$PROJECT_DIR"
fi

# Detect re-init state early so prompts and summary adapt to the case.
# Fresh = first touchstone bootstrap; reinit = repair/reconcile an already-touchstoned project.
if [ -f "$PROJECT_DIR/.touchstone-version" ]; then
  RE_INIT=true
  echo "==> Reconciling touchstone files in $PROJECT_DIR"
else
  RE_INIT=false
  echo "==> Bootstrapping project at $PROJECT_DIR"
fi

# Doctrine 0002 — Ctrl-C during the wizard must not leave a half-scaffolded dir behind.
# We only auto-remove the project dir on signal / unexpected exit if (a) we are the
# ones who created it on this run (fresh bootstrap into a non-existent path) and (b)
# the scaffold hasn't completed. A success flag cleared at the bottom of the script
# suppresses cleanup on normal exit. Reinits never touch the filesystem on cleanup —
# that would destroy a user's existing project.
PROJECT_DIR_PREEXISTED=false
if [ -e "$PROJECT_DIR" ]; then
  PROJECT_DIR_PREEXISTED=true
fi
WIZARD_COMPLETE=false
wizard_cleanup() {
  local exit_code=$?
  if [ "$WIZARD_COMPLETE" = true ]; then
    return 0
  fi
  if [ "$RE_INIT" = true ] || [ "$PROJECT_DIR_PREEXISTED" = true ]; then
    # Never remove a pre-existing dir — user might have files there.
    return 0
  fi
  if [ -d "$PROJECT_DIR" ]; then
    echo ""
    echo "==> Cancelled — removing partial scaffold at $PROJECT_DIR" >&2
    rm -rf "$PROJECT_DIR"
  fi
  if [ "$exit_code" -eq 0 ]; then
    exit 130
  fi
}
trap wizard_cleanup EXIT
trap 'exit 130' INT TERM

# Summary counters — populated by copy_file / copy_file_force, emitted at end.
FILES_ADDED=0
FILES_EXISTING=0
FILES_UPDATED=0
FILES_UNCHANGED=0

# Create directory if needed.
mkdir -p "$PROJECT_DIR"

# Init git if not already a repo.
# Respect the user's git config init.defaultBranch so touchstone doesn't force
# "master" on modern setups; fall back to "main" when the config is empty.
if [ ! -d "$PROJECT_DIR/.git" ]; then
  default_branch="$(git config --get init.defaultBranch 2>/dev/null || true)"
  default_branch="$(trim "$default_branch")"
  default_branch="${default_branch:-main}"
  echo "==> Initializing git repo (default branch: $default_branch) ..."
  git -C "$PROJECT_DIR" init -b "$default_branch"
fi

# Helper: copy a project-owned file if it does not already exist.
LAST_COPY_CREATED=false
copy_file() {
  local src="$1"
  local dst="$2"
  local dst_dir
  dst_dir="$(dirname "$dst")"

  # Guard against symlink traversal (final component + ancestor dirs) before the
  # mkdir/cp below; see touchstone_ensure_safe_dest.
  if ! touchstone_ensure_safe_dest "$dst" "$PROJECT_DIR" false; then
    LAST_COPY_CREATED=false
    return 1
  fi
  mkdir -p "$dst_dir"

  if [ -e "$dst" ]; then
    LAST_COPY_CREATED=false
    if [ ! -f "$dst" ]; then
      echo "ERROR: destination exists but is not a regular file: $dst" >&2
      return 1
    fi
    echo "    exists (skipped): $(basename "$dst")"
    FILES_EXISTING=$((FILES_EXISTING + 1))
  else
    cp "$src" "$dst"
    LAST_COPY_CREATED=true
    echo "    + $(basename "$dst")"
    FILES_ADDED=$((FILES_ADDED + 1))
  fi
}

# Helper: copy a Touchstone-owned file, backing up existing local content first.
copy_file_force() {
  local src="$1"
  local dst="$2"
  local backup_path dst_dir
  dst_dir="$(dirname "$dst")"

  # Guard against symlink traversal before any mkdir/cp/backup below.
  if ! touchstone_ensure_safe_dest "$dst" "$PROJECT_DIR" false; then
    return 1
  fi
  mkdir -p "$dst_dir"

  if [ -f "$dst" ] && diff -q "$src" "$dst" >/dev/null 2>&1; then
    echo "    same (skipped): $(basename "$dst")"
    FILES_UNCHANGED=$((FILES_UNCHANGED + 1))
    return
  fi

  if [ -e "$dst" ]; then
    if [ ! -f "$dst" ]; then
      echo "ERROR: destination exists but is not a regular file: $dst" >&2
      return 1
    fi
    backup_path="$(next_backup_path "$dst")"
    cp "$dst" "$backup_path"
    cp "$src" "$dst"
    echo "    ! $(basename "$dst") (backed up as $(basename "$backup_path"))"
    FILES_UPDATED=$((FILES_UPDATED + 1))
    return
  fi

  cp "$src" "$dst"
  echo "    + $(basename "$dst")"
  FILES_ADDED=$((FILES_ADDED + 1))
}

write_touchstone_manifest() {
  local manifest_tmp
  manifest_tmp="$(mktemp -t touchstone-manifest.XXXXXX)"
  {
    printf '# Managed by touchstone. These paths may be updated by `touchstone update`.\n'
    printf '.touchstone-manifest\n'
    printf '.touchstone-version\n'
    printf 'TOUCHSTONE.md\n'
    printf '.github/workflows/issue-claim-check.yml\n'
    for f in "$TOUCHSTONE_ROOT/principles/"*.md; do
      printf 'principles/%s\n' "$(basename "$f")"
    done
    printf 'scripts/branch-guard.sh\n'
    printf 'scripts/emergency-disclosure.sh\n'
    printf 'scripts/cortex-pr-merged-hook.sh\n'
    printf 'scripts/touchstone-run.sh\n'
    printf 'scripts/open-pr.sh\n'
    printf 'scripts/merge-pr.sh\n'
    printf 'scripts/claim-issue.sh\n'
    printf 'scripts/respond-review.sh\n'
    printf 'scripts/issue-claim-check.sh\n'
    printf 'scripts/cleanup-branches.sh\n'
    printf 'scripts/spawn-worktree.sh\n'
    printf 'scripts/cleanup-worktrees.sh\n'
    printf 'lib/toml.sh\n'
    printf 'lib/events.sh\n'
    printf 'lib/codex-auth.sh\n'
    printf 'lib/script-sync-guard.sh\n'
    printf 'lib/sha256.sh\n'
    printf 'lib/preflight.sh\n'
    printf 'lib/preflight-scope.sh\n'
    if [ "$INPUT_TYPE" = "python" ]; then
      printf 'scripts/run-pytest-in-venv.sh\n'
    fi
    printf '.claude/settings.json\n'
  } >"$manifest_tmp"
  if copy_file_force "$manifest_tmp" "$PROJECT_DIR/.touchstone-manifest"; then
    rm -f "$manifest_tmp"
  else
    rm -f "$manifest_tmp"
    return 1
  fi
}

echo ""
echo "==> Copying templates (project-owned, won't be auto-updated):"
copy_file "$TOUCHSTONE_ROOT/templates/CLAUDE.md" "$PROJECT_DIR/CLAUDE.md"
CLAUDE_MD_CREATED="$LAST_COPY_CREATED"
copy_file "$TOUCHSTONE_ROOT/templates/AGENTS.md" "$PROJECT_DIR/AGENTS.md"
copy_file "$TOUCHSTONE_ROOT/templates/GEMINI.md" "$PROJECT_DIR/GEMINI.md"
# AGENTS.md is project-owned (copy_file skips when present), but the touchstone
# steering block inside it is touchstone-owned. Apply or refresh the block so
# non-Claude reviewers (Codex/Gemini) see the steering content directly — they
# don't resolve the @-imports CLAUDE.md uses to pull in TOUCHSTONE.md.
touchstone_block_apply "$PROJECT_DIR/AGENTS.md" "$TOUCHSTONE_ROOT" || true
copy_file "$TOUCHSTONE_ROOT/templates/pre-commit-config.yaml" "$PROJECT_DIR/.pre-commit-config.yaml"
copy_file "$TOUCHSTONE_ROOT/templates/.markdownlint.json" "$PROJECT_DIR/.markdownlint.json"
copy_file "$TOUCHSTONE_ROOT/templates/gitignore" "$PROJECT_DIR/.gitignore"
copy_file "$TOUCHSTONE_ROOT/templates/.worktreeinclude.example" "$PROJECT_DIR/.worktreeinclude.example"
copy_file "$TOUCHSTONE_ROOT/templates/pull_request_template.md" "$PROJECT_DIR/.github/pull_request_template.md"
if [ -f "$PROJECT_DIR/.codex-review.toml" ] && [ ! -f "$PROJECT_DIR/.touchstone-review.toml" ]; then
  echo "    exists (legacy, skipped): .codex-review.toml"
else
  copy_file "$TOUCHSTONE_ROOT/templates/touchstone-review.toml" "$PROJECT_DIR/.touchstone-review.toml"
fi
copy_file "$TOUCHSTONE_ROOT/templates/setup.sh" "$PROJECT_DIR/setup.sh"
chmod +x "$PROJECT_DIR/setup.sh" 2>/dev/null || true

echo ""
echo "==> Copying principles (touchstone-owned, will be auto-updated):"
mkdir -p "$PROJECT_DIR/principles"
for f in "$TOUCHSTONE_ROOT/principles/"*.md; do
  copy_file_force "$f" "$PROJECT_DIR/principles/$(basename "$f")"
done

# TOUCHSTONE.md is the canonical lean-router steering doc imported by
# CLAUDE.md (@TOUCHSTONE.md) and inlined into AGENTS.md/GEMINI.md by
# touchstone_block_apply. Copy at the project root so the @-import resolves.
copy_file_force "$TOUCHSTONE_ROOT/TOUCHSTONE.md" "$PROJECT_DIR/TOUCHSTONE.md"

echo ""
echo "==> Copying GitHub workflows (touchstone-owned, will be auto-updated):"
copy_file_force "$TOUCHSTONE_ROOT/templates/ci/issue-claim-check.yml" "$PROJECT_DIR/.github/workflows/issue-claim-check.yml"

echo ""
echo "==> Copying scripts (touchstone-owned, will be auto-updated):"
mkdir -p "$PROJECT_DIR/scripts"
copy_file_force "$TOUCHSTONE_ROOT/hooks/branch-guard.sh" "$PROJECT_DIR/scripts/branch-guard.sh"
copy_file_force "$TOUCHSTONE_ROOT/hooks/emergency-disclosure.sh" "$PROJECT_DIR/scripts/emergency-disclosure.sh"
copy_file_force "$TOUCHSTONE_ROOT/hooks/cortex-pr-merged-hook.sh" "$PROJECT_DIR/scripts/cortex-pr-merged-hook.sh"
copy_file_force "$TOUCHSTONE_ROOT/scripts/touchstone-run.sh" "$PROJECT_DIR/scripts/touchstone-run.sh"
copy_file_force "$TOUCHSTONE_ROOT/scripts/open-pr.sh" "$PROJECT_DIR/scripts/open-pr.sh"
copy_file_force "$TOUCHSTONE_ROOT/scripts/merge-pr.sh" "$PROJECT_DIR/scripts/merge-pr.sh"
copy_file_force "$TOUCHSTONE_ROOT/scripts/claim-issue.sh" "$PROJECT_DIR/scripts/claim-issue.sh"
copy_file_force "$TOUCHSTONE_ROOT/scripts/respond-review.sh" "$PROJECT_DIR/scripts/respond-review.sh"
copy_file_force "$TOUCHSTONE_ROOT/scripts/issue-claim-check.sh" "$PROJECT_DIR/scripts/issue-claim-check.sh"
copy_file_force "$TOUCHSTONE_ROOT/scripts/cleanup-branches.sh" "$PROJECT_DIR/scripts/cleanup-branches.sh"
copy_file_force "$TOUCHSTONE_ROOT/scripts/spawn-worktree.sh" "$PROJECT_DIR/scripts/spawn-worktree.sh"
copy_file_force "$TOUCHSTONE_ROOT/scripts/cleanup-worktrees.sh" "$PROJECT_DIR/scripts/cleanup-worktrees.sh"
chmod +x "$PROJECT_DIR/scripts/"*.sh

echo ""
echo "==> Copying libraries (touchstone-owned, will be auto-updated):"
mkdir -p "$PROJECT_DIR/lib"
copy_file_force "$TOUCHSTONE_ROOT/lib/toml.sh" "$PROJECT_DIR/lib/toml.sh"
copy_file_force "$TOUCHSTONE_ROOT/lib/events.sh" "$PROJECT_DIR/lib/events.sh"
copy_file_force "$TOUCHSTONE_ROOT/lib/codex-auth.sh" "$PROJECT_DIR/lib/codex-auth.sh"
copy_file_force "$TOUCHSTONE_ROOT/lib/script-sync-guard.sh" "$PROJECT_DIR/lib/script-sync-guard.sh"
copy_file_force "$TOUCHSTONE_ROOT/lib/sha256.sh" "$PROJECT_DIR/lib/sha256.sh"
copy_file_force "$TOUCHSTONE_ROOT/lib/preflight.sh" "$PROJECT_DIR/lib/preflight.sh"
copy_file_force "$TOUCHSTONE_ROOT/lib/preflight-scope.sh" "$PROJECT_DIR/lib/preflight-scope.sh"

# Claude Code settings — wires the branch-guard and emergency-disclosure
# PreToolUse hooks shipped above. Touchstone-owned (overwritten on update);
# project-specific overrides go in .claude/settings.local.json.
echo ""
echo "==> Copying Claude Code settings (touchstone-owned, will be auto-updated):"
mkdir -p "$PROJECT_DIR/.claude"
copy_file_force "$TOUCHSTONE_ROOT/templates/claude-settings.json" "$PROJECT_DIR/.claude/settings.json"

# Touchstone-shipped skills — installed to USER scope (~/.claude/skills/) so
# the bundled engineering, git, Cortex, and workflow skills are available in every
# project the user opens, not duplicated into each project. Project-scoped
# skills (anything under <project>/.claude/skills/ that the user adds) remain
# project-owned and untouched.
if [ -d "$TOUCHSTONE_ROOT/skills" ]; then
  echo ""
  echo "==> Installing Touchstone-bundled skills to ~/.claude/skills (user scope):"
  touchstone_install_skills "$TOUCHSTONE_ROOT" || true
fi

# Optional CI workflow — opt-in via --ci. Not copied by default because not every
# project uses GitHub Actions, and shipping a workflow file silently into every
# bootstrap would force that opinion on GitLab/Bitbucket/self-hosted users.
# shellcheck disable=SC2034  # reserved for downstream summary printout.
CI_WORKFLOW_CREATED=false
if [ "$INPUT_CI" = "github" ]; then
  echo ""
  echo "==> Adding CI workflow (project-owned, won't be auto-updated):"
  copy_file "$TOUCHSTONE_ROOT/templates/ci/github-validate.yml" "$PROJECT_DIR/.github/workflows/validate.yml"
  if [ "$LAST_COPY_CREATED" = true ]; then
    # shellcheck disable=SC2034  # reserved for downstream summary printout.
    CI_WORKFLOW_CREATED=true
  fi
fi

# Write touchstone version.
# Use git SHA if this is a git clone, otherwise use VERSION (brew install).
if [ -d "$TOUCHSTONE_ROOT/.git" ]; then
  TOUCHSTONE_SHA="$(git -C "$TOUCHSTONE_ROOT" rev-parse HEAD)"
else
  TOUCHSTONE_SHA="$(cat "$TOUCHSTONE_ROOT/VERSION" 2>/dev/null | tr -d '[:space:]' || echo "unknown")"
fi
touchstone_ensure_safe_dest "$PROJECT_DIR/.touchstone-version" "$PROJECT_DIR" false || true
echo "$TOUCHSTONE_SHA" >"$PROJECT_DIR/.touchstone-version"
echo ""
echo "==> Wrote .touchstone-version: $TOUCHSTONE_SHA"

# Register in ~/.touchstone-projects for update-all.
# The write is a silent side effect by default (opt-in stays default for
# script-compat), so surface every registry outcome with an "==> " line:
# the path we wrote to, the fact that we were already registered, or the
# fact that registration was skipped. Always name the opt-out flag so the
# next run doesn't need to grep for it.
PROJECTS_FILE="$HOME/.touchstone-projects"
if [ "$REGISTER" = true ]; then
  # Ensure file exists.
  touch "$PROJECTS_FILE"
  # Add if not already registered.
  if ! grep -qxF "$PROJECT_DIR" "$PROJECTS_FILE" 2>/dev/null; then
    echo "$PROJECT_DIR" >>"$PROJECTS_FILE"
    echo "==> Registered in $PROJECTS_FILE — opt out next time with --no-register"
  else
    echo "==> Already registered in $PROJECTS_FILE — opt out next time with --no-register"
  fi
else
  echo "==> Registry skipped (--no-register)"
fi

# --------------------------------------------------------------------------
# Interactive placeholder filling (if stdin is a terminal)
# --------------------------------------------------------------------------
INPUT_NAME=""
INPUT_DESC=""
INPUT_TEST=""

# Interactive wizard (Doctrine 0002). Runs when stdin is a TTY OR --yes was
# passed. Flags always take precedence — prompts skip any choice already made
# via flag. Non-TTY without --yes falls back to existing flag-driven defaults.
WIZARD_INTERACTIVE=false
if [ "$RE_INIT" = false ] && [ "$CLAUDE_MD_CREATED" = true ] && { [ -t 0 ] || [ "$YES_MODE" = true ]; }; then
  WIZARD_INTERACTIVE=true
fi

if [ "$WIZARD_INTERACTIVE" = true ]; then
  echo ""
  if [ "$YES_MODE" = true ]; then
    echo "==> --yes: accepting defaults for all unspecified choices."
  else
    echo "==> Fill in project details (press Enter to skip any):"
  fi
  echo ""

  if [ "$YES_MODE" = true ]; then
    INPUT_NAME="$(basename "$PROJECT_DIR")"
  else
    read -r -p "   Project name [$(basename "$PROJECT_DIR")]: " INPUT_NAME
    INPUT_NAME="${INPUT_NAME:-$(basename "$PROJECT_DIR")}"

    read -r -p "   One-line description: " INPUT_DESC

    read -r -p "   Test command (e.g., pnpm build, pytest tests/): " INPUT_TEST
  fi

  if [ -z "$INPUT_TYPE" ]; then
    DETECTED_TYPE="$(detect_project_type "$PROJECT_DIR")"
    if [ "$YES_MODE" = true ]; then
      INPUT_TYPE="$DETECTED_TYPE"
    else
      read -r -p "   Project type (node, python, swift, rust, go, generic, auto) [$DETECTED_TYPE]: " INPUT_TYPE
      INPUT_TYPE="${INPUT_TYPE:-$DETECTED_TYPE}"
    fi
    INPUT_TYPE="$(normalize_project_type "$INPUT_TYPE")"
  fi
  if [ "$WORKFLOW_CONFIG_REQUESTED" = false ]; then
    echo ""
    echo "==> Choose Git workflow helpers (press Enter for the default):"
    echo "   Plain Git: simplest, lowest surprise; use Touchstone's branch/PR scripts."
    echo "   GitButler: optional power workflow for stacked or parallel branches, undo history, and AI-agent branch management."
    if [ "$(prompt_yes_no "Use GitButler for this project?" "false")" = "true" ]; then
      INPUT_GIT_WORKFLOW="gitbutler"
      INPUT_GITBUTLER_MCP="$(prompt_yes_no "Expose GitButler to AI agents through MCP when the CLI is installed?" "false")"
    else
      INPUT_GIT_WORKFLOW="git"
      INPUT_GITBUTLER_MCP=false
    fi
    WORKFLOW_CONFIG_REQUESTED=true
  fi

  # Doctrine 0002 — additional wizard prompts. Each prompt is gated on its
  # corresponding _REQUESTED flag: if the user passed the flag-form on the
  # command line, skip the prompt (flag precedence).

  # 1. Language scaffold (swift only, for now).
  if [ "$INPUT_TYPE" = "swift" ] && [ "$SKIP_LANGUAGE_SCAFFOLD_REQUESTED" = false ]; then
    echo ""
    if [ "$(prompt_yes_no "Scaffold Package.swift + Sources/ + Tests/?" "true")" = "true" ]; then
      SKIP_LANGUAGE_SCAFFOLD=false
    else
      SKIP_LANGUAGE_SCAFFOLD=true
    fi
  fi

  # 3. Initialize Cortex.
  if [ "$WITH_CORTEX_REQUESTED" = false ]; then
    echo ""
    if [ "$(prompt_yes_no "Initialize Cortex (file-based project memory)?" "true")" = "true" ]; then
      WITH_CORTEX=true
    else
      WITH_CORTEX=false
    fi
  fi

  # 4. Initialize Sentinel.
  if [ "$WITH_SENTINEL_REQUESTED" = false ]; then
    echo ""
    if [ "$(prompt_yes_no "Initialize Sentinel (autonomous agent loop)?" "true")" = "true" ]; then
      WITH_SENTINEL=true
    else
      WITH_SENTINEL=false
    fi
  fi

  # 5. Register in ~/.touchstone-projects.
  if [ "$REGISTER_REQUESTED" = false ]; then
    echo ""
    if [ "$(prompt_yes_no "Register for touchstone update-all (~/.touchstone-projects)?" "true")" = "true" ]; then
      REGISTER=true
    else
      REGISTER=false
    fi
  fi

  # 6. Initial commit.
  if [ "$INITIAL_COMMIT_REQUESTED" = false ]; then
    echo ""
    if [ "$(prompt_yes_no "Create initial commit?" "true")" = "true" ]; then
      INITIAL_COMMIT=true
    else
      INITIAL_COMMIT=false
    fi
  fi

  # 7. Create GitHub repo. Only offer if gh is available AND authenticated.
  # gh auth status exits non-zero when unauthenticated or when gh isn't installed.
  if [ "$GITHUB_MODE_REQUESTED" = false ]; then
    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
      echo ""
      if [ "$(prompt_yes_no "Create a private GitHub repo with gh?" "false")" = "true" ]; then
        GITHUB_MODE="private"
      else
        GITHUB_MODE="none"
      fi
    else
      GITHUB_MODE="none"
    fi
  fi
fi
# Non-interactive fallback defaults — Doctrine 0002: non-TTY without --yes and
# without a flag means "no behavior change from pre-R2 wizard". Cortex/Sentinel
# init, GitHub repo creation, and initial commit stay off unless asked for;
# registry default remains opt-in (REGISTER=true) to preserve prior behavior.
if [ -z "$WITH_CORTEX" ]; then
  WITH_CORTEX=false
fi
if [ -z "$WITH_SENTINEL" ]; then
  WITH_SENTINEL=false
fi
if [ -z "$GITHUB_MODE" ]; then
  GITHUB_MODE="none"
fi

# Non-TTY fresh scaffolds (agents, CI, `touchstone init` piped from a script)
# never enter the interactive prompt block, so INPUT_NAME stays empty and the
# substitution below no-ops — leaving {{PROJECT_NAME}} visible in CLAUDE.md and
# AGENTS.md. Default to the project basename so the substitution always runs
# and agents don't inherit a template with unresolved placeholders.
if [ "$RE_INIT" = false ] && [ -z "$INPUT_NAME" ]; then
  INPUT_NAME="$(basename "$PROJECT_DIR")"
fi

# Default project type if not set. Mirror the runner's resolution so a flag
# like --scaffold-tests dispatches against the same profile that validate
# and doctor see — otherwise a config like "project_type=generic\nprofile=python"
# or "project_type=generic" plus an added pyproject.toml would silently
# demote the flag to generic while the rest of the stack runs Python.
if [ -z "$INPUT_TYPE" ] && [ -f "$PROJECT_DIR/.touchstone-config" ]; then
  INPUT_TYPE="$(resolve_project_type_from_config "$PROJECT_DIR")"
fi
INPUT_TYPE="${INPUT_TYPE:-auto}"
INPUT_TYPE="$(normalize_project_type "$INPUT_TYPE")"
if [ "$INPUT_TYPE" = "auto" ]; then
  INPUT_TYPE="$(detect_project_type "$PROJECT_DIR")"
fi
INPUT_GIT_WORKFLOW="${INPUT_GIT_WORKFLOW:-git}"
INPUT_GIT_WORKFLOW="$(normalize_git_workflow "$INPUT_GIT_WORKFLOW")"
INPUT_GITBUTLER_MCP="${INPUT_GITBUTLER_MCP:-false}"
INPUT_GITBUTLER_MCP="$(normalize_yes_no "$INPUT_GITBUTLER_MCP")"

PACKAGE_MANAGER="$(detect_node_package_manager "$PROJECT_DIR")"
MONOREPO="$(detect_monorepo "$PROJECT_DIR")"
TARGETS="$(detect_targets "$PROJECT_DIR")"

if [ -n "$INPUT_NAME" ] || [ -n "$INPUT_DESC" ] || [ -n "$INPUT_TEST" ]; then
  # Apply to project-owned AI instruction files.
  if [ -n "$INPUT_NAME" ]; then
    ESCAPED_NAME="$(escape_sed_replacement "$INPUT_NAME")"
    for placeholder_file in CLAUDE.md AGENTS.md GEMINI.md; do
      if [ -f "$PROJECT_DIR/$placeholder_file" ]; then
        touchstone_sed_inplace "s/{{PROJECT_NAME}}/$ESCAPED_NAME/g" "$PROJECT_DIR/$placeholder_file"
      fi
    done
  fi

  if [ -n "$INPUT_DESC" ]; then
    ESCAPED_DESC="$(escape_sed_replacement "$INPUT_DESC")"
    if [ -f "$PROJECT_DIR/CLAUDE.md" ]; then
      touchstone_sed_inplace "s/{{PROJECT_DESCRIPTION[^}]*}}/$ESCAPED_DESC/g" "$PROJECT_DIR/CLAUDE.md"
    fi
  fi

  if [ -n "$INPUT_TEST" ]; then
    ESCAPED_TEST="$(escape_sed_replacement "$INPUT_TEST")"
    if [ -f "$PROJECT_DIR/CLAUDE.md" ]; then
      touchstone_sed_inplace "s/{{TEST_COMMAND[^}]*}}/$ESCAPED_TEST/g" "$PROJECT_DIR/CLAUDE.md"
    fi
  fi

  if [ -t 0 ]; then
    echo ""
    echo "==> Placeholders filled! Review CLAUDE.md, AGENTS.md, and GEMINI.md to add more detail."
  fi
fi

# Write .touchstone-config with project type (skip if already exists).
if [ ! -f "$PROJECT_DIR/.touchstone-config" ]; then
  touchstone_ensure_safe_dest "$PROJECT_DIR/.touchstone-config" "$PROJECT_DIR" false || true
  {
    printf '# touchstone project profile. Commit this file so all clones use the same commands.\n'
    printf 'project_type=%s\n' "$INPUT_TYPE"
    if [ -n "$PACKAGE_MANAGER" ]; then
      printf 'package_manager=%s\n' "$PACKAGE_MANAGER"
    else
      printf 'package_manager=auto\n'
    fi
    printf 'monorepo=%s\n' "$MONOREPO"
    printf 'targets=%s\n' "$TARGETS"
    printf 'git_workflow=%s\n' "$INPUT_GIT_WORKFLOW"
    printf 'gitbutler_mcp=%s\n' "$INPUT_GITBUTLER_MCP"
    printf '# Set sync_auto=false to opt out of automatic touchstone updates.\n'
    printf 'sync_auto=true\n'
    printf '# Set sync_ship=false to create local update branches without auto-shipping PRs.\n'
    printf 'sync_ship=true\n'
    printf 'lint_command=\n'
    printf 'typecheck_command=\n'
    printf 'build_command=\n'
    printf 'test_command=%s\n' "$INPUT_TEST"
    printf 'validate_command=\n'
    printf '# validate_lane=auto chooses affected/smoke only when safely configured; otherwise full.\n'
    printf 'validate_lane=auto\n'
    printf 'validate_affected_command=\n'
    printf 'validate_smoke_command=\n'
    printf 'validate_full_command=\n'
  } >"$PROJECT_DIR/.touchstone-config"
  echo "==> Wrote .touchstone-config: project_type=$INPUT_TYPE"
else
  echo "==> .touchstone-config already exists; left unchanged."
fi

# Keep the legacy pytest helper only for Python projects. Generic ecosystem
# tasks should go through scripts/touchstone-run.sh.
if [ "$INPUT_TYPE" = "python" ]; then
  echo ""
  echo "==> Copying Python helper:"
  copy_file_force "$TOUCHSTONE_ROOT/scripts/run-pytest-in-venv.sh" "$PROJECT_DIR/scripts/run-pytest-in-venv.sh"
  chmod +x "$PROJECT_DIR/scripts/run-pytest-in-venv.sh" 2>/dev/null || true
fi

# Swift profile on fresh bootstrap: scaffold Package.swift + Sources/ + Tests/
# so `swift build` and `swift test` work immediately. Never overwrites — the
# _has_any_swift_sources guard makes re-init on a real Swift project a no-op.
# Skippable via --skip-language-scaffold or a "no" answer to the wizard prompt,
# for users who intend to author Package.swift themselves.
if [ "$RE_INIT" = false ] && [ "$INPUT_TYPE" = "swift" ] && [ "$SKIP_LANGUAGE_SCAFFOLD" = false ]; then
  scaffold_swift_package_boilerplate "$PROJECT_DIR"
elif [ "$RE_INIT" = false ] && [ "$INPUT_TYPE" = "swift" ] && [ "$SKIP_LANGUAGE_SCAFFOLD" = true ]; then
  echo "==> swift: language scaffold skipped (--skip-language-scaffold)"
fi

# Append per-profile entries to .gitignore on fresh bootstrap only.
# Idempotent (only appends entries not already present); other profiles no-op.
if [ "$RE_INIT" = false ]; then
  append_profile_gitignore_entries "$PROJECT_DIR" "$INPUT_TYPE"
fi

# Per-profile project-owned templates (e.g. swift's .swiftlint.yml). copy_file
# is the project-owned semantic — adds when missing, leaves any hand-edited
# version untouched on re-init. Runs on both fresh and re-init so projects
# bootstrapped before the swiftlint template existed pick it up the next time
# they run `touchstone init`.
copy_profile_templates() {
  local project_dir="$1" profile="$2"
  case "$profile" in
    swift)
      if [ -f "$TOUCHSTONE_ROOT/templates/swift/.swiftlint.yml" ]; then
        copy_file "$TOUCHSTONE_ROOT/templates/swift/.swiftlint.yml" "$project_dir/.swiftlint.yml"
      fi
      ;;
    *)
      return 0
      ;;
  esac
}
copy_profile_templates "$PROJECT_DIR" "$INPUT_TYPE"

# Optional --scaffold-tests: write one smoke test per profile when no tests
# exist, so a fresh repo has something for touchstone-run.sh test to find.
# Off by default — project owners decide their test framework; we just prime
# the runner with a minimal passing test that won't fight their choice.
if [ "$INPUT_SCAFFOLD_TESTS" = true ]; then
  scaffold_smoke_test_for_profile "$PROJECT_DIR" "$INPUT_TYPE"
fi

write_touchstone_manifest

# Doctrine 0002 — Cortex / Sentinel init run BEFORE the initial commit so
# their scaffolded artifacts (.cortex/, .sentinel/, any .gitignore edits)
# land in the same atom as the rest of the touchstone scaffold. Running
# these after the commit used to leave the working tree half-committed
# once hooks armed `no-commit-to-branch`. (R5.1 — see autumn-garage
# journal/2026-04-18-r5-findings-from-fresh-scaffold.) GitHub repo
# creation stays after hook install because `gh repo create --push`
# needs the pre-push gate to exist.
#
# Capture pre-integration HEAD state so the post-integration commit logic
# can safely distinguish an integration-authored commit (created just now,
# safe to collapse) from a pre-existing user commit (touchstone must never
# rewrite). Empty string = no HEAD existed before integrations ran.
PRE_INTEGRATION_HEAD="$(git -C "$PROJECT_DIR" rev-parse --verify HEAD 2>/dev/null || true)"

if [ "$WITH_CORTEX" = true ] && [ "$RE_INIT" = false ]; then
  if command -v cortex >/dev/null 2>&1; then
    echo ""
    echo "==> Initializing Cortex ..."
    cortex_args=()
    if [ "$YES_MODE" = true ]; then cortex_args+=("--yes"); fi
    if (cd "$PROJECT_DIR" && cortex init ${cortex_args[@]+"${cortex_args[@]}"}); then
      :
    else
      echo "==> Cortex init failed (continuing)." >&2
    fi
  else
    echo ""
    echo "==> Cortex not on PATH — skipping cortex init."
    echo "    Install: brew install autumngarage/cortex/cortex"
  fi
fi

if [ "$WITH_SENTINEL" = true ] && [ "$RE_INIT" = false ]; then
  if command -v sentinel >/dev/null 2>&1; then
    echo ""
    echo "==> Initializing Sentinel ..."
    sentinel_args=()
    if [ "$YES_MODE" = true ]; then sentinel_args+=("--yes"); fi
    if (cd "$PROJECT_DIR" && sentinel init ${sentinel_args[@]+"${sentinel_args[@]}"}); then
      :
    else
      echo "==> Sentinel init failed (continuing)." >&2
    fi
  else
    echo ""
    echo "==> Sentinel not on PATH — skipping sentinel init."
    echo "    Install: brew install autumngarage/sentinel/sentinel"
  fi
fi

# Initial commit on fresh scaffold — runs AFTER the integration inits
# (above) so .cortex/, .sentinel/, and any gitignore updates those tools
# made are captured in one commit, and BEFORE `pre-commit install` below
# so the "no-commit-to-branch" / default-branch guards in the freshly-
# installed hooks don't block the user's first commit. Resolves the
# bootstrap paradox: to commit you need the hooks un-armed; once hooks
# are armed, you need a commit on the branch to push anything.
#
# Atomicity note: `sentinel init` may have already committed its own
# .gitignore edit inside `_ensure_gitignore_entries` (it calls
# `git commit -- .gitignore` when it detects a git repo). To keep the
# scaffold a single atomic commit as promised, we detect any such
# pre-existing HEAD and soft-reset it back into the index BEFORE
# staging the rest of the tree. The final `git commit` then captures
# everything — integration artifacts plus scaffold — as one commit
# with a single author/message, so `rev-list --count HEAD` equals 1.
INITIAL_COMMIT_SHA=""
# Preserve the pre-R5 invariant exactly: the initial-commit path only
# runs when NO HEAD existed before this scaffold. Bootstrapping into a
# repo that already had user-authored commits must never rewrite history
# or sweep unrelated staged changes into a "chore: initial touchstone
# scaffold". Integrations may have just created HEAD mid-run — that's
# still a fresh-scaffold case, which the PRE_INTEGRATION_HEAD guard
# distinguishes from genuine pre-existing history.
if [ "$RE_INIT" = false ] && [ "$INITIAL_COMMIT" = true ] \
  && [ -z "$PRE_INTEGRATION_HEAD" ]; then
  # Fall back to a local git identity when none is configured globally, so the
  # commit succeeds on CI boxes and fresh dev machines. Global config, when
  # present, wins because we only set the local keys if they resolve to empty.
  if [ -z "$(git -C "$PROJECT_DIR" config --get user.email 2>/dev/null || true)" ]; then
    git -C "$PROJECT_DIR" config user.email "touchstone@localhost"
  fi
  if [ -z "$(git -C "$PROJECT_DIR" config --get user.name 2>/dev/null || true)" ]; then
    git -C "$PROJECT_DIR" config user.name "Touchstone Bootstrap"
  fi

  # If an integration (e.g. sentinel init) created a commit DURING this
  # run, fold its changes back into the index so the touchstone initial
  # commit is the sole commit on the branch. Even inside this block
  # (PRE_INTEGRATION_HEAD empty), we re-verify that HEAD is a root commit
  # to be sure we're not about to delete a reference we didn't create.
  if git -C "$PROJECT_DIR" rev-parse --verify HEAD >/dev/null 2>&1; then
    commits_on_branch="$(git -C "$PROJECT_DIR" rev-list --count HEAD 2>/dev/null || echo 0)"
    if [ "$commits_on_branch" = "1" ]; then
      # Delete HEAD — `git reset` below then matches the index to the
      # now-empty tree at HEAD while preserving the working tree. The
      # subsequent `git add -A` + `git commit` lands every scaffold file
      # (integration-authored + base templates) as the sole commit.
      git -C "$PROJECT_DIR" update-ref -d HEAD >/dev/null 2>&1 || true
      git -C "$PROJECT_DIR" reset >/dev/null 2>&1 || true
    fi
  fi

  # Stage everything the integrations produced plus the base scaffold.
  # `git add -A` is safe here because PRE_INTEGRATION_HEAD was empty —
  # we know the entire working tree was authored by this scaffold run.
  git -C "$PROJECT_DIR" add -A
  if ! git -C "$PROJECT_DIR" diff --cached --quiet 2>/dev/null; then
    if git -C "$PROJECT_DIR" commit -m "chore: initial touchstone scaffold

Touchstone-Version: $TOUCHSTONE_SHA" >/dev/null 2>&1; then
      INITIAL_COMMIT_SHA="$(git -C "$PROJECT_DIR" rev-parse --short HEAD 2>/dev/null || true)"
    else
      echo "==> Initial commit skipped (git commit failed; check git identity)"
    fi
  fi
fi

# Install git hooks so the repo is actually gated, not just configured.
# pre-commit install is idempotent — safe even if setup.sh re-runs it later.
echo ""
HOOK_INSTALL_STATUS=0
touchstone_install_hooks "$PROJECT_DIR" || HOOK_INSTALL_STATUS=$?
HOOK_PUSH_GATE_READY=false
if touchstone_project_hooks_ready "$PROJECT_DIR"; then
  HOOK_PUSH_GATE_READY=true
fi

# --------------------------------------------------------------------------
# Summary block — every init exits with a checkable state, not silent success.
# --------------------------------------------------------------------------
echo ""
if [ "$RE_INIT" = true ]; then
  echo "==> touchstone reconciled:"
else
  echo "==> touchstone bootstrapped:"
fi
printf '    files:    %d added, %d unchanged' "$FILES_ADDED" "$FILES_UNCHANGED"
if [ "$FILES_UPDATED" -gt 0 ]; then
  printf ', %d updated (previous content backed up as .bak)' "$FILES_UPDATED"
fi
if [ "$FILES_EXISTING" -gt 0 ]; then
  printf ', %d already present' "$FILES_EXISTING"
fi
printf '\n'
printf '    version:  %s\n' "$TOUCHSTONE_SHA"

case "$HOOK_INSTALL_STATUS" in
  0) printf '    hooks:    installed (pre-commit, pre-push)\n' ;;
  1) printf '    hooks:    SKIPPED — no .pre-commit-config.yaml (unexpected)\n' ;;
  2) printf '    hooks:    NOT INSTALLED — pre-commit CLI missing\n' ;;
  3) printf '    hooks:    PARTIAL — one or more installs failed (see above)\n' ;;
  4) printf '    hooks:    NOT CHANGED — core.hooksPath is project-owned (see above)\n' ;;
esac

if [ -n "$INITIAL_COMMIT_SHA" ]; then
  printf '    commit:   %s (initial touchstone scaffold)\n' "$INITIAL_COMMIT_SHA"
fi

if [ "$REGISTER" = true ]; then
  printf '    registry: %s\n' "$PROJECTS_FILE"
else
  printf '    registry: skipped (--no-register)\n'
fi

# Doctrine 0002 — GitHub repo creation runs after hook install so the
# `gh repo create --push` goes through the pre-push gate. Cortex and
# Sentinel init already ran above (before the initial commit) so their
# artifacts are captured in the scaffold commit.

if { [ "$GITHUB_MODE" = "private" ] || [ "$GITHUB_MODE" = "public" ]; } && [ "$RE_INIT" = false ]; then
  if [ "$HOOK_PUSH_GATE_READY" != true ]; then
    echo ""
    echo "==> GitHub repo creation skipped: effective pre-commit and pre-push hooks are not ready." >&2
    echo "    Repair the configured hook path, verify with touchstone doctor --project, then create the remote." >&2
  elif command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    echo ""
    echo "==> Creating GitHub repo ($GITHUB_MODE) ..."
    gh_visibility_flag="--${GITHUB_MODE}"
    if (cd "$PROJECT_DIR" && gh repo create "$(basename "$PROJECT_DIR")" "$gh_visibility_flag" --source . --push); then
      :
    else
      echo "==> gh repo create failed (continuing)." >&2
    fi
  else
    echo ""
    echo "==> gh not available or not authenticated — skipping GitHub repo creation."
  fi
fi

# Doctrine 0002 — print the equivalent flag-form so scripters learn by doing.
# Includes every wizard-settable choice so copy-paste reproduces the scaffold.
if [ "$WIZARD_INTERACTIVE" = true ] || [ "$YES_MODE" = true ]; then
  register_flag="--register"
  [ "$REGISTER" = false ] && register_flag="--no-register"
  cortex_flag="--no-with-cortex"
  [ "$WITH_CORTEX" = true ] && cortex_flag="--with-cortex"
  sentinel_flag="--no-with-sentinel"
  [ "$WITH_SENTINEL" = true ] && sentinel_flag="--with-sentinel"
  commit_flag="--initial-commit"
  [ "$INITIAL_COMMIT" = false ] && commit_flag="--no-initial-commit"
  case "$GITHUB_MODE" in
    private) github_flag="--github-private" ;;
    public) github_flag="--github-public" ;;
    *) github_flag="--no-github" ;;
  esac
  scaffold_flag=""
  [ "$SKIP_LANGUAGE_SCAFFOLD" = true ] && scaffold_flag=" --skip-language-scaffold"
  echo ""
  echo "==> Equivalent to rerun:"
  printf "    touchstone new %s --type %s%s \\\\\n" \
    "$PROJECT_DIR" "$INPUT_TYPE" "$scaffold_flag"
  printf "      %s %s %s %s %s\n" \
    "$register_flag" "$cortex_flag" "$sentinel_flag" "$commit_flag" "$github_flag"
fi

echo ""
echo "Next steps:"
STEP_NUM=1
if [ "$HOOK_INSTALL_STATUS" -eq 2 ]; then
  printf '  %d. Install pre-commit to gate commits & pushes:\n' "$STEP_NUM"
  printf '       brew install pre-commit   # or: pip install pre-commit\n'
  printf '       Then rerun: touchstone init\n'
  STEP_NUM=$((STEP_NUM + 1))
fi
if [ "$RE_INIT" = false ]; then
  printf '  %d. Fill in CLAUDE.md, AGENTS.md, and GEMINI.md (architecture, key files, hard-won lessons)\n' "$STEP_NUM"
  printf '     CLAUDE.md steers Claude Code; AGENTS.md steers Codex and the review rubric; GEMINI.md steers Gemini CLI.\n'
  STEP_NUM=$((STEP_NUM + 1))
fi
printf '  %d. Install dev tools and project deps: cd %s && bash setup.sh\n' "$STEP_NUM" "$PROJECT_DIR"
STEP_NUM=$((STEP_NUM + 1))
printf '  %d. Verify the install: touchstone doctor --project\n' "$STEP_NUM"
echo ""

# Doctrine 0002 — mark success so the EXIT trap doesn't clean up.
WIZARD_COMPLETE=true
