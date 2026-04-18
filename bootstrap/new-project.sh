#!/usr/bin/env bash
#
# bootstrap/new-project.sh — spin up a new project with touchstone files.
#
# Usage:
#   new-project.sh <project-dir>
#   new-project.sh <project-dir> --no-register   # skip adding to ~/.touchstone-projects
#   new-project.sh <project-dir> --type node|python|swift|rust|go|generic|auto
#   new-project.sh <project-dir> --unsafe-paths src/auth/,migrations/
#   new-project.sh <project-dir> --reviewer codex|claude|gemini|local|auto|none
#   new-project.sh <project-dir> --review-routing all-hosted|all-local|small-local
#   new-project.sh <project-dir> --gitbutler
#
# What this does:
#   1. Creates the directory if it doesn't exist, initializes git
#   2. Copies templates, principles, hooks, and scripts into the project
#   3. Makes scripts executable
#   4. Writes .touchstone-version and .touchstone-manifest
#   5. Registers the project in ~/.touchstone-projects (for sync-all.sh)
#   6. Prints next steps
#
# After running, fill in the {{PLACEHOLDERS}} in CLAUDE.md and AGENTS.md.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib/install-hooks.sh
source "$TOUCHSTONE_ROOT/lib/install-hooks.sh"
REGISTER=true
REGISTER_REQUESTED=false       # Doctrine 0002: track whether --register / --no-register was passed.
INPUT_UNSAFE=""
INPUT_TYPE=""
INPUT_TYPE_REQUESTED=false     # Tracks explicit --type (not the auto-detect fall-through).
INPUT_REVIEWER=""
INPUT_REVIEW_ASSIST=""
INPUT_REVIEW_AUTOFIX=""
INPUT_LOCAL_REVIEW_COMMAND=""
INPUT_REVIEW_ROUTING=""
INPUT_SMALL_REVIEW_LINES=""
INPUT_GIT_WORKFLOW=""
INPUT_GITBUTLER_MCP=""
INPUT_CI=""
INPUT_SCAFFOLD_TESTS=false
REVIEW_CONFIG_REQUESTED=false
WORKFLOW_CONFIG_REQUESTED=false

# Doctrine 0002 wizard — new state. Each *_REQUESTED flag records whether the
# user passed the flag-form, so the interactive block can skip prompts the
# user has already answered via flags (flag precedence).
YES_MODE=false
SKIP_LANGUAGE_SCAFFOLD=false
SKIP_LANGUAGE_SCAFFOLD_REQUESTED=false
WITH_CORTEX=""                 # unset | true | false
WITH_CORTEX_REQUESTED=false
WITH_SENTINEL=""
WITH_SENTINEL_REQUESTED=false
INITIAL_COMMIT=true
INITIAL_COMMIT_REQUESTED=false
GITHUB_MODE=""                 # unset | private | public | none
GITHUB_MODE_REQUESTED=false

usage() {
  echo "Usage: $0 <project-dir> [--yes|-y] [--register|--no-register] [--type node|python|swift|rust|go|generic|auto] [--skip-language-scaffold] [--unsafe-paths path1,path2] [--reviewer codex|claude|gemini|local|auto|none] [--review-routing all-hosted|all-local|small-local] [--small-review-lines N] [--review-assist|--no-review-assist] [--review-autofix|--no-review-autofix] [--local-review-command <command>] [--gitbutler|--no-gitbutler] [--gitbutler-mcp|--no-gitbutler-mcp] [--ci github|none] [--scaffold-tests] [--with-cortex|--no-with-cortex] [--with-sentinel|--no-with-sentinel] [--initial-commit|--no-initial-commit] [--github-private|--github-public|--no-github]"
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

escape_toml_basic_string() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

write_unsafe_paths_block() {
  local file="$1"
  shift

  local block_file tmp_file
  block_file="$(mktemp -t touchstone-codex-review-block.XXXXXX)"
  tmp_file="$(mktemp -t touchstone-codex-review.XXXXXX)"

  {
    printf 'unsafe_paths = [\n'
    for path in "$@"; do
      [ -z "$path" ] && continue
      printf '  "%s",\n' "$(escape_toml_basic_string "$path")"
    done
    printf ']\n'
  } > "$block_file"

  if awk -v block_file="$block_file" '
    BEGIN { replaced = 0; in_block = 0 }
    /^[[:space:]]*unsafe_paths[[:space:]]*=/ && !replaced {
      while ((getline line < block_file) > 0) {
        print line
      }
      close(block_file)
      replaced = 1
      in_block = ($0 !~ /\]/)
      next
    }
    in_block {
      if ($0 ~ /^[[:space:]]*\]/) {
        in_block = 0
      }
      next
    }
    { print }
    END {
      if (!replaced) {
        exit 1
      }
    }
  ' "$file" > "$tmp_file"; then
    mv "$tmp_file" "$file"
  else
    rm -f "$block_file" "$tmp_file"
    return 1
  fi

  rm -f "$block_file"
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
    ""|auto) printf 'auto' ;;
    node|js|javascript|ts|typescript) printf 'node' ;;
    python|py) printf 'python' ;;
    swift) printf 'swift' ;;
    rust|rs) printf 'rust' ;;
    go|golang) printf 'go' ;;
    generic) printf 'generic' ;;
    *)
      echo "ERROR: unknown project type '$1' (expected node, python, swift, rust, go, generic, or auto)" >&2
      return 1
      ;;
  esac
}

normalize_reviewer() {
  local value="$1"
  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"

  case "$value" in
    ""|auto) printf 'auto' ;;
    codex|claude|gemini|local) printf '%s' "$value" ;;
    none|no|off|disabled|false) printf 'none' ;;
    *)
      echo "ERROR: unknown reviewer '$1' (expected codex, claude, gemini, local, auto, or none)" >&2
      return 1
      ;;
  esac
}

normalize_review_routing() {
  local value="$1"
  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"

  case "$value" in
    ""|hosted|all|all-hosted|cloud|remote) printf 'all-hosted' ;;
    local|all-local) printf 'all-local' ;;
    hybrid|small-local|local-small|small-local-large-hosted) printf 'small-local' ;;
    none|off|disabled|false) printf 'none' ;;
    *)
      echo "ERROR: unknown review routing '$1' (expected all-hosted, all-local, or small-local)" >&2
      return 1
      ;;
  esac
}

normalize_git_workflow() {
  local value="$1"
  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"

  case "$value" in
    ""|git|plain|standard|classic) printf 'git' ;;
    gitbutler|butler|but) printf 'gitbutler' ;;
    *)
      echo "ERROR: unknown git workflow '$1' (expected git or gitbutler)" >&2
      return 1
      ;;
  esac
}

normalize_positive_int() {
  local value="$1"
  case "$value" in
    ''|*[!0-9]*)
      echo "ERROR: expected a positive integer, got '$1'" >&2
      return 1
      ;;
    *)
      if [ "$value" -le 0 ] 2>/dev/null; then
        echo "ERROR: expected a positive integer, got '$1'" >&2
        return 1
      fi
      printf '%s' "$value"
      ;;
  esac
}

normalize_yes_no() {
  local value="$1"
  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
  case "$value" in
    y|yes|true|1|on) printf 'true' ;;
    n|no|false|0|off) printf 'false' ;;
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

default_reviewer() {
  if command -v codex >/dev/null 2>&1; then
    printf 'codex'
  elif command -v claude >/dev/null 2>&1; then
    printf 'claude'
  elif command -v gemini >/dev/null 2>&1; then
    printf 'gemini'
  else
    printf 'codex'
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
        : > "$project_dir/tests/__init__.py"
      fi
      cat > "$project_dir/tests/test_smoke.py" <<'PYTEST'
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
      cat > "$project_dir/tests/smoke.test.ts" <<'NODETEST'
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
      cat > "$project_dir/smoke_test.go" <<GOTEST
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
    generic|"")
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

  cat > "$project_dir/Package.swift" <<SWIFTPKG
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

  cat > "$project_dir/Sources/$pascal_name/${pascal_name}App.swift" <<SWIFTAPP
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

  cat > "$project_dir/Tests/${pascal_name}Tests/SmokeTests.swift" <<SWIFTTEST
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
      } >> "$gitignore"
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
      case "$line" in \#*|"") continue ;; esac
      case "$line" in *=*) ;; *) continue ;; esac
      candidate="${line%%=*}"
      candidate="${candidate#"${candidate%%[![:space:]]*}"}"
      candidate="${candidate%"${candidate##*[![:space:]]}"}"
      case "$candidate" in
        project_type|profile)
          value="${line#*=}"
          value="${value#"${value%%[![:space:]]*}"}"
          value="${value%"${value##*[![:space:]]}"}"
          result="$value"
          ;;
      esac
    done < "$dir/.touchstone-config"
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
  -h|--help)
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
    -h|--help) usage; exit 0 ;;
    -y|--yes) YES_MODE=true; shift ;;
    --no-register) REGISTER=false; REGISTER_REQUESTED=true; shift ;;
    --register) REGISTER=true; REGISTER_REQUESTED=true; shift ;;
    --with-cortex) WITH_CORTEX=true; WITH_CORTEX_REQUESTED=true; shift ;;
    --no-with-cortex) WITH_CORTEX=false; WITH_CORTEX_REQUESTED=true; shift ;;
    --with-sentinel) WITH_SENTINEL=true; WITH_SENTINEL_REQUESTED=true; shift ;;
    --no-with-sentinel) WITH_SENTINEL=false; WITH_SENTINEL_REQUESTED=true; shift ;;
    --initial-commit) INITIAL_COMMIT=true; INITIAL_COMMIT_REQUESTED=true; shift ;;
    --no-initial-commit) INITIAL_COMMIT=false; INITIAL_COMMIT_REQUESTED=true; shift ;;
    --github-private) GITHUB_MODE=private; GITHUB_MODE_REQUESTED=true; shift ;;
    --github-public) GITHUB_MODE=public; GITHUB_MODE_REQUESTED=true; shift ;;
    --no-github) GITHUB_MODE=none; GITHUB_MODE_REQUESTED=true; shift ;;
    --skip-language-scaffold) SKIP_LANGUAGE_SCAFFOLD=true; SKIP_LANGUAGE_SCAFFOLD_REQUESTED=true; shift ;;
    --type)
      [ "$#" -ge 2 ] || { echo "ERROR: --type requires a value (node, python, swift, rust, go, generic, auto)" >&2; exit 1; }
      INPUT_TYPE="$(normalize_project_type "$2")"
      INPUT_TYPE_REQUESTED=true
      shift 2
      ;;
    --unsafe-paths)
      [ "$#" -ge 2 ] || { echo "ERROR: --unsafe-paths requires a comma-separated value" >&2; exit 1; }
      INPUT_UNSAFE="$2"
      shift 2
      ;;
    --reviewer)
      [ "$#" -ge 2 ] || { echo "ERROR: --reviewer requires a value (codex, claude, gemini, local, auto, none)" >&2; exit 1; }
      INPUT_REVIEWER="$(normalize_reviewer "$2")"
      REVIEW_CONFIG_REQUESTED=true
      shift 2
      ;;
    --review-routing)
      [ "$#" -ge 2 ] || { echo "ERROR: --review-routing requires a value (all-hosted, all-local, small-local)" >&2; exit 1; }
      INPUT_REVIEW_ROUTING="$(normalize_review_routing "$2")"
      REVIEW_CONFIG_REQUESTED=true
      shift 2
      ;;
    --small-review-lines)
      [ "$#" -ge 2 ] || { echo "ERROR: --small-review-lines requires a positive integer" >&2; exit 1; }
      INPUT_SMALL_REVIEW_LINES="$(normalize_positive_int "$2")"
      REVIEW_CONFIG_REQUESTED=true
      shift 2
      ;;
    --no-ai-review|--no-review)
      INPUT_REVIEWER="none"
      INPUT_REVIEW_ROUTING="none"
      REVIEW_CONFIG_REQUESTED=true
      shift
      ;;
    --review-assist)
      INPUT_REVIEW_ASSIST=true
      REVIEW_CONFIG_REQUESTED=true
      shift
      ;;
    --no-review-assist)
      INPUT_REVIEW_ASSIST=false
      REVIEW_CONFIG_REQUESTED=true
      shift
      ;;
    --review-autofix)
      INPUT_REVIEW_AUTOFIX=true
      REVIEW_CONFIG_REQUESTED=true
      shift
      ;;
    --no-review-autofix)
      INPUT_REVIEW_AUTOFIX=false
      REVIEW_CONFIG_REQUESTED=true
      shift
      ;;
    --local-review-command)
      [ "$#" -ge 2 ] || { echo "ERROR: --local-review-command requires a command string" >&2; exit 1; }
      INPUT_LOCAL_REVIEW_COMMAND="$2"
      REVIEW_CONFIG_REQUESTED=true
      shift 2
      ;;
    --git-workflow)
      [ "$#" -ge 2 ] || { echo "ERROR: --git-workflow requires a value (git or gitbutler)" >&2; exit 1; }
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
          github|none) INPUT_CI="$2"; shift 2 ;;
          *) echo "ERROR: --ci value must be one of: github, none" >&2; exit 1 ;;
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
    *) echo "ERROR: unknown argument '$1'" >&2; exit 1 ;;
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
    for f in "$TOUCHSTONE_ROOT/principles/"*.md; do
      printf 'principles/%s\n' "$(basename "$f")"
    done
    printf 'scripts/codex-review.sh\n'
    printf 'scripts/touchstone-run.sh\n'
    printf 'scripts/open-pr.sh\n'
    printf 'scripts/merge-pr.sh\n'
    printf 'scripts/cleanup-branches.sh\n'
    if [ "$INPUT_TYPE" = "python" ]; then
      printf 'scripts/run-pytest-in-venv.sh\n'
    fi
  } > "$manifest_tmp"
  if copy_file_force "$manifest_tmp" "$PROJECT_DIR/.touchstone-manifest"; then
    rm -f "$manifest_tmp"
  else
    rm -f "$manifest_tmp"
    return 1
  fi
}

set_codex_review_key() {
  local file="$1"
  local key="$2"
  local value="$3"
  local tmp_file
  tmp_file="$(mktemp -t touchstone-codex-review-key.XXXXXX)"

  awk -v key="$key" -v repl="$key = $value" '
    BEGIN { in_section = 0; replaced = 0 }
    /^\[codex_review\][[:space:]]*$/ {
      in_section = 1
      print
      next
    }
    /^\[/ {
      if (in_section && !replaced) {
        print repl
        replaced = 1
      }
      in_section = 0
      print
      next
    }
    in_section && !replaced {
      pattern = "^[[:space:]#]*" key "[[:space:]]*="
      if ($0 ~ pattern) {
        print repl
        replaced = 1
        next
      }
    }
    { print }
    END {
      if (in_section && !replaced) {
        print repl
      }
    }
  ' "$file" > "$tmp_file"
  mv "$tmp_file" "$file"
}

reviewers_toml_for() {
  local reviewer="$1"
  case "$reviewer" in
    none) printf '[]' ;;
    auto|"") printf '["codex", "claude", "gemini"]' ;;
    *) printf '["%s"]' "$reviewer" ;;
  esac
}

small_local_reviewers_toml_for() {
  local reviewer="$1"
  case "$reviewer" in
    auto|"") printf '["local", "codex", "claude", "gemini"]' ;;
    local|none) printf '["local", "codex"]' ;;
    *) printf '["local", "%s"]' "$reviewer" ;;
  esac
}

write_review_onboarding_config() {
  local file="$1"
  local reviewer="${INPUT_REVIEWER:-auto}"
  local routing="${INPUT_REVIEW_ROUTING:-}"
  local assist="${INPUT_REVIEW_ASSIST:-false}"
  local autofix="${INPUT_REVIEW_AUTOFIX:-false}"
  local small_review_lines="${INPUT_SMALL_REVIEW_LINES:-400}"
  local enabled=true
  local reviewers_toml
  local large_reviewers_toml
  local small_reviewers_toml

  if [ -z "$routing" ]; then
    case "$reviewer" in
      local) routing="all-local" ;;
      none) routing="none" ;;
      *) routing="all-hosted" ;;
    esac
  fi

  if [ "$routing" = "none" ] || [ "$reviewer" = "none" ]; then
    enabled=false
    routing="none"
    reviewers_toml="$(reviewers_toml_for none)"
  elif [ "$routing" = "all-local" ]; then
    reviewer="local"
    reviewers_toml="$(reviewers_toml_for local)"
  else
    reviewers_toml="$(reviewers_toml_for "$reviewer")"
  fi

  large_reviewers_toml="$(reviewers_toml_for "$reviewer")"
  small_reviewers_toml="$(small_local_reviewers_toml_for "$reviewer")"

  if [ "$enabled" = true ] && [ "$autofix" = true ]; then
    set_codex_review_key "$file" "mode" '"fix"'
    set_codex_review_key "$file" "safe_by_default" "true"
  else
    set_codex_review_key "$file" "mode" '"review-only"'
    set_codex_review_key "$file" "safe_by_default" "false"
  fi

  {
    printf '\n# Touchstone onboarding choices. You can edit these later.\n'
    printf '[review]\n'
    printf 'enabled = %s\n' "$enabled"
    printf 'reviewers = %s\n' "$reviewers_toml"
    if [ "$routing" = "small-local" ]; then
      printf '\n[review.routing]\n'
      printf 'enabled = true\n'
      printf 'small_max_diff_lines = %s\n' "$small_review_lines"
      printf 'small_reviewers = %s\n' "$small_reviewers_toml"
      printf 'large_reviewers = %s\n' "$large_reviewers_toml"
    fi
    printf '\n[review.assist]\n'
    printf 'enabled = %s\n' "$assist"
    printf 'helpers = ["codex", "gemini", "claude", "local"]\n'
    if [ "$reviewer" = "local" ] || [ "$routing" = "small-local" ]; then
      printf '\n[review.local]\n'
      printf '# The command receives the review prompt on stdin and must print CODEX_REVIEW_CLEAN, CODEX_REVIEW_FIXED, or CODEX_REVIEW_BLOCKED as its last line.\n'
      printf 'command = "%s"\n' "$(escape_toml_basic_string "$INPUT_LOCAL_REVIEW_COMMAND")"
    fi
  } >> "$file"
}

print_review_setup_hint() {
  local reviewer="${INPUT_REVIEWER:-auto}"
  local routing="${INPUT_REVIEW_ROUTING:-}"
  local enabled=true

  if [ -z "$routing" ]; then
    case "$reviewer" in
      local) routing="all-local" ;;
      none) routing="none" ;;
      *) routing="all-hosted" ;;
    esac
  fi

  { [ "$reviewer" = "none" ] || [ "$routing" = "none" ]; } && enabled=false
  if [ "$enabled" = false ]; then
    echo "==> AI review disabled. You can enable it later in .codex-review.toml."
    return
  fi

  echo "==> AI review configured: routing=$routing reviewer=$reviewer"
  if [ "$routing" = "small-local" ]; then
    echo "    Small diffs (<= ${INPUT_SMALL_REVIEW_LINES:-400} lines) try your local reviewer first; larger diffs use the hosted reviewer."
  fi
  case "$reviewer" in
    codex|auto)
      if ! command -v codex >/dev/null 2>&1; then
        echo "    Codex is not installed yet. setup.sh will try to install it if npm is available."
        echo "    Manual install: npm install -g @openai/codex && codex login"
      fi
      ;;
    claude)
      if ! command -v claude >/dev/null 2>&1; then
        echo "    Claude CLI is not installed yet. Install and authenticate Claude before relying on review."
      fi
      ;;
    gemini)
      if ! command -v gemini >/dev/null 2>&1; then
        echo "    Gemini CLI is not installed yet. Install and authenticate Gemini before relying on review."
      fi
      ;;
    local)
      if [ -z "$INPUT_LOCAL_REVIEW_COMMAND" ]; then
        echo "    Add [review.local].command in .codex-review.toml before local review can run."
      else
        echo "    Local reviewer command: $INPUT_LOCAL_REVIEW_COMMAND"
      fi
      ;;
  esac

  if [ "$routing" = "small-local" ] && [ -z "$INPUT_LOCAL_REVIEW_COMMAND" ]; then
    echo "    Add [review.local].command in .codex-review.toml before local small-diff review can run."
  fi
}

echo ""
echo "==> Copying templates (project-owned, won't be auto-updated):"
copy_file "$TOUCHSTONE_ROOT/templates/CLAUDE.md" "$PROJECT_DIR/CLAUDE.md"
CLAUDE_MD_CREATED="$LAST_COPY_CREATED"
copy_file "$TOUCHSTONE_ROOT/templates/AGENTS.md" "$PROJECT_DIR/AGENTS.md"
copy_file "$TOUCHSTONE_ROOT/templates/pre-commit-config.yaml" "$PROJECT_DIR/.pre-commit-config.yaml"
copy_file "$TOUCHSTONE_ROOT/templates/gitignore" "$PROJECT_DIR/.gitignore"
copy_file "$TOUCHSTONE_ROOT/templates/pull_request_template.md" "$PROJECT_DIR/.github/pull_request_template.md"
copy_file "$TOUCHSTONE_ROOT/hooks/codex-review.config.example.toml" "$PROJECT_DIR/.codex-review.toml"
CODEX_REVIEW_CONFIG_CREATED="$LAST_COPY_CREATED"
copy_file "$TOUCHSTONE_ROOT/templates/setup.sh" "$PROJECT_DIR/setup.sh"
chmod +x "$PROJECT_DIR/setup.sh" 2>/dev/null || true

echo ""
echo "==> Copying principles (touchstone-owned, will be auto-updated):"
mkdir -p "$PROJECT_DIR/principles"
for f in "$TOUCHSTONE_ROOT/principles/"*.md; do
  copy_file_force "$f" "$PROJECT_DIR/principles/$(basename "$f")"
done

echo ""
echo "==> Copying scripts (touchstone-owned, will be auto-updated):"
mkdir -p "$PROJECT_DIR/scripts"
copy_file_force "$TOUCHSTONE_ROOT/hooks/codex-review.sh" "$PROJECT_DIR/scripts/codex-review.sh"
copy_file_force "$TOUCHSTONE_ROOT/scripts/touchstone-run.sh" "$PROJECT_DIR/scripts/touchstone-run.sh"
copy_file_force "$TOUCHSTONE_ROOT/scripts/open-pr.sh" "$PROJECT_DIR/scripts/open-pr.sh"
copy_file_force "$TOUCHSTONE_ROOT/scripts/merge-pr.sh" "$PROJECT_DIR/scripts/merge-pr.sh"
copy_file_force "$TOUCHSTONE_ROOT/scripts/cleanup-branches.sh" "$PROJECT_DIR/scripts/cleanup-branches.sh"
chmod +x "$PROJECT_DIR/scripts/"*.sh

# Optional CI workflow — opt-in via --ci. Not copied by default because not every
# project uses GitHub Actions, and shipping a workflow file silently into every
# bootstrap would force that opinion on GitLab/Bitbucket/self-hosted users.
CI_WORKFLOW_CREATED=false
if [ "$INPUT_CI" = "github" ]; then
  echo ""
  echo "==> Adding CI workflow (project-owned, won't be auto-updated):"
  copy_file "$TOUCHSTONE_ROOT/templates/ci/github-validate.yml" "$PROJECT_DIR/.github/workflows/validate.yml"
  if [ "$LAST_COPY_CREATED" = true ]; then
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
echo "$TOUCHSTONE_SHA" > "$PROJECT_DIR/.touchstone-version"
echo ""
echo "==> Wrote .touchstone-version: $TOUCHSTONE_SHA"

# Register in ~/.touchstone-projects for sync-all.sh.
PROJECTS_FILE="$HOME/.touchstone-projects"
if [ "$REGISTER" = true ]; then
  # Ensure file exists.
  touch "$PROJECTS_FILE"
  # Add if not already registered.
  if ! grep -qxF "$PROJECT_DIR" "$PROJECTS_FILE" 2>/dev/null; then
    echo "$PROJECT_DIR" >> "$PROJECTS_FILE"
    echo "==> Registered in $PROJECTS_FILE"
  else
    echo "==> Already registered in $PROJECTS_FILE"
  fi
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

  if [ "$REVIEW_CONFIG_REQUESTED" = false ] && [ "$CODEX_REVIEW_CONFIG_CREATED" = true ]; then
    if [ "$YES_MODE" = true ]; then
      # --yes: defaults are "AI review on, hosted routing, auto reviewer".
      INPUT_REVIEW_ROUTING="all-hosted"
      INPUT_REVIEWER="$(default_reviewer)"
      INPUT_REVIEW_AUTOFIX=false
      INPUT_REVIEW_ASSIST=false
      REVIEW_CONFIG_REQUESTED=true
    else
    echo ""
    echo "==> Configure AI review (press Enter for the default):"
    echo "   Hosted review: strongest default reviewer for every change."
    echo "   Local review: private and cheap, but quality depends on your local model."
    echo "   Hybrid review: local handles small diffs; hosted review handles larger diffs."
    if [ "$(prompt_yes_no "Use AI review before code reaches main?" "true")" = "true" ]; then
      local_default_reviewer="$(default_reviewer)"
      local_review_style=""
      read -r -p "   Review style (hosted, local, hybrid) [hosted]: " local_review_style
      local_review_style="$(normalize_review_routing "${local_review_style:-hosted}")"

      case "$local_review_style" in
        all-hosted)
          INPUT_REVIEW_ROUTING="all-hosted"
          read -r -p "   Hosted reviewer (codex, claude, gemini, auto) [$local_default_reviewer]: " INPUT_REVIEWER
          INPUT_REVIEWER="${INPUT_REVIEWER:-$local_default_reviewer}"
          INPUT_REVIEWER="$(normalize_reviewer "$INPUT_REVIEWER")"
          ;;
        all-local)
          INPUT_REVIEW_ROUTING="all-local"
          INPUT_REVIEWER="local"
          read -r -p "   Local reviewer command (reads prompt on stdin, e.g. 'ollama run MODEL'): " INPUT_LOCAL_REVIEW_COMMAND
          ;;
        small-local)
          INPUT_REVIEW_ROUTING="small-local"
          read -r -p "   Local reviewer command for small diffs (e.g. 'ollama run MODEL'): " INPUT_LOCAL_REVIEW_COMMAND
          read -r -p "   Hosted reviewer for larger diffs (codex, claude, gemini, auto) [$local_default_reviewer]: " INPUT_REVIEWER
          INPUT_REVIEWER="${INPUT_REVIEWER:-$local_default_reviewer}"
          INPUT_REVIEWER="$(normalize_reviewer "$INPUT_REVIEWER")"
          read -r -p "   Small-diff cutoff in changed diff lines [400]: " INPUT_SMALL_REVIEW_LINES
          INPUT_SMALL_REVIEW_LINES="${INPUT_SMALL_REVIEW_LINES:-400}"
          INPUT_SMALL_REVIEW_LINES="$(normalize_positive_int "$INPUT_SMALL_REVIEW_LINES")"
          ;;
      esac

      INPUT_REVIEW_AUTOFIX="$(prompt_yes_no "Let the AI auto-fix low-risk issues?" "false")"
      INPUT_REVIEW_ASSIST="$(prompt_yes_no "Let the AI ask one peer reviewer for larger changes?" "false")"

      if [ "$INPUT_REVIEW_AUTOFIX" = "true" ] && [ -z "$INPUT_UNSAFE" ]; then
        read -r -p "   High-scrutiny paths the AI must never auto-fix (comma-separated, e.g., src/auth/,migrations/): " INPUT_UNSAFE
      fi
    else
      INPUT_REVIEWER="none"
      INPUT_REVIEW_ROUTING="none"
      INPUT_REVIEW_AUTOFIX=false
      INPUT_REVIEW_ASSIST=false
    fi
    REVIEW_CONFIG_REQUESTED=true
    fi  # YES_MODE else
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
    if [ "$(prompt_yes_no "Register for touchstone sync (~/.touchstone-projects)?" "true")" = "true" ]; then
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

if [ -n "$INPUT_NAME" ] || [ -n "$INPUT_DESC" ] || [ -n "$INPUT_TEST" ] || [ -n "$INPUT_UNSAFE" ]; then
  # Apply to CLAUDE.md / AGENTS.md.
  if [ -n "$INPUT_NAME" ]; then
    ESCAPED_NAME="$(escape_sed_replacement "$INPUT_NAME")"
    sed -i '' "s/{{PROJECT_NAME}}/$ESCAPED_NAME/g" "$PROJECT_DIR/CLAUDE.md" 2>/dev/null || true
    sed -i '' "s/{{PROJECT_NAME}}/$ESCAPED_NAME/g" "$PROJECT_DIR/AGENTS.md" 2>/dev/null || true
  fi

  if [ -n "$INPUT_DESC" ]; then
    ESCAPED_DESC="$(escape_sed_replacement "$INPUT_DESC")"
    sed -i '' "s/{{PROJECT_DESCRIPTION[^}]*}}/$ESCAPED_DESC/g" "$PROJECT_DIR/CLAUDE.md" 2>/dev/null || true
  fi

  if [ -n "$INPUT_TEST" ]; then
    ESCAPED_TEST="$(escape_sed_replacement "$INPUT_TEST")"
    sed -i '' "s/{{TEST_COMMAND[^}]*}}/$ESCAPED_TEST/g" "$PROJECT_DIR/CLAUDE.md" 2>/dev/null || true
  fi

  if [ -n "$INPUT_UNSAFE" ]; then
    unsafe_paths_input=()
    local_unsafe_paths=()
    IFS=',' read -r -a unsafe_paths_input <<< "$INPUT_UNSAFE"
    for unsafe_path in "${unsafe_paths_input[@]}"; do
      unsafe_path="$(trim "$unsafe_path")"
      [ -z "$unsafe_path" ] && continue
      local_unsafe_paths+=("$unsafe_path")
    done

    if [ "${#local_unsafe_paths[@]}" -gt 0 ] && [ "$CODEX_REVIEW_CONFIG_CREATED" = true ]; then
      write_unsafe_paths_block "$PROJECT_DIR/.codex-review.toml" "${local_unsafe_paths[@]}"
    elif [ "${#local_unsafe_paths[@]}" -gt 0 ]; then
      echo "==> .codex-review.toml already exists; left unsafe_paths unchanged."
    fi
  fi

  if [ -t 0 ]; then
    echo ""
    echo "==> Placeholders filled! Review CLAUDE.md and AGENTS.md to add more detail."
  fi
fi

if [ "$REVIEW_CONFIG_REQUESTED" = true ]; then
  if [ "$CODEX_REVIEW_CONFIG_CREATED" = true ]; then
    write_review_onboarding_config "$PROJECT_DIR/.codex-review.toml"
    print_review_setup_hint
  else
    echo "==> .codex-review.toml already exists; left AI review choices unchanged."
  fi
fi

# Write .touchstone-config with project type (skip if already exists).
if [ ! -f "$PROJECT_DIR/.touchstone-config" ]; then
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
    printf 'lint_command=\n'
    printf 'typecheck_command=\n'
    printf 'build_command=\n'
    printf 'test_command=%s\n' "$INPUT_TEST"
    printf 'validate_command=\n'
  } > "$PROJECT_DIR/.touchstone-config"
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

# Optional --scaffold-tests: write one smoke test per profile when no tests
# exist, so a fresh repo has something for touchstone-run.sh test to find.
# Off by default — project owners decide their test framework; we just prime
# the runner with a minimal passing test that won't fight their choice.
if [ "$INPUT_SCAFFOLD_TESTS" = true ]; then
  scaffold_smoke_test_for_profile "$PROJECT_DIR" "$INPUT_TYPE"
fi

write_touchstone_manifest

# Initial commit on fresh scaffold — before hooks are installed, so the
# "no-commit-to-branch" / default-branch guards in the freshly-installed
# hooks don't block the user's first commit. Resolves the bootstrap paradox:
# to commit you need the hooks un-armed; once hooks are armed, you need a
# commit on the branch to push anything. This ordering solves that.
INITIAL_COMMIT_SHA=""
if [ "$RE_INIT" = false ] && [ "$INITIAL_COMMIT" = true ]; then
  if ! git -C "$PROJECT_DIR" rev-parse --verify HEAD >/dev/null 2>&1; then
    # Fall back to a local git identity when none is configured globally, so the
    # commit succeeds on CI boxes and fresh dev machines. Global config, when
    # present, wins because we only set the local keys if they resolve to empty.
    if [ -z "$(git -C "$PROJECT_DIR" config --get user.email 2>/dev/null || true)" ]; then
      git -C "$PROJECT_DIR" config user.email "touchstone@localhost"
    fi
    if [ -z "$(git -C "$PROJECT_DIR" config --get user.name 2>/dev/null || true)" ]; then
      git -C "$PROJECT_DIR" config user.name "Touchstone Bootstrap"
    fi
    git -C "$PROJECT_DIR" add -A
    # No --no-verify needed — hooks are installed after this commit on purpose.
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
esac

if [ -n "$INITIAL_COMMIT_SHA" ]; then
  printf '    commit:   %s (initial touchstone scaffold)\n' "$INITIAL_COMMIT_SHA"
fi

if [ "$REGISTER" = true ]; then
  printf '    registry: %s\n' "$PROJECTS_FILE"
else
  printf '    registry: skipped (--no-register)\n'
fi

# Doctrine 0002 — Cortex / Sentinel / GitHub integrations. These all run after
# the touchstone scaffold is on disk so a failure in any one leaves the core
# project usable. Each prints a one-line success or skip message.

if [ "$WITH_CORTEX" = true ] && [ "$RE_INIT" = false ]; then
  if command -v cortex >/dev/null 2>&1; then
    echo ""
    echo "==> Initializing Cortex ..."
    if ( cd "$PROJECT_DIR" && cortex init ); then
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
    if ( cd "$PROJECT_DIR" && sentinel init ); then
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

if { [ "$GITHUB_MODE" = "private" ] || [ "$GITHUB_MODE" = "public" ]; } && [ "$RE_INIT" = false ]; then
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    echo ""
    echo "==> Creating GitHub repo ($GITHUB_MODE) ..."
    gh_visibility_flag="--${GITHUB_MODE}"
    if ( cd "$PROJECT_DIR" && gh repo create "$(basename "$PROJECT_DIR")" "$gh_visibility_flag" --source . --push ); then
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
  printf "    touchstone new %s --type %s --reviewer %s%s \\\\\n" \
    "$PROJECT_DIR" "$INPUT_TYPE" "${INPUT_REVIEWER:-auto}" "$scaffold_flag"
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
  printf '  %d. Fill in CLAUDE.md and AGENTS.md (architecture, key files, hard-won lessons)\n' "$STEP_NUM"
  STEP_NUM=$((STEP_NUM + 1))
fi
printf '  %d. Install dev tools and project deps: cd %s && bash setup.sh\n' "$STEP_NUM" "$PROJECT_DIR"
STEP_NUM=$((STEP_NUM + 1))
printf '  %d. Verify the install: touchstone doctor --project\n' "$STEP_NUM"
echo ""

# Doctrine 0002 — mark success so the EXIT trap doesn't clean up.
WIZARD_COMPLETE=true
