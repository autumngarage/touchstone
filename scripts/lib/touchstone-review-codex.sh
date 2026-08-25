#!/usr/bin/env bash
# Resolve and authenticate the native Codex executable used by normal review.

touchstone_codex_fail() {
  printf '%s\n' "$*" >&2
  return 1
}

touchstone_codex_canonical_path() {
  local path="$1" link directory basename depth=0

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
    directory="$(cd "$(dirname "$path")" 2>/dev/null && pwd -P)" || {
      touchstone_codex_fail "Codex executable link has an unreadable target: $path"
      return
    }
    basename="$(basename "$path")"
    path="$directory/$basename"
  done

  directory="$(cd "$(dirname "$path")" 2>/dev/null && pwd -P)" || {
    touchstone_codex_fail "Codex executable has an unreadable directory: $path"
    return
  }
  printf '%s/%s\n' "$directory" "$(basename "$path")"
}

touchstone_resolve_codex_native() {
  local candidate="$1" platform="$2" machine="$3"
  local package_root package_scope platform_package target_triple package_candidate leaf native bundled_path

  candidate="$(touchstone_codex_canonical_path "$candidate")" || return
  bundled_path=""

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
      candidate="$(touchstone_codex_canonical_path "$native")" || return
      if [ -d "$(dirname "$(dirname "$candidate")")/path" ]; then
        bundled_path="$(cd "$(dirname "$(dirname "$candidate")")/path" && pwd -P)" || return
        case "$bundled_path" in
          *:*)
            touchstone_codex_fail "official npm Codex bundled-tool path cannot be represented safely: $bundled_path"
            return
            ;;
        esac
      fi
      ;;
  esac

  printf '%s\n' "$candidate"
  [ -z "$bundled_path" ] || printf '%s\n' "$bundled_path"
}

touchstone_verify_openai_codex() {
  local candidate="$1" codesign_bin="$2" signature

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
