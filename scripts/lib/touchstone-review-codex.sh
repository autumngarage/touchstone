#!/usr/bin/env bash
# Resolve and authenticate the native Codex executable used by normal review.
# Sourced callers read the three TOUCHSTONE_CODEX_* values after each call;
# filesystem paths never cross a text serialization boundary.

touchstone_codex_fail() {
  TOUCHSTONE_CODEX_ERROR="$*"
  : "$TOUCHSTONE_CODEX_ERROR"
  return 1
}

touchstone_review_path_is_profile_safe() {
  local path="$1"

  case "$path" in
    /*) ;;
    *) return 1 ;;
  esac
  ! LC_ALL=C printf '%s' "$path" | grep -q '[[:cntrl:]"\\]'
}

touchstone_review_git() {
  env \
    -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE \
    -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES \
    -u GIT_CEILING_DIRECTORIES -u GIT_CONFIG -u GIT_CONFIG_PARAMETERS \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_COUNT=0 \
    git "$@"
}

touchstone_review_resolve_git_context() {
  local invoking_dir="$1" repository_root git_dir git_common_dir

  TOUCHSTONE_REVIEW_REPOSITORY_ROOT=""
  TOUCHSTONE_REVIEW_GIT_DIR=""
  TOUCHSTONE_REVIEW_GIT_COMMON_DIR=""

  repository_root="$(
    touchstone_review_git -C "$invoking_dir" rev-parse --show-toplevel 2>/dev/null
  )" || {
    touchstone_codex_fail "normal review must run inside a git repository"
    return
  }
  repository_root="$(cd "$repository_root" && pwd -P)" || {
    touchstone_codex_fail "normal review repository root is unreadable: $repository_root"
    return
  }
  git_dir="$(
    touchstone_review_git -C "$repository_root" rev-parse --absolute-git-dir 2>/dev/null
  )" || {
    touchstone_codex_fail "normal review could not resolve the repository Git directory"
    return
  }
  git_common_dir="$(
    touchstone_review_git -C "$repository_root" \
      rev-parse --path-format=absolute --git-common-dir 2>/dev/null
  )" || {
    touchstone_codex_fail "normal review could not resolve the repository Git common directory"
    return
  }

  for path in "$repository_root" "$git_dir" "$git_common_dir"; do
    touchstone_review_path_is_profile_safe "$path" || {
      touchstone_codex_fail "repository path cannot be represented safely in the isolated Codex trust boundary: $path"
      return
    }
  done

  # Returned globals are consumed by the sourced caller.
  # shellcheck disable=SC2034
  TOUCHSTONE_REVIEW_REPOSITORY_ROOT="$repository_root"
  # shellcheck disable=SC2034
  TOUCHSTONE_REVIEW_GIT_DIR="$git_dir"
  # shellcheck disable=SC2034
  TOUCHSTONE_REVIEW_GIT_COMMON_DIR="$git_common_dir"
}

touchstone_review_render_profile() {
  local source="$1" destination="$2" repository_root="$3" git_dir="$4" git_common_dir="$5"
  local staged="${destination}.tmp"

  touchstone_review_path_is_profile_safe "$repository_root" \
    && touchstone_review_path_is_profile_safe "$git_dir" \
    && touchstone_review_path_is_profile_safe "$git_common_dir" || {
    touchstone_codex_fail "repository path cannot be represented safely in the isolated Codex trust boundary"
    return
  }
  if ! awk \
    -v repository_root="$repository_root" \
    -v git_dir="$git_dir" \
    -v git_common_dir="$git_common_dir" '
    $0 == "# touchstone:review-git-roots" {
      print "\"" git_dir "\" = \"read\""
      if (git_common_dir != git_dir) {
        print "\"" git_common_dir "\" = \"read\""
      }
      git_roots_rendered = 1
    }
    $0 == "# touchstone:review-project-trust" {
      print "[projects.\"" repository_root "\"]"
      print "trust_level = \"untrusted\""
      project_trust_rendered = 1
    }
    { print }
    END { if (!git_roots_rendered || !project_trust_rendered) exit 42 }
  ' "$source" >"$staged"; then
    rm -f "$staged"
    touchstone_codex_fail "managed review profile is missing a repository boundary marker"
    return
  fi
  if ! mv "$staged" "$destination"; then
    rm -f "$staged"
    touchstone_codex_fail "could not stage the managed review profile in isolated Codex state"
    return
  fi
}

touchstone_review_codex() {
  local codex_bin="$1"
  shift

  "$codex_bin" \
    -p review-normal \
    -c 'shell_environment_policy.filters.OPENROUTER_API_KEY="exclude"' \
    -c 'allow_login_shell=false' \
    --disable shell_snapshot \
    --disable plugins \
    --disable plugin_hooks \
    --disable enable_mcp_apps \
    "$@"
}

touchstone_review_validate_launch() {
  local codex_bin="$1" repository_root="$2" git_bin="$3"
  local output

  if ! output="$(
    touchstone_review_codex "$codex_bin" \
      sandbox -P touchstone_review -C "$repository_root" \
      "$git_bin" -c core.excludesFile=/dev/null status --short \
      2>&1
  )"; then
    touchstone_codex_fail "Codex rejected the managed review profile or cannot inspect exact Git state: $output"
    return
  fi
}

touchstone_codex_physical_directory() {
  local requested="$1" previous="$PWD" directory

  TOUCHSTONE_CODEX_DIRECTORY=""
  if ! builtin cd -P "$requested" 2>/dev/null; then
    touchstone_codex_fail "Codex executable has an unreadable directory: $requested"
    return
  fi
  directory="$PWD"
  if ! builtin cd "$previous" 2>/dev/null; then
    touchstone_codex_fail "could not restore the working directory after resolving Codex: $previous"
    return
  fi
  case "$directory" in
    *$'\n'*)
      touchstone_codex_fail "Codex executable physical directory contains a newline: $requested"
      return
      ;;
  esac
  TOUCHSTONE_CODEX_DIRECTORY="$directory"
}

touchstone_codex_canonical_path() {
  local path="$1" link directory basename depth=0

  TOUCHSTONE_CODEX_CANONICAL=""

  case "$path" in
    /*) ;;
    *)
      touchstone_codex_fail "Codex resolved to a non-absolute executable: $path"
      return
      ;;
  esac
  case "$path" in
    *$'\n'*)
      touchstone_codex_fail "Codex executable path contains a newline"
      return
      ;;
  esac

  while [ -L "$path" ]; do
    depth=$((depth + 1))
    if [ "$depth" -gt 32 ]; then
      touchstone_codex_fail "Codex executable has too many symbolic-link hops: $1"
      return
    fi
    link="$(
      link_status=0
      readlink -n "$path" || link_status=$?
      printf '\001'
      exit "$link_status"
    )" || {
      touchstone_codex_fail "could not read Codex executable link: $path"
      return
    }
    link="${link%$'\001'}"
    case "$link" in
      *$'\n'*)
        touchstone_codex_fail "Codex executable link target contains a newline: $path"
        return
        ;;
    esac
    case "$link" in
      /*) path="$link" ;;
      *) path="$(dirname "$path")/$link" ;;
    esac
    touchstone_codex_physical_directory "$(dirname "$path")" || return
    directory="$TOUCHSTONE_CODEX_DIRECTORY"
    basename="$(basename "$path")"
    path="$directory/$basename"
  done

  touchstone_codex_physical_directory "$(dirname "$path")" || return
  directory="$TOUCHSTONE_CODEX_DIRECTORY"
  TOUCHSTONE_CODEX_CANONICAL="$directory/$(basename "$path")"
}

touchstone_resolve_codex_native() {
  local candidate="$1" platform="$2" machine="$3"
  local package_root package_scope platform_package target_triple package_candidate leaf native bundled_path

  TOUCHSTONE_CODEX_ERROR=""
  TOUCHSTONE_CODEX_BIN=""
  TOUCHSTONE_CODEX_BUNDLED_PATH=""
  bundled_path=""
  touchstone_codex_canonical_path "$candidate" || return
  candidate="$TOUCHSTONE_CODEX_CANONICAL"

  case "$candidate" in
    */@openai/codex/bin/codex.js)
      [ "$platform" = Darwin ] || {
        touchstone_codex_fail "official npm Codex resolution is unsupported on $platform"
        return
      }
      case "$machine" in
        arm64)
          platform_package="codex-darwin-arm64"
          target_triple="aarch64-apple-darwin"
          ;;
        x86_64)
          platform_package="codex-darwin-x64"
          target_triple="x86_64-apple-darwin"
          ;;
        *)
          touchstone_codex_fail "official npm Codex has no supported macOS package for architecture: $machine"
          return
          ;;
      esac
      package_root="${candidate%/bin/codex.js}"
      package_scope="${package_root%/codex}"
      native=""
      for package_candidate in \
        "$package_root/node_modules/@openai/$platform_package" \
        "$package_scope/$platform_package" \
        "$package_root"; do
        for leaf in bin/codex codex/codex; do
          if [ -x "$package_candidate/vendor/$target_triple/$leaf" ]; then
            native="$package_candidate/vendor/$target_triple/$leaf"
            break 2
          fi
        done
      done
      [ -n "$native" ] || {
        touchstone_codex_fail "official npm Codex native executable is missing or not executable for package: $platform_package"
        return
      }
      touchstone_codex_canonical_path "$native" || return
      candidate="$TOUCHSTONE_CODEX_CANONICAL"
      if [ -d "$(dirname "$(dirname "$candidate")")/path" ]; then
        touchstone_codex_physical_directory "$(dirname "$(dirname "$candidate")")/path" || return
        bundled_path="$TOUCHSTONE_CODEX_DIRECTORY"
        case "$bundled_path" in
          *:*)
            touchstone_codex_fail "official npm Codex bundled-tool path cannot be represented safely: $bundled_path"
            return
            ;;
        esac
      fi
      ;;
  esac

  TOUCHSTONE_CODEX_BIN="$candidate"
  TOUCHSTONE_CODEX_BUNDLED_PATH="$bundled_path"
  : "$TOUCHSTONE_CODEX_BIN" "$TOUCHSTONE_CODEX_BUNDLED_PATH"
}

touchstone_verify_openai_codex() {
  local candidate="$1" codesign_bin="$2" signature

  TOUCHSTONE_CODEX_ERROR=""
  [ -x "$codesign_bin" ] || {
    touchstone_codex_fail "macOS code-signature verification is unavailable at $codesign_bin"
    return
  }
  "$codesign_bin" --verify --deep --strict "$candidate" 2>/dev/null || {
    touchstone_codex_fail "Codex failed macOS code-signature integrity verification: $candidate"
    return
  }
  signature="$("$codesign_bin" -dv --verbose=4 "$candidate" 2>&1)" || {
    touchstone_codex_fail "Codex does not have a verifiable macOS code signature: $candidate"
    return
  }
  printf '%s\n' "$signature" | grep -qFx 'Identifier=codex' || {
    touchstone_codex_fail "refusing an executable that is not the signed Codex CLI: $candidate"
    return
  }
  printf '%s\n' "$signature" | grep -qFx 'TeamIdentifier=2DC432GLL2' || {
    touchstone_codex_fail "refusing a Codex executable not signed by OpenAI: $candidate"
    return
  }
}
