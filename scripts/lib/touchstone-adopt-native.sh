# shellcheck shell=bash

swift_has_dependency_source() {
  local file="$1" source="$2"
  awk -v source="$source" '
    /\.package[[:space:]]*\(/ { in_package=1 }
    in_package && source == "remote" && /(^|[^A-Za-z])(url|id)[[:space:]]*:/ { found=1 }
    in_package && source == "path" && /(^|[^A-Za-z])path[[:space:]]*:/ { found=1 }
    in_package && /\)/ { in_package=0 }
    END { exit !found }
  ' "$file"
}
validate_swift_manifest() {
  local file="$1" directory="$2" target source_root source_relative tracked_sources source
  target="$(awk '
    /^[[:space:]]*$/ { next }
    count == 0 && /^\/\/ swift-tools-version:[[:space:]]*[0-9]+[.][0-9]+([.][0-9]+)?[[:space:]]*$/ { count++; next }
    count == 1 && /^[[:space:]]*import[[:space:]]+PackageDescription[[:space:]]*$/ { count++; next }
    count == 2 && /^[[:space:]]*let[[:space:]]+package[[:space:]]*=[[:space:]]*Package[(][[:space:]]*$/ { count++; next }
    count == 3 && /^[[:space:]]*name:[[:space:]]*"[A-Za-z0-9._-]+",[[:space:]]*$/ { count++; next }
    count == 4 && /^[[:space:]]*targets:[[:space:]]*\[[[:space:]]*$/ { count++; next }
    count == 5 && /^[[:space:]]*[.]testTarget[(]name:[[:space:]]*"[A-Za-z0-9._-]+"[)][[:space:]]*$/ {
      target=$0
      sub(/^[[:space:]]*[.]testTarget[(]name:[[:space:]]*"/, "", target)
      sub(/"[)][[:space:]]*$/, "", target)
      count++
      next
    }
    count == 6 && /^[[:space:]]*\][[:space:]]*$/ { count++; next }
    count == 7 && /^[[:space:]]*[)][[:space:]]*$/ { count++; next }
    { invalid=1 }
    END {
      if (invalid || count != 8 || target == "") exit 2
      print target
    }
  ' "$file" 2>/dev/null)" \
    || contract_refusal "Package.swift is malformed or outside the portable buildable-target subset; pass --task NAME=COMMAND for a manual contract"
  source_root="$directory/Tests/$target"
  if [ "$directory" = "$PROJECT_ROOT" ]; then
    source_relative="Tests/$target"
  else
    source_relative="${directory#"$PROJECT_ROOT"/}/Tests/$target"
  fi
  tracked_sources="$(git -C "$PROJECT_ROOT" ls-files -- "$source_relative" | awk '/[.]swift$/')"
  [ -n "$tracked_sources" ] \
    || contract_refusal "Swift test target '$target' has no tracked Swift source"
  while IFS= read -r source; do
    [ -n "$source" ] || continue
    [ -f "$PROJECT_ROOT/$source" ] && [ ! -L "$PROJECT_ROOT/$source" ] \
      || contract_refusal "Swift test target '$target' source '$source' is not a regular tracked file"
  done <<<"$tracked_sources"
  [ -d "$source_root" ] && [ ! -L "$source_root" ] \
    || contract_refusal "Swift test target '$target' has no regular source directory"
}
toml_has_local_path_reference() {
  local file="$1"
  awk '
    {
      line = $0
      sub(/[[:space:]]*#.*/, "", line)
      gsub(/[[:space:]"\047]/, "", line)
      if (line ~ /(^|[,{])path=/) found=1
    }
    END { exit !found }
  ' "$file"
}

go_has_local_replace() {
  local file="$1"
  awk '
    function trim(value) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      return value
    }
    {
      line = $0
      sub(/[[:space:]]*\/\/.*/, "", line)
      if (line !~ /=>/) next
      replacement = substr(line, index(line, "=>") + 2)
      replacement = trim(replacement)
      gsub(/^["\047]|["\047]$/, "", replacement)
      if (replacement ~ /^(\/|~\/|[.][.]?\/)/ ||
          replacement ~ /^[A-Za-z]:[\\\/]/ || replacement ~ /^\\\\/) found=1
    }
    END { exit !found }
  ' "$file"
}

validate_go_mod_document() {
  local file="$1"
  awk '
    /^[[:space:]]*(\/\/.*)?$/ { next }
    /^[[:space:]]*module[[:space:]]+[^[:space:]]+[[:space:]]*$/ {
      if (module_seen) exit 2
      module_seen=1
      next
    }
    /^[[:space:]]*go[[:space:]]+[0-9]+[.][0-9]+([.][0-9]+)?[[:space:]]*$/ {
      if (go_seen) exit 2
      go_seen=1
      next
    }
    { exit 2 }
    END { if (!module_seen) exit 2 }
  ' "$file" >/dev/null 2>&1 \
    || contract_refusal "go.mod is malformed or outside the dependency-free portable subset; pass --task NAME=COMMAND for a manual contract"
}

validate_cargo_lock() {
  local file="$1"
  validate_toml_document "$file" Cargo.lock
  awk '
    BEGIN { in_root=1 }
    /^[[:space:]]*\[/ { in_root=0 }
    !in_root { next }
    /^[[:space:]]*version[[:space:]]*=[[:space:]]*[34][[:space:]]*$/ {
      if (version_seen) exit 2
      version_seen=1
      next
    }
    /^[[:space:]]*(#.*)?$/ { next }
    { exit 2 }
    END { if (!version_seen) exit 2 }
  ' "$file" >/dev/null 2>&1 \
    || contract_refusal "Cargo.lock has no unique supported root lockfile version; regenerate it or pass --task NAME=COMMAND"
  awk '
    function finish_package() {
      if (in_package && (!name_seen || !version_seen)) exit 2
    }
    /^[[:space:]]*\[\[package\]\][[:space:]]*$/ {
      finish_package()
      in_package=1
      nested=0
      name_seen=version_seen=0
      packages++
      next
    }
    in_package && /^[[:space:]]*\[/ { nested=1; next }
    !in_package || nested { next }
    /^[[:space:]]*name[[:space:]]*=[[:space:]]*"[A-Za-z0-9][A-Za-z0-9._-]*"[[:space:]]*$/ {
      if (name_seen) exit 2
      name_seen=1
      next
    }
    /^[[:space:]]*name[[:space:]]*=/ { exit 2 }
    /^[[:space:]]*version[[:space:]]*=[[:space:]]*"[^"]+"[[:space:]]*$/ {
      if (version_seen) exit 2
      version_seen=1
      next
    }
    /^[[:space:]]*version[[:space:]]*=/ { exit 2 }
    END {
      finish_package()
      if (!packages) exit 2
    }
  ' "$file" >/dev/null 2>&1 \
    || contract_refusal "Cargo.lock has incomplete package records; regenerate it or pass --task NAME=COMMAND"
}

verify_cargo_lock_compatibility() {
  local directory="$1" output detail
  command -v cargo >/dev/null 2>&1 \
    || contract_refusal "Rust automatic adoption requires Cargo to verify the lock offline; install Cargo or pass --task NAME=COMMAND"
  if output="$(cd "$directory" \
    && CARGO_NET_OFFLINE=true \
      cargo metadata --locked --offline --no-deps --format-version 1 2>&1)"; then
    return 0
  fi
  detail="$(printf '%s\n' "$output" | awk '
    NF {
      if (joined != "") joined=joined " "
      joined=joined $0
    }
    END { print substr(joined, 1, 300) }
  ')"
  contract_refusal "Cargo.lock is incompatible with the verified manifests under offline metadata resolution${detail:+: $detail}; regenerate it or pass --task NAME=COMMAND"
}

rust_manifest_is_package() {
  awk '/^[[:space:]]*\[package\][[:space:]]*$/ { found=1 } END { exit !found }' "$1"
}

require_tracked_rust_source() {
  local directory="$1" relative source
  reject_rust_execution_config "$directory"
  rust_manifest_is_package "$directory/Cargo.toml" || return 0
  if [ "$directory" = "$PROJECT_ROOT" ]; then relative=""; else relative="${directory#"$PROJECT_ROOT"/}/"; fi
  for source in src/lib.rs src/main.rs; do
    if git -C "$PROJECT_ROOT" ls-files --error-unmatch -- "$relative$source" >/dev/null 2>&1; then
      [ -f "$PROJECT_ROOT/$relative$source" ] && [ ! -L "$PROJECT_ROOT/$relative$source" ] \
        || contract_refusal "Rust source '$relative$source' is not a regular tracked file"
      return 0
    fi
  done
  contract_refusal "Rust package '${directory#"$PROJECT_ROOT"/}' has no tracked default src/lib.rs or src/main.rs"
}

reject_rust_execution_config() {
  local directory="$1" config ancestor
  if [ -e "$directory/build.rs" ] || [ -L "$directory/build.rs" ]; then
    contract_refusal "Rust package '${directory#"$PROJECT_ROOT"/}' has a build.rs program automatic validation cannot isolate; pass --task NAME=COMMAND"
  fi
  awk '
    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
      section=$0
      sub(/^[[:space:]]*\[/, "", section)
      sub(/\][[:space:]]*$/, "", section)
      next
    }
    section == "package" && /^[[:space:]]*build[[:space:]]*=/ {
      line=$0
      sub(/^[^=]*=[[:space:]]*/, "", line)
      sub(/[[:space:]]*(#.*)?$/, "", line)
      if (line != "false") unsafe=1
    }
    END { exit !unsafe }
  ' "$directory/Cargo.toml" \
    && contract_refusal "Rust package '${directory#"$PROJECT_ROOT"/}' declares a custom build program automatic validation cannot isolate; pass --task NAME=COMMAND"
  ancestor="$directory"
  while :; do
    for config in "$ancestor/.cargo/config" "$ancestor/.cargo/config.toml"; do
      if [ -e "$config" ] || [ -L "$config" ]; then
        contract_refusal "Rust target '${directory#"$PROJECT_ROOT"/}' inherits project-controlled Cargo execution config '${config#"$PROJECT_ROOT"/}'; pass --task NAME=COMMAND"
      fi
    done
    [ "$ancestor" != "$PROJECT_ROOT" ] || break
    ancestor="${ancestor%/*}"
    case "$ancestor" in "$PROJECT_ROOT" | "$PROJECT_ROOT"/*) ;; *)
      contract_refusal "Rust target '${directory#"$PROJECT_ROOT"/}' escapes the repository while checking Cargo config"
      ;;
    esac
  done
}

require_tracked_go_source() {
  local directory="$1" relative tracked_sources source
  if [ "$directory" = "$PROJECT_ROOT" ]; then relative=""; else relative="${directory#"$PROJECT_ROOT"/}"; fi
  if [ -n "$relative" ]; then
    tracked_sources="$(git -C "$PROJECT_ROOT" ls-files -- "$relative" | awk -v prefix="$relative/" '
      function selected(path, count, part, parts, base) {
        path=substr(path, length(prefix) + 1)
        count=split(path, parts, "/")
        for (part=1; part<count; part++) {
          if (parts[part] == "vendor" || parts[part] == "testdata" || parts[part] ~ /^[._]/) return 0
        }
        base=parts[count]
        return base ~ /[.]go$/ && base !~ /^[._]/
      }
      selected($0)
    ')"
  else
    tracked_sources="$(git -C "$PROJECT_ROOT" ls-files | awk '
      function selected(path, count, part, parts, base) {
        count=split(path, parts, "/")
        for (part=1; part<count; part++) {
          if (parts[part] == "vendor" || parts[part] == "testdata" || parts[part] ~ /^[._]/) return 0
        }
        base=parts[count]
        return base ~ /[.]go$/ && base !~ /^[._]/
      }
      selected($0)
    ')"
  fi
  [ -n "$tracked_sources" ] \
    || contract_refusal "Go target '${directory#"$PROJECT_ROOT"/}' has no tracked Go source"
  while IFS= read -r source; do
    [ -n "$source" ] || continue
    [ -f "$PROJECT_ROOT/$source" ] && [ ! -L "$PROJECT_ROOT/$source" ] \
      || contract_refusal "Go source '$source' is not a regular tracked file"
  done <<<"$tracked_sources"
}

verify_go_packages() {
  local directory="$1" output detail
  command -v go >/dev/null 2>&1 \
    || contract_refusal "Go automatic adoption requires the Go tool to verify selected packages offline; install Go or pass --task NAME=COMMAND"
  if output="$(cd "$directory" \
    && GOENV=off GOTOOLCHAIN=local GOWORK=off GOPROXY=off GOSUMDB=off \
      go list ./... 2>&1)"; then
    [ -n "$(printf '%s' "$output" | awk 'NF { found=1 } END { if (found) print "yes" }')" ] \
      && return 0
  fi
  detail="$(printf '%s\n' "$output" | awk '
    NF {
      if (joined != "") joined=joined " "
      joined=joined $0
    }
    END { print substr(joined, 1, 300) }
  ')"
  contract_refusal "Go target has no package selected by ./... under offline local-toolchain resolution${detail:+: $detail}; pass --task NAME=COMMAND"
}

validate_cargo_workspace_members() {
  local members defaults pattern manifest
  if ! members="$(cargo_workspace_values members)"; then
    contract_refusal "root Cargo.toml has a malformed or repeated workspace members declaration"
  fi
  while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    workspace_pattern_supported "$pattern" \
      || contract_refusal "Cargo workspace pattern '$pattern' uses glob syntax this compiler cannot verify"
    case "$pattern" in *'*'*)
      contract_refusal "Cargo workspace pattern '$pattern' requires expansion this portable compiler cannot verify; list exact tracked members or pass --task NAME=COMMAND"
      ;;
    esac
    valid_relative_path "$pattern" \
      || contract_refusal "Cargo workspace member '$pattern' escapes the repository"
    manifest="$PROJECT_ROOT/$pattern/Cargo.toml"
    [ -f "$manifest" ] && [ ! -L "$manifest" ] \
      || contract_refusal "Cargo workspace member '$pattern' has no regular Cargo.toml"
    git -C "$PROJECT_ROOT" ls-files --error-unmatch -- "$pattern/Cargo.toml" >/dev/null 2>&1 \
      || contract_refusal "Cargo workspace member '$pattern' has no tracked Cargo.toml"
    validate_toml_document "$manifest" "Cargo workspace member '$pattern' Cargo.toml"
    toml_has_local_path_reference "$manifest" \
      && contract_refusal "Cargo workspace member '$pattern' declares a local path dependency this portable compiler cannot verify; pass --task NAME=COMMAND"
    require_tracked_rust_source "$PROJECT_ROOT/$pattern"
  done <<<"$members"
  if ! defaults="$(cargo_workspace_values default-members)"; then
    contract_refusal "root Cargo.toml has a malformed or repeated workspace default-members declaration"
  fi
  while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    workspace_pattern_supported "$pattern" \
      || contract_refusal "Cargo default member '$pattern' uses syntax this compiler cannot verify"
    case "$pattern" in *'*'*)
      contract_refusal "Cargo default member '$pattern' requires expansion this portable compiler cannot verify; list exact tracked members or pass --task NAME=COMMAND"
      ;;
    esac
    valid_relative_path "$pattern" \
      || contract_refusal "Cargo default member '$pattern' escapes the repository"
    printf '%s\n' "$members" | grep -Fqx -- "$pattern" \
      || contract_refusal "Cargo default member '$pattern' is not a verified workspace member"
  done <<<"$defaults"
  return 0
}
