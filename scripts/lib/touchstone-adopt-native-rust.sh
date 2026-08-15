# shellcheck shell=bash
# shellcheck disable=SC2034 # globals are shared across sourced compiler modules

toml_has_local_path_reference() {
  local file="$1"
  awk '
    {
      line = $0
      sub(/[[:space:]]*#.*/, "", line)
      gsub(/[[:space:]"\047]/, "", line)
      if (line ~ /(^|[,{.])path=/) found=1
    }
    END { exit !found }
  ' "$file"
}

cargo_has_dependency_declaration() {
  local file="$1"
  awk '
    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
      section = $0
      sub(/^[[:space:]]*\[/, "", section)
      sub(/\][[:space:]]*$/, "", section)
      gsub(/[[:space:]"\047]/, "", section)
      dependency_table = section ~ /(^|[.])(dependencies|dev-dependencies|build-dependencies)$/
      if (section ~ /(^|[.])(dependencies|dev-dependencies|build-dependencies)[.]/) found = 1
      next
    }
    {
      line = $0
      sub(/[[:space:]]*#.*/, "", line)
      if (dependency_table && line ~ /^[[:space:]]*[A-Za-z0-9_-]+[[:space:]]*=/) found = 1
      compact = line
      gsub(/[[:space:]"\047]/, "", compact)
      if (compact ~ /(^|[.])(dependencies|dev-dependencies|build-dependencies)[.][A-Za-z0-9_-]+=/) found = 1
    }
    END { exit !found }
  ' "$file"
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
  cargo_has_dependency_declaration "$directory/Cargo.toml" \
    && contract_refusal "Rust target '${directory#"$PROJECT_ROOT"/}' declares a dependency without a verified checkout-bound offline source; pass --task NAME=COMMAND"
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
  local directory="$1" config ancestor rust_manifest_status=1
  if [ -e "$directory/build.rs" ] || [ -L "$directory/build.rs" ]; then
    contract_refusal "Rust package '${directory#"$PROJECT_ROOT"/}' has a build.rs program automatic validation cannot isolate; pass --task NAME=COMMAND"
  fi
  awk '
    function value_of(line) {
      sub(/^[^=]*=[[:space:]]*/, "", line)
      sub(/[[:space:]]*(#.*)?$/, "", line)
      return line
    }
    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
      section=$0
      sub(/^[[:space:]]*\[/, "", section)
      sub(/\][[:space:]]*$/, "", section)
      next
    }
    section == "package" && /^[[:space:]]*build[[:space:]]*=/ {
      line=value_of($0)
      if (line != "false") unsafe=1
    }
    section == "package" && /^[[:space:]]*workspace[[:space:]]*=/ { external_workspace=1 }
    section == "" && /^[[:space:]]*package[.][A-Za-z0-9_.-]+[[:space:]]*=/ { dotted_package=1 }
    END {
      if (unsafe) exit 10
      if (external_workspace) exit 11
      if (dotted_package) exit 12
      exit 1
    }
  ' "$directory/Cargo.toml" \
    || rust_manifest_status=$?
  case "${rust_manifest_status:-1}" in
    10) contract_refusal "Rust package '${directory#"$PROJECT_ROOT"/}' declares a custom build program automatic validation cannot isolate; pass --task NAME=COMMAND" ;;
    11) contract_refusal "Rust package '${directory#"$PROJECT_ROOT"/}' declares an explicit workspace root automatic validation cannot bind to this checkout; pass --task NAME=COMMAND" ;;
    12) contract_refusal "Rust package '${directory#"$PROJECT_ROOT"/}' uses dotted package keys this portable compiler cannot classify safely; pass --task NAME=COMMAND" ;;
  esac
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
